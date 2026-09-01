import CoreGraphics
import Foundation
import LocalAuthentication
import Security

enum LLMProvider: String, CaseIterable, Identifiable {
    case codex
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "ChatGPT / Codex"
        case .openAICompatible: return "OpenAI 兼容 API"
        }
    }
}

struct AppConfig {
    let provider: LLMProvider
    let codexCredentials: CodexOAuthCredentials?
    let customBaseURL: String
    let customAPIKey: String
    let model: String
    let thinkingEnabled: Bool
    let reasoningEffort: ReasoningEffort
    let reasoningSummary: ReasoningSummary
    let textVerbosity: TextVerbosity
    let serviceTier: ServiceTier
    let maxOutputTokens: Int
    let outputDisplayMode: OutputDisplayMode
    let touchBarFontSize: Double
    let touchBarTextColor: TouchBarTextColor
    let touchBarTextIntensity: Double
    let touchBarTextAlignment: TouchBarTextAlignment
    let prompt: String
    let instructions: String
    let maxImageEdge: Int

    init(
        provider: LLMProvider = .codex,
        codexCredentials: CodexOAuthCredentials? = nil,
        customBaseURL: String = "",
        customAPIKey: String = "",
        model: String,
        thinkingEnabled: Bool,
        reasoningEffort: ReasoningEffort,
        reasoningSummary: ReasoningSummary,
        textVerbosity: TextVerbosity,
        serviceTier: ServiceTier,
        maxOutputTokens: Int,
        outputDisplayMode: OutputDisplayMode,
        touchBarFontSize: Double,
        touchBarTextColor: TouchBarTextColor,
        touchBarTextIntensity: Double,
        touchBarTextAlignment: TouchBarTextAlignment,
        prompt: String,
        instructions: String,
        maxImageEdge: Int
    ) {
        self.provider = provider
        self.codexCredentials = codexCredentials
        self.customBaseURL = customBaseURL
        self.customAPIKey = customAPIKey
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.textVerbosity = textVerbosity
        self.serviceTier = serviceTier
        self.maxOutputTokens = maxOutputTokens
        self.outputDisplayMode = outputDisplayMode
        self.touchBarFontSize = touchBarFontSize
        self.touchBarTextColor = touchBarTextColor
        self.touchBarTextIntensity = touchBarTextIntensity
        self.touchBarTextAlignment = touchBarTextAlignment
        self.prompt = prompt
        self.instructions = instructions
        self.maxImageEdge = maxImageEdge
    }

    static func load() throws -> AppConfig {
        try ConfigDraft.load().makeConfig()
    }
}

struct ConfigDraft: Equatable {
    var provider: LLMProvider
    var customBaseURL: String
    var customAPIKey: String
    var model: String
    var thinkingEnabled: Bool
    var reasoningEffort: ReasoningEffort
    var reasoningSummary: ReasoningSummary
    var textVerbosity: TextVerbosity
    var serviceTier: ServiceTier
    var maxOutputTokens: Int
    var outputDisplayMode: OutputDisplayMode
    var touchBarFontSize: Double
    var touchBarTextColor: TouchBarTextColor
    var touchBarTextIntensity: Double
    var touchBarTextAlignment: TouchBarTextAlignment
    var prompt: String
    var instructions: String
    var hotKeyText: String
    var selectionHotKeyText: String
    var panelHotKeyText: String
    var captureRegionHotKeyText: String
    var batchCaptureHotKeyText: String
    var maxImageEdge: Int
    var captureRegionEnabled: Bool
    var captureRegionX: Double
    var captureRegionY: Double
    var captureRegionWidth: Double
    var captureRegionHeight: Double
    var panelOpacity: Double
    var panelTextOpacity: Double
    var panelTextColor: TouchBarTextColor
    var panelFontSize: Double
    var panelWidth: Int
    var panelHeight: Int
    var panelOriginX: Double?
    var panelOriginY: Double?

    /// gpt-5.6-terra：官方定位的日常默认档（性能≈gpt-5.5、更快更省额度）；
    /// 复杂问题可在设置里切 gpt-5.6-sol（旗舰）。
    static let defaultModel = "gpt-5.6-terra"

