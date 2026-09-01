import XCTest
@testable import CatGPT

final class OAuthAndLLMClientTests: XCTestCase {
    func testNeedsRefreshUsesSixtySecondBuffer() {
        let now = Date().timeIntervalSince1970

        XCTAssertFalse(CodexOAuthCredentials(access: "a", refresh: "r", expires: now + 61, accountId: "id").needsRefresh)
        XCTAssertTrue(CodexOAuthCredentials(access: "a", refresh: "r", expires: now + 60, accountId: "id").needsRefresh)
    }

    func testTokenResponseParserAcceptsFallbackRefreshAndReadsAccountId() throws {
        let jwt = makeJWT(accountId: "account-123")
        let payload = """
        {"access_token":"\(jwt)","expires_in":3600}
        """
        let credentials = try CodexOAuthClient.parseTokenResponse(
            data: Data(payload.utf8),
            statusCode: 200,
            fallbackRefreshToken: "fallback-refresh"
        )

        XCTAssertEqual(credentials.access, jwt)
        XCTAssertEqual(credentials.refresh, "fallback-refresh")
        XCTAssertEqual(credentials.accountId, "account-123")
    }

    func testTokenResponseParserThrowsForMissingRequiredFields() {
        let payload = #"{"access_token":"abc"}"#

        XCTAssertThrowsError(
            try CodexOAuthClient.parseTokenResponse(
                data: Data(payload.utf8),
                statusCode: 200,
                fallbackRefreshToken: nil
            )
        ) { error in
            XCTAssertAppError(error, equals: .response("登录响应缺少必要凭证字段。"))
        }
    }

    func testTokenResponseParserTreatsFlatAndNestedInvalidGrantAsAuthExpired() {
        let flat = #"{"error":"invalid_grant"}"#
        let nested = #"{"error":{"code":"token_expired"}}"#

        XCTAssertThrowsError(
            try CodexOAuthClient.parseTokenResponse(
                data: Data(flat.utf8),
                statusCode: 400,
                fallbackRefreshToken: nil
            )
        ) { error in
            XCTAssertAppError(error, equals: .authExpired("ChatGPT 登录已失效，请重新登录。"))
        }

        XCTAssertThrowsError(
            try CodexOAuthClient.parseTokenResponse(
                data: Data(nested.utf8),
                statusCode: 400,
                fallbackRefreshToken: nil
            )
        ) { error in
            XCTAssertAppError(error, equals: .authExpired("ChatGPT 登录已失效，请重新登录。"))
        }
    }

