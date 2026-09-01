import Foundation

/// 流式过程中的进度事件，按真实 SSE 事件驱动 UI，替代此前的固定定时器假阶段。
enum LLMStreamEvent: Sendable, Equatable {
    /// 已建立连接，服务端开始返回 SSE。
    case connected
    /// 模型正在推理（收到 reasoning 相关事件）。
    case reasoning
    /// 增量正文更新（携带当前累计的完整文本）。
    case delta(String)
}

/// actor：credentials/refreshTask 的读写与 single-flight 判断天然串行，
/// 避免并发截图任务同时用同一个 rotating refresh token 双重刷新（会把 token 用废）。
actor LLMClient {
    private let config: AppConfig
    private let session: URLSession
    private let onCredentialsRefreshed: @Sendable (CodexOAuthCredentials) -> Void
    private let refreshCredentialsProvider: @Sendable (CodexOAuthCredentials) async throws -> CodexOAuthCredentials
    private var credentials: CodexOAuthCredentials?
    private var refreshTask: Task<CodexOAuthCredentials, Error>?

    /// 内部信号：access token 被服务端拒绝（HTTP 401），可刷新后重试一次。
    private struct UnauthorizedError: Error {}

    init(
        config: AppConfig,
        session: URLSession = .shared,
        onCredentialsRefreshed: @escaping @Sendable (CodexOAuthCredentials) -> Void = { _ in },
        refreshCredentials: (@Sendable (CodexOAuthCredentials) async throws -> CodexOAuthCredentials)? = nil
    ) {
        self.config = config
        self.session = session
        self.onCredentialsRefreshed = onCredentialsRefreshed
        self.refreshCredentialsProvider = refreshCredentials ?? { credentials in
            try await CodexOAuthClient().refresh(credentials)
        }
        credentials = config.codexCredentials
    }

    /// single-flight 且不可取消的刷新：OpenAI 的 refresh token 是 rotating 的，
    /// 一旦请求到达服务端完成轮换，本地就必须拿到并保存新 token——
    /// 用 detached task 执行并在任务内部完成持久化，即使调用方被取消也不丢结果。
    private func refreshCredentials(force: Bool = false) async throws -> CodexOAuthCredentials {
        guard let currentCredentials = credentials else {
            throw AppError.configuration("请先登录 ChatGPT/Codex。")
        }
        if !force, !currentCredentials.needsRefresh {
            return currentCredentials
        }
        if let task = refreshTask {
            let refreshed = try await task.value
            credentials = refreshed
            return refreshed
        }

        let current = currentCredentials
        let callback = onCredentialsRefreshed
        let provider = self.refreshCredentialsProvider
        let task = Task.detached {
            let refreshed = try await provider(current)
            callback(refreshed)
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        credentials = refreshed
        return refreshed
    }

    func analyze(
        imageData: Data,
        mimeType: String = "image/png",
        onEvent: (@Sendable (LLMStreamEvent) -> Void)? = nil
    ) async throws -> String {
        try await analyze(imageDataList: [imageData], mimeType: mimeType, onEvent: onEvent)
    }

    func analyze(
        imageDataList: [Data],
        mimeType: String = "image/png",
        onEvent: (@Sendable (LLMStreamEvent) -> Void)? = nil
    ) async throws -> String {
        guard !imageDataList.isEmpty else {
            throw AppError.configuration("至少需要一张截图。")
        }
        let body: [String: Any]
        switch config.provider {
        case .codex:
            body = Self.makeRequestBody(config: config, imageDataList: imageDataList, mimeType: mimeType)
        case .openAICompatible:
            body = Self.makeOpenAICompatibleRequestBody(config: config, imageDataList: imageDataList, mimeType: mimeType)
        }
        return try await perform(body: body, onEvent: onEvent)
    }

    /// 向 OpenAI 兼容服务发送一次最小非流式请求，用于验证地址、凭证和模型是否可用。
    func verifyConnection() async throws {
        guard config.provider == .openAICompatible else {
            throw AppError.configuration("当前不是 OpenAI 兼容 API。")
        }

        let body = Self.makeOpenAICompatibleVerificationRequestBody(config: config)
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        guard let url = Self.resolveOpenAICompatibleEndpoint(config.customBaseURL) else {
            throw AppError.configuration("OpenAI 兼容 API 地址无效。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.customAPIKey.isEmpty {
            request.setValue("Bearer \(config.customAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        request.httpBody = bodyData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withTimeout(
                seconds: 30,
                timeoutMessage: "外部 LLM 验证超过 30 秒仍未返回。"
            ) {
                try await self.session.data(for: request)
            }
        } catch {
            if Self.isCancellationError(error) { throw error }
            if error is AppError { throw error }
            throw AppError.network(Self.openAICompatibleNetworkErrorMessage(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("外部 LLM 返回了无效的 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.openAICompatibleErrorMessage(from: data)
                ?? "外部 LLM 请求失败：HTTP \(http.statusCode)。"
            throw AppError.response(message)
        }

        do {
            if Self.looksLikeOpenAICompatibleSSE(data) {
                _ = try Self.parseOpenAICompatibleSSE(from: data, onEvent: nil)
            } else {
                _ = try Self.parseOpenAICompatibleContent(from: data)
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.response("外部 LLM 返回格式无法识别，请确认接口返回 OpenAI 兼容格式。")
        }
    }

    nonisolated static func makeRequestBody(
        config: AppConfig,
        imageDataList: [Data],
        mimeType: String
    ) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_text", "text": config.prompt]]
        content.append(contentsOf: imageDataList.map { imageData in
            [
                "type": "input_image",
                "image_url": "data:\(mimeType);base64,\(imageData.base64EncodedString())"
            ]
        })
        return makeBody(config: config, input: [["role": "user", "content": content]])
    }

    nonisolated static func makeOpenAICompatibleRequestBody(
        config: AppConfig,
        imageDataList: [Data],
        mimeType: String
    ) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": config.prompt]]
        content.append(contentsOf: imageDataList.map { imageData in
            [
                "type": "image_url",
                "image_url": ["url": "data:\(mimeType);base64,\(imageData.base64EncodedString())"]
            ]
        })

        var body: [String: Any] = [
            "model": config.model,
            // Non-streaming is the most widely supported mode across third-party
            // vision gateways. The response reader still accepts SSE if a gateway
            // ignores this flag and streams anyway.
            "stream": false,
            "messages": [
                ["role": "system", "content": config.instructions],
                ["role": "user", "content": content]
            ]
        ]
        if config.maxOutputTokens > 0 {
            body["max_tokens"] = config.maxOutputTokens
        }
        return body
    }

    nonisolated static func makeOpenAICompatibleVerificationRequestBody(config: AppConfig) -> [String: Any] {
        [
            "model": config.model,
            "stream": false,
            "messages": [
                [
                    "role": "user",
                    "content": "Reply with OK."
                ]
            ],
            "max_tokens": 1
        ]
    }

    nonisolated private static func makeBody(config: AppConfig, input: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model,
            "store": false,
            "stream": true,
            "instructions": config.instructions,
            "input": input,
            "text": [
                "verbosity": config.textVerbosity.rawValue
            ]
        ]
        var reasoning: [String: Any] = [
            "effort": config.thinkingEnabled ? config.reasoningEffort.rawValue : "none"
        ]
        if config.thinkingEnabled, let summary = config.reasoningSummary.requestValue {
            reasoning["summary"] = summary
        }
        body["reasoning"] = reasoning
        if let serviceTier = config.serviceTier.requestValue {
            body["service_tier"] = serviceTier
        }
        if config.maxOutputTokens > 0 {
            body["max_output_tokens"] = config.maxOutputTokens
        }
        return body
    }

    private func perform(
        body: [String: Any],
        onEvent: (@Sendable (LLMStreamEvent) -> Void)?
    ) async throws -> String {
        let timeoutSeconds = responseTimeoutSeconds
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        switch config.provider {
        case .openAICompatible:
            return try await sendOpenAICompatible(bodyData: bodyData, timeoutSeconds: timeoutSeconds, onEvent: onEvent)
        case .codex:
            let activeCredentials = try await refreshCredentials()
            do {
                return try await send(bodyData: bodyData, credentials: activeCredentials, timeoutSeconds: timeoutSeconds, onEvent: onEvent)
            } catch is UnauthorizedError {
                // access token 被服务端提前吊销：强制刷新一次并重试。
                let refreshed = try await refreshCredentials(force: true)
                do {
                    return try await send(bodyData: bodyData, credentials: refreshed, timeoutSeconds: timeoutSeconds, onEvent: onEvent)
                } catch is UnauthorizedError {
                    throw AppError.authExpired("ChatGPT 登录已失效，请重新登录。")
                }
            }
        }
    }

    private func sendOpenAICompatible(
        bodyData: Data,
        timeoutSeconds: UInt64,
        onEvent: (@Sendable (LLMStreamEvent) -> Void)? = nil
    ) async throws -> String {
        guard let url = Self.resolveOpenAICompatibleEndpoint(config.customBaseURL) else {
            throw AppError.configuration("OpenAI 兼容 API 地址无效。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !config.customAPIKey.isEmpty {
            request.setValue("Bearer \(config.customAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.httpBody = bodyData

        return try await withTimeout(seconds: timeoutSeconds) {
            try await self.streamOpenAICompatibleResponse(for: request, onEvent: onEvent)
        }
    }

    nonisolated static func resolveOpenAICompatibleEndpoint(_ base: String) -> URL? {
        var value = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        if !value.hasSuffix("/chat/completions") {
            value += "/chat/completions"
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }

    private func send(
        bodyData: Data,
        credentials: CodexOAuthCredentials,
        timeoutSeconds: UInt64,
        onEvent: (@Sendable (LLMStreamEvent) -> Void)? = nil
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-client-request-id")
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.httpBody = bodyData

        return try await withTimeout(seconds: timeoutSeconds) {
            try await self.streamCodexResponse(for: request, onEvent: onEvent)
        }
    }

    private var responseTimeoutSeconds: UInt64 {
        guard config.thinkingEnabled else { return 180 }

        switch config.reasoningEffort {
        case .minimal, .low:
            return 240
        case .medium:
            return 360
        case .high:
            return 480
        case .xhigh:
            return 600
        }
    }

    /// 增量消费 SSE：逐行解析、逐 delta 回调，首字延迟从"等待全程"降到秒级。
    /// AsyncLineSequence 自动处理 \n / \r\n 行终止符；该 API 的每个 data: 负载
    /// 都是单行 JSON，因此无需按空行组装多行事件。
    private func streamCodexResponse(
        for request: URLRequest,
        onEvent: (@Sendable (LLMStreamEvent) -> Void)?
    ) async throws -> String {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Self.isCancellationError(error) {
                throw error
            }
            throw AppError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 {
                throw UnauthorizedError()
            }
            var errorData = Data()
            do {
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count > 256 * 1024 { break }
                }
            } catch {
                // 错误响应体读取失败时用状态码兜底。
            }
            let message = friendlyErrorMessage(from: errorData) ?? "Codex 请求失败：HTTP \(http.statusCode)。"
            throw AppError.response(message)
        }

        onEvent?(.connected)

        var deltaText = ""
        var finalText = ""
        var sawReasoning = false
        var completed = false
        var finished = false

        // SSE 只认 \n / \r\n 为行终止符。这里按字节手工切行，
        // 不能用 AsyncLineSequence——它还会在 U+2028/U+2029/NEL 处断行，
        // 而这些字符可以合法地出现在 JSON 字符串里，会把负载撕成两半。
        func handleLine(_ rawLine: Data) throws {
            var lineData = rawLine
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            guard let line = String(data: lineData, encoding: .utf8),
                  line.hasPrefix("data:") else {
                return
            }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return }

            if payload == "[DONE]" {
                finished = true
                return
            }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return
            }

            if let message = friendlyErrorMessage(fromJSON: json) {
                throw AppError.response(message)
            }

            let eventType = json["type"] as? String

            if !sawReasoning, isReasoningEvent(eventType: eventType, json: json) {
                sawReasoning = true
                onEvent?(.reasoning)
            }

            if eventType == "response.output_text.delta",
               let delta = json["delta"] as? String {
                deltaText += delta
                onEvent?(.delta(deltaText))
            }

            if eventType == "response.output_text.done",
               let text = json["text"] as? String,
               !text.isEmpty {
                finalText = text
            }

            if let responseObject = json["response"] as? [String: Any] {
                let extracted = extractText(from: responseObject).joined(separator: "\n")
                if !extracted.isEmpty {
                    finalText = extracted
                }
            }

            if eventType == "response.failed" {
                throw AppError.response("Codex 处理失败（response.failed），请重试。")
            }

            if eventType == "response.completed" {
                completed = true
                finished = true
            }
        }

        do {
            var lineBuffer = Data()
            for try await byte in bytes {
                if byte == 0x0A {
                    try handleLine(lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                    if finished { break }
                } else {
                    lineBuffer.append(byte)
                }
            }
            if !finished, !lineBuffer.isEmpty {
                try handleLine(lineBuffer)
            }
        } catch let error as AppError {
            throw error
        } catch {
            // 取消错误必须原样上抛，否则上层无法把"用户中断"与真实故障区分开。
            if Self.isCancellationError(error) {
                throw error
            }
            throw AppError.network("接收 Codex 返回时中断：\(error.localizedDescription)")
        }

        let result = (completed && !finalText.isEmpty ? finalText : (deltaText.isEmpty ? finalText : deltaText))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else {
            throw AppError.response("Codex 返回中没有可显示文本。")
        }

        return result
    }

    private func streamOpenAICompatibleResponse(
        for request: URLRequest,
        onEvent: (@Sendable (LLMStreamEvent) -> Void)?
    ) async throws -> String {
        let (data, response): (Data, URLResponse)
        do {
            // Some OpenAI-compatible gateways label ordinary JSON as SSE, and some
            // return SSE framing that URLSession.AsyncBytes cannot parse reliably.
            // Read the complete response first, then choose the parser from the body.
            (data, response) = try await session.data(for: request)
        } catch {
            if Self.isCancellationError(error) { throw error }
            throw AppError.network(Self.openAICompatibleNetworkErrorMessage(error))
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = Self.openAICompatibleErrorMessage(from: data)
                ?? "外部 LLM 请求失败：HTTP \(http.statusCode)。"
            throw AppError.response(message)
        }

        onEvent?(.connected)
        // The body is authoritative here. Some gateways advertise SSE even when
        // they return one complete JSON response for a streaming request.
        if Self.looksLikeOpenAICompatibleSSE(data) {
            let text = try Self.parseOpenAICompatibleSSE(from: data, onEvent: onEvent)
            return text
        }

        let text = try Self.parseOpenAICompatibleContent(from: data)
        onEvent?(.delta(text))
        return text
    }

    private static func looksLikeOpenAICompatibleSSE(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("data:") }
    }

    private static func parseOpenAICompatibleSSE(
        from data: Data,
        onEvent: (@Sendable (LLMStreamEvent) -> Void)?
    ) throws -> String {
        guard let rawText = String(data: data, encoding: .utf8) else {
            throw AppError.response("外部 LLM 返回格式无法识别，请确认接口返回 UTF-8 编码的 JSON 或 SSE。")
        }

        var deltaText = ""
        var finalText = ""
        var sawReasoning = false

        for rawLine in rawText.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let jsonData = payload.data(using: String.Encoding.utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let message = openAICompatibleErrorMessage(fromJSON: json) {
                throw AppError.response(message)
            }
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
            let delta = choice["delta"] as? [String: Any]
            let reasoning: String?
            if let delta {
                reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String
            } else {
                reasoning = nil
            }
            if !sawReasoning, reasoning?.isEmpty == false {
                sawReasoning = true
                onEvent?(.reasoning)
            }
            if let delta {
                let text = extractTextValue(from: delta["content"])
                if !text.isEmpty {
                    deltaText += text
                    onEvent?(.delta(deltaText))
                }
            }
            if let message = choice["message"] as? [String: Any] {
                let text = extractTextValue(from: message["content"])
                if !text.isEmpty {
                    finalText = text
                }
            }
            if let text = choice["text"] as? String {
                deltaText += text
                onEvent?(.delta(deltaText))
            }
        }

        let result = (finalText.isEmpty ? deltaText : finalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw AppError.response("外部 LLM 返回中没有可显示文本，请确认该模型支持当前请求。")
        }
        return stripReasoning(result)
    }

    private static func parseOpenAICompatibleContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw AppError.response("外部 LLM 返回格式无法识别：响应不是有效 JSON。")
        }
        if let jsonObject = json as? [String: Any],
           let message = openAICompatibleErrorMessage(fromJSON: jsonObject) {
            throw AppError.response(message)
        }
        let text = stripReasoning(extractOpenAICompatibleText(from: json))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let preview = responsePreview(data)
            let suffix = preview.map { " 响应摘要：\($0)" } ?? ""
            throw AppError.response("外部 LLM 返回格式无法识别：未找到可显示文本。\(suffix)")
        }
        return text
    }

    private static func extractOpenAICompatibleText(from value: Any) -> String {
        guard let dictionary = value as? [String: Any] else {
            if let array = value as? [Any] {
                return array.lazy
                    .map(extractOpenAICompatibleText(from:))
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
            }
            return value as? String ?? ""
        }

        if let choices = dictionary["choices"] as? [Any] {
            for choice in choices {
                let text = extractOpenAICompatibleChoiceText(from: choice)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }

        for key in ["output_text", "text", "content"] {
            let text = extractTextValue(from: dictionary[key])
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        for key in ["data", "response", "output", "result", "message"] {
            if let child = dictionary[key] {
                let text = extractOpenAICompatibleText(from: child)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    private static func extractOpenAICompatibleChoiceText(from value: Any) -> String {
        guard let choice = value as? [String: Any] else {
            return extractOpenAICompatibleText(from: value)
        }
        for key in ["message", "delta"] {
            if let child = choice[key] {
                let text = extractTextValue(from: child)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        for key in ["text", "content"] {
            let text = extractTextValue(from: choice[key])
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }

    private static func extractTextValue(from value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if let array = value as? [Any] {
            return array.map { extractTextValue(from: $0) }.joined()
        }
        guard let dictionary = value as? [String: Any] else { return "" }
        for key in ["text", "content", "output_text", "value"] {
            if let child = dictionary[key] {
                let text = extractTextValue(from: child)
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    private static func responsePreview(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let compact = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        let limit = 180
        return compact.count > limit ? String(compact.prefix(limit)) + "…" : compact
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func openAICompatibleErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? "外部 LLM 返回错误：\(text!)" : nil
        }
        return openAICompatibleErrorMessage(fromJSON: json)
    }

    private static func openAICompatibleErrorMessage(fromJSON json: [String: Any]) -> String? {
        let error = json["error"] as? [String: Any]
        let message = error?["message"] as? String
            ?? json["message"] as? String
            ?? json["detail"] as? String
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "外部 LLM 返回错误：\(message)"
    }

    private static func openAICompatibleNetworkErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == URLError.Code.cannotParseResponse.rawValue {
            return "外部 LLM 返回格式不正确，请确认 API 地址指向 OpenAI 兼容的 /chat/completions 接口。"
        }
        return error.localizedDescription
    }

    private static func stripReasoning(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>", options: .caseInsensitive),
              let end = result.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let end = result.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            result = String(result[end.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isReasoningEvent(eventType: String?, json: [String: Any]) -> Bool {
        if let eventType, eventType.contains("reasoning") {
            return true
        }
        if let item = json["item"] as? [String: Any],
           let itemType = item["type"] as? String,
           itemType.contains("reasoning") {
            return true
        }
        return false
    }

    private func extractText(from value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }

        if let array = value as? [Any] {
            return array.flatMap(extractText)
        }

        guard let dictionary = value as? [String: Any] else {
            return []
        }

        var parts: [String] = []

        if let type = dictionary["type"] as? String,
           ["output_text", "text"].contains(type),
           let text = dictionary["text"] as? String {
            parts.append(text)
        }

        for key in ["output", "content", "message"] {
            if let child = dictionary[key] {
                parts.append(contentsOf: extractText(from: child))
            }
        }

        return parts
    }

    private func friendlyErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 非 JSON 响应体（空 body、HTML 错误页）：空/纯空白归一为 nil，
            // 让调用方回落到带状态码的兜底文案，而不是抛出空白错误。
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }

        return friendlyErrorMessage(fromJSON: json)
    }

    private func friendlyErrorMessage(fromJSON json: [String: Any]) -> String? {
        let response = json["response"] as? [String: Any]
        let error = (json["error"] as? [String: Any]) ?? (response?["error"] as? [String: Any])
        let type = error?["type"] as? String
        let message = error?["message"] as? String

        guard error != nil else {
            return nil
        }

        if type == "usage_limit_reached" {
            if let seconds = error?["resets_in_seconds"] as? Int, seconds > 0 {
                let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
                return "已达到 ChatGPT/Codex 使用上限，约 \(minutes) 分钟后恢复。"
            }
            return "已达到 ChatGPT/Codex 使用上限，请稍后再试。"
        }

        if let message, !message.isEmpty {
            return "Codex 返回错误：\(message)"
        }

        return nil
    }

    private func withTimeout<T>(
        seconds: UInt64,
        timeoutMessage: String? = nil,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if let timeoutMessage {
                    throw AppError.network(timeoutMessage)
                }
                let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
                throw AppError.network("Codex 超过 \(minutes) 分钟仍未返回。可以中断任务，或在偏好设置里降低 Thinking 智能程度后重试。")
            }

            guard let result = try await group.next() else {
                throw AppError.network("Codex 请求没有返回结果。")
            }
            group.cancelAll()
            return result
        }
    }
}