    /// 设置界面的模型快捷选择（2026-07 经 ChatGPT OAuth 可用的多模态模型；
    /// gpt-5.3-codex-spark 为纯文本模型不支持图片输入，故不列入）。
    static let suggestedModels: [(id: String, hint: String)] = [
        ("gpt-5.6-sol", "旗舰 · 最强推理"),
        ("gpt-5.6-terra", "日常均衡 · 推荐"),
        ("gpt-5.6-luna", "最快最省"),
        ("gpt-5.5", "上一代旗舰")
    ]

    static func isSupportedModel(_ value: String) -> Bool {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return suggestedModels.contains { $0.id == model }
    }
    static let defaultThinkingEnabled = true
    static let defaultReasoningEffort: ReasoningEffort = .medium
    static let defaultReasoningSummary: ReasoningSummary = .none
    static let defaultTextVerbosity: TextVerbosity = .low
    static let defaultServiceTier: ServiceTier = .systemDefault
    static let defaultMaxOutputTokens = 0
    static let defaultOutputDisplayMode: OutputDisplayMode = .floatingPanel
    static let defaultTouchBarFontSize = 14.0
    static let defaultTouchBarTextColor: TouchBarTextColor = .system
    static let defaultTouchBarTextIntensity = 1.0
    static let defaultTouchBarTextAlignment: TouchBarTextAlignment = .center
    static let defaultPrompt = "请分析这张截图，并用中文简洁回答。"
    static let defaultInstructions = "你是一个简洁、准确的中文屏幕分析助手。"
    static let defaultHotKey = "cmd double tap"
    static let defaultSelectionHotKey = "ctrl double tap"
    static let defaultPanelHotKey = "opt double tap"
    static let defaultCaptureRegionHotKey = "cmd+e"
    static let defaultBatchCaptureHotKey = "shift double tap"
    static let defaultMaxImageEdge = 1600
    static let defaultCaptureRegionEnabled = false
    static let defaultPanelOpacity = 0.94
    static let defaultPanelTextOpacity = 1.0
    static let defaultPanelTextColor: TouchBarTextColor = .system
    static let defaultPanelFontSize = 14.0
    static let defaultPanelWidth = 520
    static let defaultPanelHeight = 320

    private static let shortcutDefaultsMigrationVersion = 1
    private static let captureRegionShortcutMigrationVersion = 1
    private static let legacyDefaultHotKey = "cmd+shift+l"
    private static let legacyDefaultSelectionHotKey = "cmd+shift+k"
    private static let legacyDefaultPanelHotKey = "cmd+shift+o"
    private static let legacyDefaultCaptureRegionHotKey = "shift double tap"