    func testLLMClientRefreshesAfter401AndEmitsStreamingEvents() async throws {
        let recorder = EventRecorder()
        let refreshCallCount = LockedCounter()
        let session = makeSession(
            responses: [
                .http(statusCode: 401, body: #"{"error":"invalid_token"}"#),
                .stream(events: [
                    #"data: {"type":"response.reasoning.delta"}"#,
                    #"data: {"type":"response.output_text.delta","delta":"Hel"}"#,
                    #"data: {"type":"response.output_text.delta","delta":"lo"}"#,
                    #"data: {"type":"response.output_text.done","text":"Hello!"}"#,
                    #"data: {"type":"response.completed"}"#,
                    "data: [DONE]"
                ])
            ]
        )

        let client = LLMClient(
            config: makeConfig(),
            session: session,
            onCredentialsRefreshed: { _ in },
            refreshCredentials: { credentials in
                refreshCallCount.increment()
                return CodexOAuthCredentials(
                    access: "refreshed-access",
                    refresh: credentials.refresh,
                    expires: Date().timeIntervalSince1970 + 3600,
                    accountId: credentials.accountId
                )
            }
        )

        let result = try await client.analyze(imageData: Data([0x01])) { recorder.record($0) }

        XCTAssertEqual(result, "Hello!")
        XCTAssertEqual(refreshCallCount.value, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(recorder.events, [.connected, .reasoning, .delta("Hel"), .delta("Hello")])
    }

    func testLLMClientUsesOpenAICompatibleStreamingWithoutCodexCredentials() async throws {
        let recorder = EventRecorder()
        let client = LLMClient(
            config: makeConfig(provider: .openAICompatible),
            session: makeSession(responses: [
                .stream(events: [
                    #"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#,
                    #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
                    #"data: {"choices":[{"delta":{"content":"!"}}]}"#,
                    "data: [DONE]"
                ])
            ])
        )

        let result = try await client.analyze(imageData: Data([0x01])) { recorder.record($0) }

        XCTAssertEqual(result, "Hello!")
        XCTAssertEqual(recorder.events, [.connected, .reasoning, .delta("Hello"), .delta("Hello!")])
    }

    func testLLMClientAcceptsOpenAICompatibleJSONResponse() async throws {
        let recorder = EventRecorder()
        let client = LLMClient(
            config: makeConfig(provider: .openAICompatible),
            session: makeSession(responses: [
                .http(
                    statusCode: 200,
                    body: #"{"choices":[{"message":{"content":"JSON answer"}}]}"#
                )
            ])
        )

        let result = try await client.analyze(imageData: Data([0x01])) { recorder.record($0) }

        XCTAssertEqual(result, "JSON answer")
        XCTAssertEqual(recorder.events, [.connected, .delta("JSON answer")])
    }

    func testLLMClientAcceptsJSONWhenGatewayLabelsResponseAsSSE() async throws {
        let client = LLMClient(
            config: makeConfig(provider: .openAICompatible),
            session: makeSession(responses: [
                .http(
                    statusCode: 200,
                    body: #"{"choices":[{"message":{"content":"JSON answer"}}]}"#,
                    contentType: "text/event-stream"
                )
            ])
        )

        let result = try await client.analyze(imageData: Data([0x01]))

        XCTAssertEqual(result, "JSON answer")
    }

    func testLLMClientAcceptsContentPartArrayResponse() async throws {
        let client = LLMClient(
            config: makeConfig(provider: .openAICompatible),
            session: makeSession(responses: [
                .http(
                    statusCode: 200,
                    body: #"{"choices":[{"message":{"content":[{"type":"text","text":"part one "},{"type":"text","text":"part two"}]}}]}"#
                )
            ])
        )

        let result = try await client.analyze(imageData: Data([0x01]))

        XCTAssertEqual(result, "part one part two")
    }

    func testOpenAICompatibleVerificationUsesNonStreamingRequestAndBearerKey() async throws {
        let client = LLMClient(
            config: makeConfig(provider: .openAICompatible),
            session: makeSession(responses: [
                .http(statusCode: 200, body: #"{"choices":[{"message":{"content":"OK"}}]}"#)
            ])
        )

        try await client.verifyConnection()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

    }

    func testOpenAICompatibleVerificationSurfacesHTTPError() async throws {
        let client = LLMClient(
            config: makeConfig(provider: .openAICompatible),
            session: makeSession(responses: [
                .http(statusCode: 401, body: #"{"error":{"message":"invalid api key"}}"#)
            ])
        )

        do {
            try await client.verifyConnection()
            XCTFail("expected verification error")
        } catch let error as AppError {
            XCTAssertAppError(error, equals: .response("外部 LLM 返回错误：invalid api key"))
        }
    }

    func testLLMClientThrowsWhenStreamEndsWithoutText() async throws {
        let client = LLMClient(
            config: makeConfig(),
            session: makeSession(responses: [.stream(events: ["data: {\"type\":\"response.completed\"}"])])
        )

        do {
            _ = try await client.analyze(imageData: Data([0x01]))
            XCTFail("expected response error")
        } catch let error as AppError {
            XCTAssertAppError(error, equals: .response("Codex 返回中没有可显示文本。"))
        }
    }

    func testLLMClientThrowsForResponseFailedEvent() async throws {
        let client = LLMClient(
            config: makeConfig(),
            session: makeSession(responses: [.stream(events: ["data: {\"type\":\"response.failed\"}"])])
        )

        do {
            _ = try await client.analyze(imageData: Data([0x01]))
            XCTFail("expected response error")
        } catch let error as AppError {
            XCTAssertAppError(error, equals: .response("Codex 处理失败（response.failed），请重试。"))
        }
    }

    func testLLMClientSurfacesServiceErrorBody() async throws {
        let client = LLMClient(
            config: makeConfig(),
            session: makeSession(responses: [.http(statusCode: 500, body: #"{"error":{"message":"boom"}}"#)])
        )

        do {
            _ = try await client.analyze(imageData: Data([0x01]))
            XCTFail("expected response error")
        } catch let error as AppError {
            XCTAssertAppError(error, equals: .response("Codex 返回错误：boom"))
        }
    }

    private func makeConfig(provider: LLMProvider = .codex) -> AppConfig {
        AppConfig(
            provider: provider,
            codexCredentials: provider == .codex
                ? CodexOAuthCredentials(access: "access", refresh: "refresh", expires: 9_999_999_999, accountId: "account")
                : nil,
            customBaseURL: "https://example.com/v1",
            customAPIKey: "key",
            model: "gpt-5.6-terra", thinkingEnabled: true, reasoningEffort: .medium,
            reasoningSummary: .none, textVerbosity: .low, serviceTier: .systemDefault,
            maxOutputTokens: 0, outputDisplayMode: .floatingPanel, touchBarFontSize: 14,
            touchBarTextColor: .system, touchBarTextIntensity: 1, touchBarTextAlignment: .center,
            prompt: "测试提示词", instructions: "测试指令", maxImageEdge: 1600
        )
    }

    private func makeSession(responses: [StubURLProtocol.Response]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.responses = responses
        StubURLProtocol.requestCount = 0
        StubURLProtocol.requests = []
        return URLSession(configuration: configuration)
    }

    private func makeJWT(accountId: String) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString()
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountId)"}}"#.utf8).base64URLEncodedString()
        return "\(header).\(payload).signature"
    }

    private func XCTAssertAppError(_ error: Error, equals expected: AppError, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = error as? AppError else {
            XCTFail("expected AppError, got \(error)", file: file, line: line)
            return
        }

        switch (actual, expected) {
        case (.configuration(let a), .configuration(let b)),
             (.hotKey(let a), .hotKey(let b)),
             (.screenshot(let a), .screenshot(let b)),
             (.network(let a), .network(let b)),
             (.response(let a), .response(let b)),
             (.authExpired(let a), .authExpired(let b)):
            XCTAssertEqual(a, b, file: file, line: line)
        default:
            XCTFail("expected \(expected), got \(actual)", file: file, line: line)
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [LLMStreamEvent] = []

    func record(_ event: LLMStreamEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class StubURLProtocol: URLProtocol {
    struct Response {
        enum Kind {
            case http(statusCode: Int, body: String, contentType: String)
            case stream(events: [String])
        }

        let kind: Kind

        static func http(statusCode: Int, body: String, contentType: String = "application/json") -> Self {
            Self(kind: .http(statusCode: statusCode, body: body, contentType: contentType))
        }

        static func stream(events: [String]) -> Self {
            Self(kind: .stream(events: events))
        }
    }

    static var responses: [Response] = []
    static var requestCount = 0
    static var requests: [URLRequest] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        guard !Self.responses.isEmpty else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
            return
        }
        Self.requestCount += 1
        Self.requests.append(request)
        let response = Self.responses.removeFirst()
        Self.lock.unlock()

        switch response.kind {
        case .http(let statusCode, let body, let contentType):
            let httpResponse = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)

        case .stream(let events):
            let httpResponse = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((events.joined(separator: "\n") + "\n").utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
