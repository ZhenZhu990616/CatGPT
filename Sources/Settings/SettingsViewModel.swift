import AppKit
import Foundation
import ServiceManagement
import SwiftUI

struct SettingsState: Equatable {
    let signedIn: Bool
    let accountId: String
    let screenPermission: Bool
    let accessibilityPermission: Bool
    let statusText: String
    let hotKeyStatus: String

    init(
        signedIn: Bool,
        accountId: String,
        screenPermission: Bool,
        accessibilityPermission: Bool = false,
        statusText: String,
        hotKeyStatus: String
    ) {
        self.signedIn = signedIn
        self.accountId = accountId
        self.screenPermission = screenPermission
        self.accessibilityPermission = accessibilityPermission
        self.statusText = statusText
        self.hotKeyStatus = hotKeyStatus
    }
}

enum SettingsField: Hashable {
    case customBaseURL
    case customAPIKey
    case model
    case prompt
    case instructions
    case captureShortcut
    case selectionShortcut
    case panelShortcut
    case captureRegionShortcut
    case batchCaptureShortcut
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var selectedSection: SettingsSection = .shortcuts
    @Published private(set) var draft: ConfigDraft
    @Published private(set) var lastAppliedDraft: ConfigDraft
    @Published private(set) var state: SettingsState
    @Published private(set) var fieldErrors: [SettingsField: String] = [:]
    @Published var presets: [PromptPreset]
    @Published var newPresetName = ""
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var isVerifyingExternalService = false
    @Published private(set) var externalServiceVerificationMessage: String?
    @Published private(set) var externalServiceVerificationSucceeded = false

    let launchAtLoginAvailable = Bundle.main.bundlePath.hasSuffix(".app")

    private let draftProvider: () -> ConfigDraft
    private let stateProvider: () -> SettingsState
    private let applyDraft: (ConfigDraft, SettingsUpdateScope) throws -> Void
    private let onLogin: () -> Void
    private let onLogout: () -> Void
    private let onPermission: () -> Void
    private let onAccessibilityPermission: () -> Void
    private let onVerifyExternalService: (ConfigDraft) async throws -> Void
    private let debounceNanoseconds: UInt64
    private var pendingTextTasks: [SettingsField: Task<Void, Never>] = [:]
    private var externalVerificationTask: Task<Void, Never>?
    private var externalVerificationRevision = 0