    static func load() -> ConfigDraft {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        migrateLegacyShortcutDefaultsIfNeeded(defaults)
        migrateCaptureRegionShortcutDefaultIfNeeded(defaults)
        let storedPrompt = defaults.string(forKey: Keys.prompt)
        let prompt = storedPrompt == "Analyze this screenshot and answer concisely." ? defaultPrompt : storedPrompt

        let storedModel = defaults.string(forKey: Keys.model)
        let model: String?
        switch storedModel {
        case "gpt-4o-mini":
            // 历史默认值迁移到当前默认模型；gpt-5.5 仍是可选模型，不能迁移。
            model = defaultModel
        case "gpt-5.6":
            // 裸 "gpt-5.6" 不是有效 ID（有效：gpt-5.6-sol/terra/luna），
            // 按旗舰意图迁移到 sol。
            model = "gpt-5.6-sol"
        default:
            model = storedModel
        }

        return ConfigDraft(
            provider: LLMProvider(
                rawValue: defaults.string(forKey: Keys.provider)
                    ?? env["SCREEN_LLM_PROVIDER"]
                    ?? LLMProvider.codex.rawValue
            ) ?? .codex,
            customBaseURL: defaults.string(forKey: Keys.customBaseURL)
                ?? env["SCREEN_LLM_BASE_URL"]
                ?? "",
            customAPIKey: KeychainStore.readOpenAIAPIKey()
                ?? env["SCREEN_LLM_API_KEY"]
                ?? "",
            model: model
                ?? env["SCREEN_LLM_MODEL"]
                ?? defaultModel,
            thinkingEnabled: defaults.object(forKey: Keys.thinkingEnabled) == nil
                ? parseBool(env["SCREEN_LLM_THINKING"]) ?? defaultThinkingEnabled
                : defaults.bool(forKey: Keys.thinkingEnabled),
            reasoningEffort: ReasoningEffort(
                rawValue: defaults.string(forKey: Keys.reasoningEffort)
                    ?? env["SCREEN_LLM_REASONING_EFFORT"]
                    ?? defaultReasoningEffort.rawValue
            ) ?? defaultReasoningEffort,
            reasoningSummary: ReasoningSummary(
                rawValue: defaults.string(forKey: Keys.reasoningSummary)
                    ?? env["SCREEN_LLM_REASONING_SUMMARY"]
                    ?? defaultReasoningSummary.rawValue
            ) ?? defaultReasoningSummary,
            textVerbosity: TextVerbosity(
                rawValue: defaults.string(forKey: Keys.textVerbosity)
                    ?? env["SCREEN_LLM_TEXT_VERBOSITY"]
                    ?? defaultTextVerbosity.rawValue
            ) ?? defaultTextVerbosity,
            serviceTier: ServiceTier(
                rawValue: defaults.string(forKey: Keys.serviceTier)
                    ?? env["SCREEN_LLM_SERVICE_TIER"]
                    ?? defaultServiceTier.rawValue
            ) ?? defaultServiceTier,
            maxOutputTokens: defaults.object(forKey: Keys.maxOutputTokens) == nil
                ? Int(env["SCREEN_LLM_MAX_OUTPUT_TOKENS"] ?? "") ?? defaultMaxOutputTokens
                : defaults.integer(forKey: Keys.maxOutputTokens),
            outputDisplayMode: OutputDisplayMode(
                rawValue: defaults.string(forKey: Keys.outputDisplayMode)
                    ?? env["SCREEN_LLM_OUTPUT_DISPLAY_MODE"]
                    ?? defaultOutputDisplayMode.rawValue
            ) ?? defaultOutputDisplayMode,
            touchBarFontSize: defaults.object(forKey: Keys.touchBarFontSize) == nil
                ? Double(env["SCREEN_LLM_TOUCHBAR_FONT_SIZE"] ?? "") ?? defaultTouchBarFontSize
                : defaults.double(forKey: Keys.touchBarFontSize),
            touchBarTextColor: TouchBarTextColor(
                rawValue: defaults.string(forKey: Keys.touchBarTextColor)
                    ?? env["SCREEN_LLM_TOUCHBAR_TEXT_COLOR"]
                    ?? defaultTouchBarTextColor.rawValue
            ) ?? defaultTouchBarTextColor,
            touchBarTextIntensity: defaults.object(forKey: Keys.touchBarTextIntensity) == nil
                ? Double(env["SCREEN_LLM_TOUCHBAR_TEXT_INTENSITY"] ?? "") ?? defaultTouchBarTextIntensity
                : defaults.double(forKey: Keys.touchBarTextIntensity),
            touchBarTextAlignment: TouchBarTextAlignment(
                rawValue: defaults.string(forKey: Keys.touchBarTextAlignment)
                    ?? env["SCREEN_LLM_TOUCHBAR_TEXT_ALIGNMENT"]
                    ?? defaultTouchBarTextAlignment.rawValue
            ) ?? defaultTouchBarTextAlignment,
            prompt: prompt
                ?? env["SCREEN_LLM_PROMPT"]
                ?? defaultPrompt,
            instructions: defaults.string(forKey: Keys.instructions)
                ?? env["SCREEN_LLM_INSTRUCTIONS"]
                ?? defaultInstructions,
            hotKeyText: defaults.string(forKey: Keys.hotKey)
                ?? env["SCREEN_LLM_HOTKEY"]
                ?? defaultHotKey,
            selectionHotKeyText: defaults.string(forKey: Keys.selectionHotKey)
                ?? env["SCREEN_LLM_SELECTION_HOTKEY"]
                ?? defaultSelectionHotKey,
            panelHotKeyText: defaults.string(forKey: Keys.panelHotKey)
                ?? env["SCREEN_LLM_PANEL_HOTKEY"]
                ?? defaultPanelHotKey,
            captureRegionHotKeyText: defaults.string(forKey: Keys.captureRegionHotKey)
                ?? env["SCREEN_LLM_CAPTURE_REGION_HOTKEY"]
                ?? defaultCaptureRegionHotKey,
            batchCaptureHotKeyText: defaults.string(forKey: Keys.batchCaptureHotKey)
                ?? env["SCREEN_LLM_BATCH_CAPTURE_HOTKEY"]
                ?? defaultBatchCaptureHotKey,
            maxImageEdge: defaults.object(forKey: Keys.maxImageEdge) == nil
                ? Int(env["SCREEN_LLM_MAX_IMAGE_EDGE"] ?? "") ?? defaultMaxImageEdge
                : defaults.integer(forKey: Keys.maxImageEdge),
            captureRegionEnabled: defaults.object(forKey: Keys.captureRegionEnabled) == nil
                ? parseBool(env["SCREEN_LLM_CAPTURE_REGION_ENABLED"]) ?? defaultCaptureRegionEnabled
                : defaults.bool(forKey: Keys.captureRegionEnabled),
            captureRegionX: defaults.object(forKey: Keys.captureRegionX) == nil
                ? Double(env["SCREEN_LLM_CAPTURE_REGION_X"] ?? "") ?? 0
                : defaults.double(forKey: Keys.captureRegionX),
            captureRegionY: defaults.object(forKey: Keys.captureRegionY) == nil
                ? Double(env["SCREEN_LLM_CAPTURE_REGION_Y"] ?? "") ?? 0
                : defaults.double(forKey: Keys.captureRegionY),
            captureRegionWidth: defaults.object(forKey: Keys.captureRegionWidth) == nil
                ? Double(env["SCREEN_LLM_CAPTURE_REGION_WIDTH"] ?? "") ?? 0
                : defaults.double(forKey: Keys.captureRegionWidth),
            captureRegionHeight: defaults.object(forKey: Keys.captureRegionHeight) == nil
                ? Double(env["SCREEN_LLM_CAPTURE_REGION_HEIGHT"] ?? "") ?? 0
                : defaults.double(forKey: Keys.captureRegionHeight),
            panelOpacity: defaults.object(forKey: Keys.panelOpacity) == nil
                ? Double(env["SCREEN_LLM_PANEL_OPACITY"] ?? "") ?? defaultPanelOpacity
                : defaults.double(forKey: Keys.panelOpacity),
            panelTextOpacity: defaults.object(forKey: Keys.panelTextOpacity) == nil
                ? Double(env["SCREEN_LLM_PANEL_TEXT_OPACITY"] ?? "") ?? defaultPanelTextOpacity
                : defaults.double(forKey: Keys.panelTextOpacity),
            panelTextColor: TouchBarTextColor(
                rawValue: defaults.string(forKey: Keys.panelTextColor)
                    ?? env["SCREEN_LLM_PANEL_TEXT_COLOR"]
                    ?? defaultPanelTextColor.rawValue
            ) ?? defaultPanelTextColor,
            panelFontSize: defaults.object(forKey: Keys.panelFontSize) == nil
                ? Double(env["SCREEN_LLM_PANEL_FONT_SIZE"] ?? "") ?? defaultPanelFontSize
                : defaults.double(forKey: Keys.panelFontSize),
            panelWidth: defaults.object(forKey: Keys.panelWidth) == nil
                ? Int(env["SCREEN_LLM_PANEL_WIDTH"] ?? "") ?? defaultPanelWidth
                : defaults.integer(forKey: Keys.panelWidth),
            panelHeight: defaults.object(forKey: Keys.panelHeight) == nil
                ? Int(env["SCREEN_LLM_PANEL_HEIGHT"] ?? "") ?? defaultPanelHeight
                : defaults.integer(forKey: Keys.panelHeight),
            panelOriginX: defaults.object(forKey: Keys.panelOriginX) == nil
                ? nil
                : defaults.double(forKey: Keys.panelOriginX),
            panelOriginY: defaults.object(forKey: Keys.panelOriginY) == nil
                ? nil
                : defaults.double(forKey: Keys.panelOriginY)
        )
    }

    private static func migrateLegacyShortcutDefaultsIfNeeded(_ defaults: UserDefaults) {
        guard defaults.integer(forKey: Keys.shortcutDefaultsMigrationVersion) < shortcutDefaultsMigrationVersion else {
            return
        }

        let migrations = [
            (Keys.hotKey, legacyDefaultHotKey, defaultHotKey),
            (Keys.selectionHotKey, legacyDefaultSelectionHotKey, defaultSelectionHotKey),
            (Keys.panelHotKey, legacyDefaultPanelHotKey, defaultPanelHotKey)
        ]

        for (key, legacyValue, replacement) in migrations {
            if defaults.string(forKey: key) == legacyValue {
                defaults.set(replacement, forKey: key)
            }
        }

        defaults.set(shortcutDefaultsMigrationVersion, forKey: Keys.shortcutDefaultsMigrationVersion)
    }

    private static func migrateCaptureRegionShortcutDefaultIfNeeded(_ defaults: UserDefaults) {
        guard defaults.integer(forKey: Keys.captureRegionShortcutMigrationVersion) < captureRegionShortcutMigrationVersion else {
            return
        }
        if defaults.string(forKey: Keys.captureRegionHotKey) == legacyDefaultCaptureRegionHotKey {
            defaults.set(defaultCaptureRegionHotKey, forKey: Keys.captureRegionHotKey)
        }
        defaults.set(captureRegionShortcutMigrationVersion, forKey: Keys.captureRegionShortcutMigrationVersion)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(customBaseURL, forKey: Keys.customBaseURL)
        KeychainStore.saveOpenAIAPIKeyAsync(customAPIKey)
        defaults.set(model, forKey: Keys.model)
        defaults.set(thinkingEnabled, forKey: Keys.thinkingEnabled)
        defaults.set(reasoningEffort.rawValue, forKey: Keys.reasoningEffort)
        defaults.set(reasoningSummary.rawValue, forKey: Keys.reasoningSummary)
        defaults.set(textVerbosity.rawValue, forKey: Keys.textVerbosity)
        defaults.set(serviceTier.rawValue, forKey: Keys.serviceTier)
        defaults.set(maxOutputTokens, forKey: Keys.maxOutputTokens)
        defaults.set(outputDisplayMode.rawValue, forKey: Keys.outputDisplayMode)
        defaults.set(touchBarFontSize, forKey: Keys.touchBarFontSize)
        defaults.set(touchBarTextColor.rawValue, forKey: Keys.touchBarTextColor)
        defaults.set(touchBarTextIntensity, forKey: Keys.touchBarTextIntensity)
        defaults.set(touchBarTextAlignment.rawValue, forKey: Keys.touchBarTextAlignment)
        defaults.set(prompt, forKey: Keys.prompt)
        defaults.set(instructions, forKey: Keys.instructions)
        defaults.set(hotKeyText, forKey: Keys.hotKey)
        defaults.set(selectionHotKeyText, forKey: Keys.selectionHotKey)
        defaults.set(panelHotKeyText, forKey: Keys.panelHotKey)
        defaults.set(captureRegionHotKeyText, forKey: Keys.captureRegionHotKey)
        defaults.set(batchCaptureHotKeyText, forKey: Keys.batchCaptureHotKey)
        defaults.set(maxImageEdge, forKey: Keys.maxImageEdge)
        defaults.set(captureRegionEnabled, forKey: Keys.captureRegionEnabled)
        defaults.set(captureRegionX, forKey: Keys.captureRegionX)
        defaults.set(captureRegionY, forKey: Keys.captureRegionY)
        defaults.set(captureRegionWidth, forKey: Keys.captureRegionWidth)
        defaults.set(captureRegionHeight, forKey: Keys.captureRegionHeight)
        defaults.set(panelOpacity, forKey: Keys.panelOpacity)
        defaults.set(panelTextOpacity, forKey: Keys.panelTextOpacity)
        defaults.set(panelTextColor.rawValue, forKey: Keys.panelTextColor)
        defaults.set(panelFontSize, forKey: Keys.panelFontSize)
        defaults.set(panelWidth, forKey: Keys.panelWidth)
        defaults.set(panelHeight, forKey: Keys.panelHeight)
        if let panelOriginX {
            defaults.set(panelOriginX, forKey: Keys.panelOriginX)
        } else {
            defaults.removeObject(forKey: Keys.panelOriginX)
        }
        if let panelOriginY {
            defaults.set(panelOriginY, forKey: Keys.panelOriginY)
        } else {
            defaults.removeObject(forKey: Keys.panelOriginY)
        }
    }