    init(
        initialDraft: ConfigDraft,
        draftProvider: (() -> ConfigDraft)? = nil,
        stateProvider: @escaping () -> SettingsState,
        applyDraft: @escaping (ConfigDraft, SettingsUpdateScope) throws -> Void,
        onLogin: @escaping () -> Void = {},
        onLogout: @escaping () -> Void = {},
        onPermission: @escaping () -> Void = {},
        onAccessibilityPermission: @escaping () -> Void = {},
        onVerifyExternalService: @escaping (ConfigDraft) async throws -> Void = { _ in },
        debounceNanoseconds: UInt64 = 300_000_000
    ) {
        draft = initialDraft
        lastAppliedDraft = initialDraft
        self.draftProvider = draftProvider ?? { initialDraft }
        self.stateProvider = stateProvider
        self.applyDraft = applyDraft
        self.onLogin = onLogin
        self.onLogout = onLogout
        self.onPermission = onPermission
        self.onAccessibilityPermission = onAccessibilityPermission
        self.onVerifyExternalService = onVerifyExternalService
        self.debounceNanoseconds = debounceNanoseconds
        state = stateProvider()
        presets = PromptPresetStore.load()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func reload() {
        state = stateProvider()
        presets = PromptPresetStore.load()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard pendingTextTasks.isEmpty, fieldErrors.isEmpty else { return }
        let latest = draftProvider()
        draft = latest
        lastAppliedDraft = latest
    }

    func binding<Value: Equatable>(
        _ keyPath: WritableKeyPath<ConfigDraft, Value>,
        scope: SettingsUpdateScope
    ) -> Binding<Value> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { self.set($0, at: keyPath, scope: scope) }
        )
    }

    func set<Value: Equatable>(
        _ value: Value,
        at keyPath: WritableKeyPath<ConfigDraft, Value>,
        scope: SettingsUpdateScope
    ) {
        guard draft[keyPath: keyPath] != value else { return }

        if scope == .client {
            invalidateExternalServiceVerification()
        }
        draft[keyPath: keyPath] = value
        var candidate = lastAppliedDraft
        candidate[keyPath: keyPath] = value

        do {
            try applyDraft(candidate, scope)
            lastAppliedDraft = candidate
        } catch {
            draft[keyPath: keyPath] = lastAppliedDraft[keyPath: keyPath]
        }
    }

    func textBinding(
        _ keyPath: WritableKeyPath<ConfigDraft, String>,
        field: SettingsField
    ) -> Binding<String> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { self.setText($0, at: keyPath, field: field) }
        )
    }

    func setText(
        _ value: String,
        at keyPath: WritableKeyPath<ConfigDraft, String>,
        field: SettingsField
    ) {
        if [.customBaseURL, .customAPIKey, .model].contains(field) {
            invalidateExternalServiceVerification()
        }
        draft[keyPath: keyPath] = value
        fieldErrors[field] = nil
        pendingTextTasks[field]?.cancel()
        pendingTextTasks[field] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            applyText(at: keyPath, field: field)
            pendingTextTasks[field] = nil
        }
    }

    func shortcutBinding(
        _ keyPath: WritableKeyPath<ConfigDraft, String>,
        field: SettingsField
    ) -> Binding<String> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { self.setShortcut($0, at: keyPath, field: field) }
        )
    }

    func setShortcut(
        _ value: String,
        at keyPath: WritableKeyPath<ConfigDraft, String>,
        field: SettingsField
    ) {
        do {
            _ = try Shortcut.parse(value)

            var candidate = lastAppliedDraft
            candidate[keyPath: keyPath] = value
            let shortcuts = [
                try Shortcut.parse(candidate.hotKeyText).displayText,
                try Shortcut.parse(candidate.selectionHotKeyText).displayText,
                try Shortcut.parse(candidate.panelHotKeyText).displayText,
                try Shortcut.parse(candidate.captureRegionHotKeyText).displayText,
                try Shortcut.parse(candidate.batchCaptureHotKeyText).displayText
            ]
            guard Set(shortcuts).count == shortcuts.count else {
                throw SettingsValidationError.duplicateShortcut
            }

            try applyDraft(candidate, .shortcuts)
            draft[keyPath: keyPath] = value
            lastAppliedDraft = candidate
            fieldErrors[field] = nil
        } catch {
            draft[keyPath: keyPath] = lastAppliedDraft[keyPath: keyPath]
            fieldErrors[field] = error.localizedDescription
        }
    }

    func error(for field: SettingsField) -> String? {
        fieldErrors[field]
    }

    func resetShortcuts() {
        var candidate = lastAppliedDraft
        candidate.hotKeyText = ConfigDraft.defaultHotKey
        candidate.selectionHotKeyText = ConfigDraft.defaultSelectionHotKey
        candidate.panelHotKeyText = ConfigDraft.defaultPanelHotKey
        candidate.captureRegionHotKeyText = ConfigDraft.defaultCaptureRegionHotKey
        candidate.batchCaptureHotKeyText = ConfigDraft.defaultBatchCaptureHotKey

        do {
            try applyDraft(candidate, .shortcuts)
            draft.hotKeyText = candidate.hotKeyText
            draft.selectionHotKeyText = candidate.selectionHotKeyText
            draft.panelHotKeyText = candidate.panelHotKeyText
            draft.captureRegionHotKeyText = candidate.captureRegionHotKeyText
            draft.batchCaptureHotKeyText = candidate.batchCaptureHotKeyText
            lastAppliedDraft = candidate
            fieldErrors[.captureShortcut] = nil
            fieldErrors[.selectionShortcut] = nil
            fieldErrors[.panelShortcut] = nil
            fieldErrors[.captureRegionShortcut] = nil
            fieldErrors[.batchCaptureShortcut] = nil
        } catch {
            fieldErrors[.captureShortcut] = error.localizedDescription
        }
    }

    func setMaxOutputTokens(_ value: Int) {
        set(max(0, value), at: \ConfigDraft.maxOutputTokens, scope: .client)
    }

    func verifyExternalServiceConnection() {
        guard !isVerifyingExternalService else { return }

        guard draft.provider == .openAICompatible else {
            setExternalVerificationFailure("当前不是 OpenAI 兼容 API。")
            return
        }
        guard !draft.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setExternalVerificationFailure("API 地址不能为空。")
            return
        }
        guard !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setExternalVerificationFailure("模型不能为空。")
            return
        }

        externalVerificationRevision += 1
        let revision = externalVerificationRevision
        let candidate = draft
        isVerifyingExternalService = true
        externalServiceVerificationMessage = "正在验证…"
        externalServiceVerificationSucceeded = false

        externalVerificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.externalVerificationRevision == revision {
                    self.externalVerificationTask = nil
                }
            }

            do {
                try await self.onVerifyExternalService(candidate)
                guard !Task.isCancelled, self.externalVerificationRevision == revision else { return }
                self.isVerifyingExternalService = false
                self.externalServiceVerificationMessage = "连接成功"
                self.externalServiceVerificationSucceeded = true
            } catch {
                guard !Task.isCancelled, self.externalVerificationRevision == revision else { return }
                self.isVerifyingExternalService = false
                self.externalServiceVerificationMessage = error.localizedDescription
                self.externalServiceVerificationSucceeded = false
            }
        }
    }

    var externalServiceStatusText: String {
        if isVerifyingExternalService { return "正在验证…" }
        if let message = externalServiceVerificationMessage { return message }
        if draft.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "尚未填写 API 地址"
        }
        return "使用自定义 OpenAI 兼容服务"
    }

    func setMaxImageEdge(_ value: Int) {
        set(max(640, value), at: \ConfigDraft.maxImageEdge, scope: .client)
    }

    func setCaptureRegion(_ rect: CGRect) {
        var candidate = lastAppliedDraft
        candidate.captureRegionEnabled = true
        candidate.captureRegionX = rect.origin.x.rounded()
        candidate.captureRegionY = rect.origin.y.rounded()
        candidate.captureRegionWidth = rect.width.rounded()
        candidate.captureRegionHeight = rect.height.rounded()

        do {
            try applyDraft(candidate, .storageOnly)
            draft.captureRegionEnabled = candidate.captureRegionEnabled
            draft.captureRegionX = candidate.captureRegionX
            draft.captureRegionY = candidate.captureRegionY
            draft.captureRegionWidth = candidate.captureRegionWidth
            draft.captureRegionHeight = candidate.captureRegionHeight
            lastAppliedDraft = candidate
        } catch {
            draft.captureRegionEnabled = lastAppliedDraft.captureRegionEnabled
        }
    }

    func chooseCaptureRegion() {
        Task { @MainActor in
            let previousWindow = NSApp.keyWindow
            previousWindow?.orderOut(nil)
            try? await Task.sleep(nanoseconds: 120_000_000)
            defer {
                NSApp.activate(ignoringOtherApps: true)
                previousWindow?.makeKeyAndOrderFront(nil)
            }

            guard let rect = try? await SelectionCapture.selectRegion() else { return }
            setCaptureRegion(rect)
        }
    }

    func login() { onLogin() }

    func logout() {
        onLogout()
        reload()
    }

    func applyPreset(_ preset: PromptPreset) {
        setText(preset.text, at: \ConfigDraft.prompt, field: .prompt)
    }

    func addPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        presets.append(PromptPreset(id: UUID(), name: name, text: draft.prompt))
        PromptPresetStore.save(presets)
        newPresetName = ""
    }

    func deletePreset(_ preset: PromptPreset) {
        presets.removeAll { $0.id == preset.id }
        PromptPresetStore.save(presets)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

    func requestScreenPermission() {
        onPermission()
        reload()
    }

    func requestAccessibilityPermission() {
        onAccessibilityPermission()
        reload()
    }

    var accountText: String {
        state.signedIn ? "已登录 · \(state.accountId.isEmpty ? "Codex" : state.accountId)" : "未登录"
    }

    var permissionText: String {
        state.screenPermission ? "屏幕录制已授权" : "屏幕录制未授权"
    }

    var accessibilityPermissionText: String {
        state.accessibilityPermission ? "辅助功能已授权" : "双击修饰键快捷键需要授权"
    }

    private func applyText(
        at keyPath: WritableKeyPath<ConfigDraft, String>,
        field: SettingsField
    ) {
        let value = draft[keyPath: keyPath]
        if field == .model && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[field] = "模型不能为空。"
            return
        }
        if field == .model,
           draft.provider == .codex,
           !ConfigDraft.isSupportedModel(value) {
            fieldErrors[field] = "模型输入有误。"
            return
        }
        if field == .customBaseURL && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[field] = "API 地址不能为空。"
            return
        }

        var candidate = lastAppliedDraft
        candidate[keyPath: keyPath] = field == .model
            ? value.trimmingCharacters(in: .whitespacesAndNewlines)
            : value

        do {
            try applyDraft(candidate, .client)
            lastAppliedDraft = candidate
            draft[keyPath: keyPath] = candidate[keyPath: keyPath]
            fieldErrors[field] = nil
        } catch {
            fieldErrors[field] = error.localizedDescription
        }
    }

    private func invalidateExternalServiceVerification() {
        externalVerificationRevision += 1
        externalVerificationTask?.cancel()
        externalVerificationTask = nil
        isVerifyingExternalService = false
        externalServiceVerificationMessage = nil
        externalServiceVerificationSucceeded = false
    }

    private func setExternalVerificationFailure(_ message: String) {
        externalVerificationRevision += 1
        externalVerificationTask?.cancel()
        externalVerificationTask = nil
        isVerifyingExternalService = false
        externalServiceVerificationMessage = message
        externalServiceVerificationSucceeded = false
    }
}

enum SettingsValidationError: LocalizedError {
    case duplicateShortcut

    var errorDescription: String? {
        switch self {
        case .duplicateShortcut:
            return "不能与其他 CatGPT 快捷键重复。"
        }
    }
}