    func makeConfig() throws -> AppConfig {
        try makeConfig(codexCredentials: KeychainStore.readCodexCredentials())
    }

    func makeConfig(codexCredentials: CodexOAuthCredentials? = KeychainStore.readCodexCredentials()) throws -> AppConfig {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw AppError.configuration("模型不能为空。")
        }

        let trimmedBaseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .codex:
            guard codexCredentials != nil else {
                throw AppError.configuration("请先登录 ChatGPT/Codex。")
            }
            guard Self.isSupportedModel(trimmedModel) else {
                throw AppError.configuration("模型输入有误。")
            }
        case .openAICompatible:
            guard LLMClient.resolveOpenAICompatibleEndpoint(trimmedBaseURL) != nil else {
                throw AppError.configuration("OpenAI 兼容 API 地址无效。")
            }
        }

        return AppConfig(
            provider: provider,
            codexCredentials: codexCredentials,
            customBaseURL: trimmedBaseURL,
            customAPIKey: customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: trimmedModel,
            thinkingEnabled: thinkingEnabled,
            reasoningEffort: reasoningEffort,
            reasoningSummary: reasoningSummary,
            textVerbosity: textVerbosity,
            serviceTier: serviceTier,
            maxOutputTokens: max(0, maxOutputTokens),
            outputDisplayMode: outputDisplayMode,
            touchBarFontSize: min(24, max(10, touchBarFontSize)),
            touchBarTextColor: touchBarTextColor,
            touchBarTextIntensity: min(1.0, max(0.35, touchBarTextIntensity)),
            touchBarTextAlignment: touchBarTextAlignment,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultPrompt : prompt,
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultInstructions : instructions,
            maxImageEdge: max(640, maxImageEdge)
        )
    }

    func makeShortcut() throws -> Shortcut {
        try Shortcut.parse(hotKeyText)
    }

    func makePanelShortcut() throws -> Shortcut {
        try Shortcut.parse(panelHotKeyText)
    }

    func makeSelectionShortcut() throws -> Shortcut {
        try Shortcut.parse(selectionHotKeyText)
    }

    func makeCaptureRegionShortcut() throws -> Shortcut {
        try Shortcut.parse(captureRegionHotKeyText)
    }

    func makeBatchCaptureShortcut() throws -> Shortcut {
        try Shortcut.parse(batchCaptureHotKeyText)
    }

    var normalizedPanelOpacity: Double {
        min(1.0, max(0.0, panelOpacity))
    }

    var normalizedPanelTextOpacity: Double {
        min(1.0, max(0.0, panelTextOpacity))
    }

    var normalizedPanelFontSize: Double {
        min(28, max(10, panelFontSize))
    }

    var captureRegion: CGRect? {
        guard captureRegionEnabled,
              captureRegionWidth >= 12,
              captureRegionHeight >= 12 else {
            return nil
        }
        return CGRect(
            x: captureRegionX,
            y: captureRegionY,
            width: captureRegionWidth,
            height: captureRegionHeight
        )
    }

    var normalizedPanelWidth: Int {
        min(900, max(120, panelWidth))
    }

    var normalizedPanelHeight: Int {
        min(720, max(42, panelHeight))
    }

    var normalizedTouchBarFontSize: Double {
        min(24, max(10, touchBarFontSize))
    }

    /// 与 makeConfig 的下限一致；防止用户存入 0/负数把截图压成 1×1。
    var normalizedMaxImageEdge: Int {
        max(640, maxImageEdge)
    }

    var normalizedTouchBarTextIntensity: Double {
        min(1.0, max(0.35, touchBarTextIntensity))
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}

enum OutputDisplayMode: String, CaseIterable, Identifiable {
    case floatingPanel
    case touchBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floatingPanel: return "悬浮窗"
        case .touchBar: return "Touch Bar"
        }
    }
}

enum TouchBarTextColor: String, CaseIterable, Identifiable {
    case system
    case white
    case black
    case gray
    case blue
    case green
    case yellow
    case red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .white: return "白色"
        case .black: return "黑色"
        case .gray: return "灰色"
        case .blue: return "蓝色"
        case .green: return "绿色"
        case .yellow: return "黄色"
        case .red: return "红色"
        }
    }
}

enum TouchBarTextAlignment: String, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: return "左"
        case .center: return "中"
        case .trailing: return "右"
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Identifiable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: return "极低"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "超高"
        }
    }
}

enum ReasoningSummary: String, CaseIterable, Identifiable {
    case none
    case auto
    case concise
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "关闭"
        case .auto: return "自动"
        case .concise: return "简短"
        case .detailed: return "详细"
        }
    }

    var requestValue: String? {
        self == .none ? nil : rawValue
    }
}

enum TextVerbosity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "简洁"
        case .medium: return "标准"
        case .high: return "详细"
        }
    }
}

enum ServiceTier: String, CaseIterable, Identifiable {
    case systemDefault = ""
    case auto
    case `default` = "default"
    case flex
    case scale
    case priority

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemDefault: return "系统默认"
        case .auto: return "自动"
        case .default: return "默认"
        case .flex: return "Flex"
        case .scale: return "Scale"
        case .priority: return "Priority"
        }
    }

    var requestValue: String? {
        rawValue.isEmpty ? nil : rawValue
    }
}

private enum Keys {
    static let provider = "catGPT.provider"
    static let customBaseURL = "catGPT.customBaseURL"
    static let model = "catGPT.model"
    static let thinkingEnabled = "catGPT.thinkingEnabled"
    static let reasoningEffort = "catGPT.reasoningEffort"
    static let reasoningSummary = "catGPT.reasoningSummary"
    static let textVerbosity = "catGPT.textVerbosity"
    static let serviceTier = "catGPT.serviceTier"
    static let maxOutputTokens = "catGPT.maxOutputTokens"
    static let outputDisplayMode = "catGPT.outputDisplayMode"
    static let touchBarFontSize = "catGPT.touchBarFontSize"
    static let touchBarTextColor = "catGPT.touchBarTextColor"
    static let touchBarTextIntensity = "catGPT.touchBarTextIntensity"
    static let touchBarTextAlignment = "catGPT.touchBarTextAlignment"
    static let prompt = "catGPT.prompt"
    static let instructions = "catGPT.instructions"
    static let hotKey = "catGPT.hotKey"
    static let selectionHotKey = "catGPT.selectionHotKey"
    static let panelHotKey = "catGPT.panelHotKey"
    static let captureRegionHotKey = "catGPT.captureRegionHotKey"
    static let batchCaptureHotKey = "catGPT.batchCaptureHotKey"
    static let captureRegionShortcutMigrationVersion = "catGPT.captureRegionShortcutMigrationVersion"
    static let maxImageEdge = "catGPT.maxImageEdge"
    static let captureRegionEnabled = "catGPT.captureRegionEnabled"
    static let captureRegionX = "catGPT.captureRegionX"
    static let captureRegionY = "catGPT.captureRegionY"
    static let captureRegionWidth = "catGPT.captureRegionWidth"
    static let captureRegionHeight = "catGPT.captureRegionHeight"
    static let panelOpacity = "catGPT.panelOpacity"
    static let panelTextOpacity = "catGPT.panelTextOpacity"
    static let panelTextColor = "catGPT.panelTextColor"
    static let panelFontSize = "catGPT.panelFontSize"
    static let panelWidth = "catGPT.panelWidth"
    static let panelHeight = "catGPT.panelHeight"
    static let panelOriginX = "catGPT.panelOriginX"
    static let panelOriginY = "catGPT.panelOriginY"
    static let shortcutDefaultsMigrationVersion = "catGPT.shortcutDefaultsMigrationVersion"
}

struct PromptPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var text: String
}

/// 提示词预设：JSON 存 UserDefaults，首次运行内置三条常用预设。
enum PromptPresetStore {
    private static let key = "catGPT.promptPresets"

    static func load() -> [PromptPreset] {
        if let data = UserDefaults.standard.data(forKey: key),
           let presets = try? JSONDecoder().decode([PromptPreset].self, from: data) {
            return presets
        }
        let defaults = builtinPresets()
        save(defaults)
        return defaults
    }

    static func save(_ presets: [PromptPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func builtinPresets() -> [PromptPreset] {
        [
            PromptPreset(id: UUID(), name: "通用分析", text: ConfigDraft.defaultPrompt),
            PromptPreset(id: UUID(), name: "提取文字（OCR）", text: "只提取图中的全部文字，按原有排版输出，不要任何解释。"),
            PromptPreset(id: UUID(), name: "翻译成中文", text: "把图中的文字翻译成中文，保持原有段落结构，只输出译文。")
        ]
    }
}

enum KeychainStore {
    private static let service = "CatGPT"
    private static let codexAccount = "CODEX_OAUTH_CREDENTIALS"
    private static let openAIAPIKeyAccount = "OPENAI_COMPATIBLE_API_KEY"
    /// 所有异步写操作走同一条串行队列，保证"登出删除"和"刷新保存"
    /// 按发起顺序落盘，不会出现登出后旧的保存任务把凭证写回去。
    private static let writeQueue = DispatchQueue(label: "CatGPT.KeychainStore")

    static func saveCodexCredentialsAsync(_ credentials: CodexOAuthCredentials) {
        writeQueue.async {
            try? saveCodexCredentials(credentials)
        }
    }

    static func deleteCodexCredentialsAsync() {
        writeQueue.async {
            deleteCodexCredentials()
        }
    }

    static func readOpenAIAPIKey() -> String? {
        readString(account: openAIAPIKeyAccount)
    }

    static func saveOpenAIAPIKeyAsync(_ apiKey: String) {
        writeQueue.async {
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deleteString(account: openAIAPIKeyAccount)
            } else {
                try? saveString(apiKey, account: openAIAPIKeyAccount)
            }
        }
    }

    static func readCodexCredentials() -> CodexOAuthCredentials? {
        guard let text = readString(account: codexAccount),
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexOAuthCredentials.self, from: data)
    }

    static func saveCodexCredentials(_ credentials: CodexOAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError.configuration("无法编码登录凭证。")
        }
        try saveString(text, account: codexAccount)
    }

    static func deleteCodexCredentials() {
        deleteString(account: codexAccount)
    }

    private static func deleteString(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // errSecItemNotFound 视为已删除，无需报错。
        SecItemDelete(query as CFDictionary)
    }

    private static func readString(account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // 启动阶段不得为读取旧凭证强制弹出钥匙串认证窗口；
            // 若系统需要交互授权则作为未登录处理，等待用户主动登录。
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func saveString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // 更新时也带上 accessibility，让此前用 WhenUnlocked 存过的既有凭证
        // 追溯升级为 ThisDeviceOnly，不只对新增条目生效。
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // ThisDeviceOnly：refresh token 不进加密备份、不随迁移带到其他设备。
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AppError.configuration("无法将登录凭证保存到钥匙串：\(addStatus)。")
            }
        } else if status != errSecSuccess {
            throw AppError.configuration("无法更新钥匙串中的登录凭证：\(status)。")
        }
    }
}

enum AppError: Error, LocalizedError {
    case configuration(String)
    case hotKey(String)
    case screenshot(String)
    case network(String)
    case response(String)
    /// 登录凭证已彻底失效（invalid_grant 等），需要重新走 OAuth 登录。
    case authExpired(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message),
             .hotKey(let message),
             .screenshot(let message),
             .network(let message),
             .response(let message),
             .authExpired(let message):
            return message
        }
    }
}
