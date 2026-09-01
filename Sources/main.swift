import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var captureMenuItem: NSMenuItem?
    private var selectionMenuItem: NSMenuItem?
    private var resultMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var logoutMenuItem: NSMenuItem?
    private var cancelMenuItem: NSMenuItem?
    private let shortcutRegistry = ShortcutRegistry()
    private let resultPanel = ResultPanelController()
    private let touchBarResult = TouchBarResultController()
    private let history = HistoryStore()
    private var historyMenu: NSMenu?
    private var presetMenu: NSMenu?
    private var settingsWindowController: SettingsWindowController?
    private let batchCaptureQueue = BatchCaptureQueue()
    private var batchCaptureTask: Task<Void, Never>?
    private var batchEscapeMonitor: Any?
    private var batchProgressUsesFloatingPanel = false
    private let streamTextCoalescer = StreamTextUpdateCoalescer()

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
    private var draft = ConfigDraft.load()
    private var client: LLMClient?
    private var credentials: CodexOAuthCredentials?
    private var credentialsLoaded = false
    /// 登录会话代际：仅在登出、凭证失效、登录成功这三处递增。
    /// 用于作废旧会话的在途刷新回调（防止登出后刷新完成把凭证写回钥匙串
    /// "复活"登录态）；常规设置保存/预设切换不递增，
    /// 否则会丢弃合法的 rotating refresh token 轮换结果。
    private var clientGeneration = 0
    private var isRunning = false
    private var isLoggingIn = false
    private var statusText = "就绪"
    private var statusKind = "ready"
    private var hotKeyStatus = "快捷键未启用"
    private var lastResult = ""
    private var captureToken = UUID()
    private var captureTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        bindResultPanel()
        buildStatusMenu()
        reloadRuntime()
        loadStoredCredentials()

        // 开发辅助：CATGPT_OPEN_SETTINGS=<分区 rawValue 或 1> 启动即打开设置窗口。
        if let section = ProcessInfo.processInfo.environment["CATGPT_OPEN_SETTINGS"] {
            openSettings()
            settingsWindowController?.select(sectionRaw: section)
        }
    }

    /// accessory 应用没有可见菜单栏，但 ⌘C/⌘V/⌘Z 等标准快捷键依赖
    /// mainMenu 的 keyEquivalent 路由；没有它设置窗口里连粘贴都不可用。
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 CatGPT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func bindResultPanel() {
        resultPanel.onFrameChanged = { [weak self] width, height, originX, originY in
            guard let self else { return }
            self.draft.panelWidth = width
            self.draft.panelHeight = height
            self.draft.panelOriginX = originX
            self.draft.panelOriginY = originY
            self.draft.save()
        }
    }

    private func buildStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.makeImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "CatGPT"
        item.button?.setAccessibilityLabel("CatGPT")

        item.menu = makeStatusMenu()
        statusItem = item
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeMenuItem(title: "偏好设置", action: #selector(openSettings), symbolName: "gearshape", keyEquivalent: ","))
        let captureItem = makeMenuItem(title: "立即截图", action: #selector(captureFromMenu), symbolName: "camera.viewfinder")
        let selectionItem = makeMenuItem(title: "框选截图", action: #selector(selectionCaptureFromMenu), symbolName: "crop")
        let resultItem = makeMenuItem(title: "呼出/隐藏结果", action: #selector(toggleResultFromMenu), symbolName: "macwindow")
        let cancelItem = makeMenuItem(title: "中断当前任务", action: #selector(cancelFromMenu), symbolName: "stop.circle")
        let loginItem = makeMenuItem(title: "登录 ChatGPT", action: #selector(loginFromMenu), symbolName: "person.crop.circle.badge.checkmark")
        let logoutItem = makeMenuItem(title: "退出登录", action: #selector(logoutFromMenu), symbolName: "person.crop.circle.badge.xmark")
        captureMenuItem = captureItem
        selectionMenuItem = selectionItem
        resultMenuItem = resultItem
        cancelMenuItem = cancelItem
        loginMenuItem = loginItem
        logoutMenuItem = logoutItem
        menu.addItem(captureItem)
        menu.addItem(selectionItem)
        menu.addItem(cancelItem)
        menu.addItem(resultItem)

        let historyItem = makeInfoMenuItem(title: "历史记录", symbolName: "clock.arrow.circlepath")
        let historySubmenu = NSMenu(title: "历史记录")
        historySubmenu.delegate = self
        historyItem.submenu = historySubmenu
        historyMenu = historySubmenu
        menu.addItem(historyItem)

        let presetItem = makeInfoMenuItem(title: "提示词预设", symbolName: "text.badge.checkmark")
        let presetSubmenu = NSMenu(title: "提示词预设")
        presetSubmenu.delegate = self
        presetItem.submenu = presetSubmenu
        presetMenu = presetSubmenu
        menu.addItem(presetItem)

        menu.addItem(loginItem)
        menu.addItem(logoutItem)
        menu.addItem(.separator())

        let statusMenuItem = makeInfoMenuItem(title: statusText, symbolName: statusSymbolName(for: statusKind))
        statusMenuItem.isEnabled = false
        self.statusMenuItem = statusMenuItem
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "退出", action: #selector(quit), symbolName: "power", keyEquivalent: "q"))
        updateMenuShortcutTitles()
        return menu
    }

    private func makeMenuItem(title: String, action: Selector, symbolName: String, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = menuImage(symbolName)
        return item
    }

    private func makeInfoMenuItem(title: String, symbolName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = menuImage(symbolName)
        return item
    }

    private func menuImage(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func statusSymbolName(for kind: String) -> String {
        switch kind {
        case "ready": return "checkmark.circle"
        case "working": return "arrow.triangle.2.circlepath"
        case "warning": return "exclamationmark.triangle"
        case "error": return "xmark.octagon"
        default: return "info.circle"
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === cancelMenuItem {
            return isRunning
        }
        if menuItem === logoutMenuItem {
            return credentials != nil
        }
        return true
    }

    private func updateAccountMenuItems(provider: LLMProvider? = nil) {
        let isCodex = (provider ?? draft.provider) == .codex
        loginMenuItem?.isHidden = !isCodex
        logoutMenuItem?.isHidden = !isCodex
        loginMenuItem?.title = credentials == nil ? "登录 ChatGPT" : "重新登录 ChatGPT"
    }

    // MARK: - 历史记录与提示词预设子菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu {
            rebuildHistoryMenu(menu)
        } else if menu === presetMenu {
            rebuildPresetMenu(menu)
        }
    }

    private func rebuildHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "暂无历史", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for entry in history.entries {
            let preview = entry.answer
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(30)
            let item = NSMenuItem(
                title: "\(Self.historyDateFormatter.string(from: entry.date))  \(preview)\(entry.answer.count > 30 ? "…" : "")",
                action: #selector(showHistoryEntry(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "清空历史", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    private func rebuildPresetMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let presets = PromptPresetStore.load()
        if presets.isEmpty {
            let empty = NSMenuItem(title: "暂无预设（可在偏好设置的提示词页添加）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for preset in presets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = preset.text == draft.prompt ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func showHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = history.entry(withId: id) else {
            return
        }
        lastResult = entry.answer
        showOutput(text: entry.answer, kind: "ready")
    }

    @objc private func clearHistory() {
        history.clear()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = PromptPresetStore.load().first(where: { $0.id == id }) else {
            return
        }
        var proposed = draft
        proposed.prompt = preset.text
        do {
            try applyDraftFromSettings(proposed, scope: .client)
            settingsWindowController?.reload()
            setStatus("已切换提示词预设：\(preset.name)", kind: "ready")
        } catch {
            setStatus(error.localizedDescription, kind: "error")
        }
    }

    private func reloadRuntime() {
        applyPanelSettings(from: draft)
        updateAccountMenuItems()

        let hotKeyError: Error?
        do {
            try registerHotKeys(from: draft)
            hotKeyError = nil
        } catch {
            hotKeyError = error
            hotKeyStatus = error.localizedDescription
        }

        rebuildClient(from: draft)
        if let hotKeyError {
            setStatus(hotKeyError.localizedDescription, kind: "warning")
        }
    }

    private func rebuildClient(from candidate: ConfigDraft) {
        // applyDraftFromSettings 在 SettingsApplication 内以 inout 修改 draft；
        // 这里必须使用 candidate，避免同时读取 AppDelegate.draft 触发独占访问冲突。
        updateAccountMenuItems(provider: candidate.provider)
        let generation = clientGeneration
        let config: AppConfig
        do {
            config = try candidate.makeConfig(codexCredentials: credentials)
        } catch {
            client = nil
            if credentialsLoaded {
                // 区分"缺凭证"和"配置非法（如模型清空）"，别一律误报"请先登录"。
                if case AppError.configuration = error {
                    setStatus(error.localizedDescription, kind: "warning")
                } else {
                    setStatus(candidate.provider == .codex ? "请先登录 ChatGPT/Codex" : "请先配置外部 LLM", kind: "warning")
                }
            } else {
                setStatus("正在读取登录状态...", kind: "working")
            }
            return
        }

        client = LLMClient(config: config) { [weak self] credentials in
            Task { @MainActor in
                guard let self, self.clientGeneration == generation else { return }
                self.credentials = credentials
                self.credentialsLoaded = true
                KeychainStore.saveCodexCredentialsAsync(credentials)
            }
        }
        setStatus(
            candidate.provider == .codex ? "已登录，可截图" : "外部 LLM 已配置，可截图",
            kind: "ready"
        )
    }

    private func loadStoredCredentials() {
        Task { @MainActor in
            let stored = await Task.detached {
                KeychainStore.readCodexCredentials()
            }.value
            credentials = stored
            credentialsLoaded = true
            reloadRuntime()
        }
    }

    private func applyPanelSettings(from candidate: ConfigDraft) {
        resultPanel.configure(
            width: candidate.normalizedPanelWidth,
            height: candidate.normalizedPanelHeight,
            opacity: candidate.normalizedPanelOpacity,
            textOpacity: candidate.normalizedPanelTextOpacity,
            fontSize: candidate.normalizedPanelFontSize,
            textColor: candidate.panelTextColor,
            originX: candidate.panelOriginX,
            originY: candidate.panelOriginY
        )
        touchBarResult.configure(
            fontSize: candidate.normalizedTouchBarFontSize,
            textColor: candidate.touchBarTextColor,
            textIntensity: candidate.normalizedTouchBarTextIntensity,
            textAlignment: candidate.touchBarTextAlignment
        )
    }

    private func registerHotKeys(from candidate: ConfigDraft) throws {
        shortcutRegistry.unregisterAll()

        let captureShortcut = try candidate.makeShortcut()
        let selectionShortcut = try candidate.makeSelectionShortcut()
        let panelShortcut = try candidate.makePanelShortcut()
        let captureRegionShortcut = try candidate.makeCaptureRegionShortcut()
        let batchCaptureShortcut = try candidate.makeBatchCaptureShortcut()

        do {
            try shortcutRegistry.register(shortcut: captureShortcut, id: 1) { [weak self] in
            Task { @MainActor in
                do {
                    try self?.launchImmediateCapture()
                } catch {
                    self?.lastResult = error.localizedDescription
                    self?.setStatus(error.localizedDescription, kind: "error")
                }
            }
            }

            try shortcutRegistry.register(shortcut: selectionShortcut, id: 2) { [weak self] in
            Task { @MainActor in
                do {
                    try self?.launchCapture(selection: true)
                } catch {
                    self?.lastResult = error.localizedDescription
                    self?.setStatus(error.localizedDescription, kind: "error")
                }
            }
            }

            try shortcutRegistry.register(shortcut: panelShortcut, id: 3) { [weak self] in
            Task { @MainActor in
                self?.toggleResultPanel()
            }
            }

            try shortcutRegistry.register(shortcut: captureRegionShortcut, id: 4) { [weak self] in
                self?.chooseCaptureRegionFromShortcut()
            }

            try shortcutRegistry.register(shortcut: batchCaptureShortcut, id: 5) { [weak self] in
                Task { @MainActor in
                    self?.launchBatchCapture()
                }
            }

            hotKeyStatus = "快捷键已启用：截图 \(captureShortcut.displayText) / 框选 \(selectionShortcut.displayText) / 结果 \(panelShortcut.displayText) / 固定区域 \(captureRegionShortcut.displayText) / 批量 \(batchCaptureShortcut.displayText)"
            updateMenuShortcutTitles(from: candidate)
        } catch {
            shortcutRegistry.unregisterAll()
            throw error
        }
    }

    private func updateMenuShortcutTitles(from candidate: ConfigDraft? = nil) {
        let source = candidate ?? draft
        applyMenuShortcut(captureMenuItem, title: "立即截图", shortcut: try? source.makeShortcut())
        applyMenuShortcut(selectionMenuItem, title: "框选截图", shortcut: try? source.makeSelectionShortcut())
        applyMenuShortcut(resultMenuItem, title: "呼出/隐藏结果", shortcut: try? source.makePanelShortcut())
    }

    private func applyMenuShortcut(_ item: NSMenuItem?, title: String, shortcut: Shortcut?) {
        guard let item else { return }
        item.title = title
        item.attributedTitle = nil
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []

        guard let shortcut else { return }
        switch shortcut {
        case .chord(let hotKey):
            item.keyEquivalent = hotKey.keyEquivalent
            item.keyEquivalentModifierMask = hotKey.menuModifierMask
        case .doubleTap(let key):
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 308)]
            item.attributedTitle = NSAttributedString(
                string: "\(title)\t\(key.displayText)",
                attributes: [
                    .paragraphStyle: paragraph,
                    .foregroundColor: NSColor.labelColor
                ]
            )
        }
    }

    private func cancelCapture() {
        guard isRunning else {
            setStatus("没有正在运行的任务", kind: "ready", phase: "ready")
            return
        }

        captureTask?.cancel()
        finishCancelledCapture()
    }

    private func finishCancelledCapture() {
        captureTask = nil
        isRunning = false
        batchProgressUsesFloatingPanel = false
        streamTextCoalescer.cancel()
        captureToken = UUID()
        lastResult = "已中断。"
        setStatus("已中断", kind: "warning", phase: "ready")
        // 用户主动取消不弹结果面板，安静收场即可。
        hideOutputForCapture()
    }

    private func launchImmediateCapture() throws {
        if batchCaptureQueue.isCapturing {
            setStatus("正在缓存截图，请稍候", kind: "warning")
        } else if batchCaptureQueue.isEmpty {
            try launchCapture(selection: false)
        } else {
            try sendBatchCaptureQueue()
        }
    }

    private func sendBatchCaptureQueue() throws {
        guard !batchCaptureQueue.isCapturing else {
            setStatus("正在缓存截图，请稍候", kind: "warning")
            return
        }
        guard client != nil else {
            throw AppError.configuration(configurationRequiredMessage)
        }
        guard Screenshotter.hasPermission() else {
            Screenshotter.requestPermissionIfNeeded()
            throw AppError.screenshot("需要授予 CatGPT 屏幕录制权限。请在“服务”设置中启用后重新打开应用。")
        }
        guard case .images(let images) = batchCaptureQueue.takeAllForSending() else { return }

        try startRequestState(status: "正在发送到 \(providerDisplayName)...", phase: "sending")
        batchProgressUsesFloatingPanel = true
        syncBatchEscapeMonitor()
        touchBarResult.hideForCapture()
        resultPanel.showPhase("sending")

        let token = captureToken
        let generation = clientGeneration
        captureTask = Task { @MainActor in
            do {
                let answer = try await self.performBatchAnalysis(images: images, token: token)
                guard self.captureToken == token else { return }
                self.captureTask = nil
                self.streamTextCoalescer.flush()
                self.lastResult = answer
                self.history.add(prompt: self.draft.prompt, answer: answer)
                self.setStatus("完成", kind: "ready", phase: "ready")
                self.showOutput(text: answer, kind: "ready")
                self.isRunning = false
                self.batchProgressUsesFloatingPanel = false
            } catch {
                if self.isCancellation(error) {
                    if self.captureToken == token { self.finishCancelledCapture() }
                    return
                }
                guard self.captureToken == token else { return }
                self.captureTask = nil
                self.isRunning = false
                self.batchProgressUsesFloatingPanel = false
                self.handleAuthExpiredIfNeeded(error, generation: generation)
                self.lastResult = error.localizedDescription
                self.setStatus(error.localizedDescription, kind: "error", phase: "error")
                self.showOutput(text: error.localizedDescription, kind: "error")
            }
        }
    }

    private func startRequestState(status: String, phase: String) throws {
        guard client != nil else {
            throw AppError.configuration(configurationRequiredMessage)
        }
        isRunning = true
        streamTextCoalescer.cancel()
        captureToken = UUID()
        lastResult = ""
        setStatus(status, kind: "working", phase: phase)
    }

    @MainActor
    private func performBatchAnalysis(images: [Data], token: UUID) async throws -> String {
        guard let client else {
            throw AppError.configuration(configurationRequiredMessage)
        }
        let answer = try await client.analyze(
            imageDataList: images,
            mimeType: "image/jpeg",
            onEvent: streamEventHandler(token: token)
        )
        try Task.checkCancellation()
        guard captureToken == token else { throw CancellationError() }
        return answer
    }

    private func launchBatchCapture() {
        guard !isRunning else {
            setStatus("当前任务尚未完成", kind: "warning")
            return
        }
        guard Screenshotter.hasPermission() else {
            Screenshotter.requestPermissionIfNeeded()
            setStatus("需要授予 CatGPT 屏幕录制权限。", kind: "error")
            return
        }
        switch batchCaptureQueue.beginCapture() {
        case .busy:
            setStatus("正在缓存截图，请稍候", kind: "warning")
            return
        case .full:
            setStatus("最多缓存 8 张，请先发送", kind: "warning")
            return
        case .started:
            break
        }

        hideOutputForCapture()
        if batchCaptureQueue.count > 0 {
            resultPanel.showBatch(count: batchCaptureQueue.count)
        }
        syncBatchEscapeMonitor()
        let maxEdge = draft.normalizedMaxImageEdge
        let region = draft.captureRegion
        batchCaptureTask = Task { @MainActor in
            defer {
                self.batchCaptureTask = nil
                self.syncBatchEscapeMonitor()
            }
            do {
                let image = try await Screenshotter.captureImageData(maxEdge: maxEdge, region: region)
                try Task.checkCancellation()
                let previousCount = self.batchCaptureQueue.count
                self.batchCaptureQueue.completeCapture(image)
                guard self.batchCaptureQueue.count > previousCount else { return }
                self.setStatus("已缓存 \(self.batchCaptureQueue.count) 张截图", kind: "ready")
                self.resultPanel.showBatch(count: self.batchCaptureQueue.count)
            } catch {
                self.batchCaptureQueue.cancelInFlightCapture()
                if self.isCancellation(error) { return }
                self.setStatus(error.localizedDescription, kind: "error")
                if self.batchCaptureQueue.count > 0 {
                    self.resultPanel.showBatch(count: self.batchCaptureQueue.count)
                } else {
                    self.resultPanel.hideForCapture()
                }
            }
        }
    }

    private func syncBatchEscapeMonitor() {
        let shouldMonitor = batchCaptureQueue.isCapturing || !batchCaptureQueue.isEmpty
        if shouldMonitor, batchEscapeMonitor == nil {
            batchEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == UInt16(kVK_Escape) else { return }
                Task { @MainActor in self?.handleBatchEscape() }
            }
        } else if !shouldMonitor, let batchEscapeMonitor {
            NSEvent.removeMonitor(batchEscapeMonitor)
            self.batchEscapeMonitor = nil
        }
    }

    private func handleBatchEscape() {
        if batchCaptureQueue.isCapturing {
            batchCaptureTask?.cancel()
            batchCaptureQueue.cancelInFlightCapture()
            setStatus("已取消缓存截图", kind: "ready")
        } else if batchCaptureQueue.removeLast() != nil {
            setStatus(
                batchCaptureQueue.isEmpty ? "就绪" : "已缓存 \(batchCaptureQueue.count) 张截图",
                kind: "ready"
            )
        } else {
            return
        }

        if batchCaptureQueue.isEmpty {
            resultPanel.hideForCapture()
        } else {
            resultPanel.showBatch(count: batchCaptureQueue.count)
        }
        syncBatchEscapeMonitor()
    }

    private func clearBatchCaptureState() {
        batchCaptureTask?.cancel()
        batchCaptureTask = nil
        streamTextCoalescer.cancel()
        batchCaptureQueue.clear()
        batchProgressUsesFloatingPanel = false
        resultPanel.hideForCapture()
        syncBatchEscapeMonitor()
    }

    private func launchCapture(selection: Bool) throws {
        cancelCaptureForReplacementIfNeeded()
        try startCaptureState()
        let token = captureToken
        let generation = clientGeneration
        captureTask = Task { @MainActor in
            do {
                _ = try await self.performCapture(selection: selection)
                if self.captureToken == token {
                    self.captureTask = nil
                }
            } catch {
                if self.isCancellation(error) {
                    if self.captureToken == token {
                        self.finishCancelledCapture()
                    }
                    return
                }

                guard self.captureToken == token else { return }
                self.captureTask = nil
                self.handleAuthExpiredIfNeeded(error, generation: generation)
                self.lastResult = error.localizedDescription
                self.setStatus(error.localizedDescription, kind: "error", phase: "error")
                self.showOutput(text: error.localizedDescription, kind: "error")
            }
        }
    }

    private func cancelCaptureForReplacementIfNeeded() {
        guard isRunning else { return }
        let previousTask = captureTask
        captureTask = nil
        isRunning = false
        captureToken = UUID()
        previousTask?.cancel()
    }

    private func startCaptureState() throws {
        try startRequestState(status: "正在截图...", phase: "capturing")
    }

    /// 显式钉在主 actor 上：截图状态机（captureToken/isRunning/lastResult）与
    /// AppKit 调用都要求主线程，nonisolated async 会跳到全局执行器造成数据竞争。
    @MainActor
    private func performCapture(selection: Bool = false) async throws -> String {
        let token = captureToken
        guard let client else {
            if captureToken == token {
                isRunning = false
            }
            throw AppError.configuration(configurationRequiredMessage)
        }

        // 权限前置检查：别让用户拖完整个框选才发现没有屏幕录制权限。
        guard Screenshotter.hasPermission() else {
            isRunning = false
            Screenshotter.requestPermissionIfNeeded()
            throw AppError.screenshot("需要授予 CatGPT 屏幕录制权限。请在“服务”设置中启用后重新打开应用。")
        }

        hideOutputForCapture()
        try Task.checkCancellation()

        do {
            let imageData = selection
                ? try await SelectionCapture.captureImageData(maxEdge: draft.normalizedMaxImageEdge)
                : try await Screenshotter.captureImageData(maxEdge: draft.normalizedMaxImageEdge, region: draft.captureRegion)
            try Task.checkCancellation()
            guard captureToken == token else {
                throw CancellationError()
            }

            setStatus("正在发送到 \(providerDisplayName)...", kind: "working", phase: "sending")
            showOutputPhase("sending")

            // 阶段切换由真实 SSE 事件驱动；正文随 delta 增量上屏。
            let answer = try await client.analyze(
                imageData: imageData,
                mimeType: "image/jpeg",
                onEvent: streamEventHandler(token: token)
            )
            try Task.checkCancellation()
            guard captureToken == token else {
                throw CancellationError()
            }
            streamTextCoalescer.flush()
            lastResult = answer
            history.add(prompt: draft.prompt, answer: answer)
            setStatus("完成", kind: "ready", phase: "ready")
            showOutput(text: answer, kind: "ready")
            isRunning = false
            return answer
        } catch {
            if isCancellation(error) {
                if captureToken == token {
                    isRunning = false
                }
                throw CancellationError()
            }
            if captureToken == token {
                isRunning = false
            }
            throw error
        }
    }

    private func streamEventHandler(token: UUID) -> @Sendable (LLMStreamEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in
                guard let self, self.isRunning, self.captureToken == token else { return }
                switch event {
                case .connected:
                    self.setStatus("正在接收 \(self.providerDisplayName) 返回...", kind: "working", phase: "receiving")
                    self.showOutputPhase("receiving")
                case .reasoning:
                    self.setStatus("正在思考...", kind: "working", phase: "thinking")
                    self.showOutputPhase("thinking")
                case .delta(let text):
                    self.streamTextCoalescer.submit(text) { [weak self] text in
                        guard let self, self.isRunning, self.captureToken == token else { return }
                        self.batchProgressUsesFloatingPanel = false
                        self.showOutput(text: text, kind: "working", autoScroll: true, isStreaming: true)
                    }
                }
            }
        }
    }

    /// 用户选了 Touch Bar 模式但本机没有可用 Touch Bar 时，回退到悬浮窗，
    /// 否则回答会送到不存在的 Touch Bar 上、用户什么也看不到。
    private var usingTouchBar: Bool {
        draft.outputDisplayMode == .touchBar && TouchBarResultController.isAvailable
    }

    private var providerDisplayName: String {
        draft.provider == .codex ? "Codex" : "外部 LLM"
    }

    private var configurationRequiredMessage: String {
        draft.provider == .codex ? "请先登录 ChatGPT/Codex。" : "请先在模型设置中填写有效的 OpenAI 兼容 API 地址和模型。"
    }

    private func showOutput(text: String, kind: String, autoScroll: Bool = false, isStreaming: Bool = false) {
        if usingTouchBar {
            resultPanel.hideForCapture()
            touchBarResult.show(text: text, kind: kind)
        } else {
            touchBarResult.hideForCapture()
            resultPanel.show(text: text, kind: kind, autoScroll: autoScroll, isStreaming: isStreaming)
        }
    }

    private func showOutputPhase(_ phase: String) {
        if usingTouchBar && !batchProgressUsesFloatingPanel {
            resultPanel.hideForCapture()
            touchBarResult.showPhase(phase)
        } else {
            touchBarResult.hideForCapture()
            resultPanel.showPhase(phase)
        }
    }

    private func hideOutputForCapture() {
        resultPanel.hideForCapture()
        touchBarResult.hideForCapture()
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        return Task.isCancelled
    }

    private func setStatus(_ text: String, kind: String, phase: String? = nil) {
        statusText = text
        statusKind = kind
        statusMenuItem?.title = text
        statusMenuItem?.image = menuImage(statusSymbolName(for: kind))
    }

    private func requestScreenPermission() {
        if Screenshotter.hasPermission() {
            setStatus("屏幕录制权限已授权", kind: "ready")
            return
        }

        Screenshotter.requestPermissionIfNeeded()
        Screenshotter.openScreenRecordingSettings()
        setStatus("请在系统设置中启用 CatGPT 的屏幕录制权限，完成后重新打开应用", kind: "warning")
    }

    private func requestAccessibilityPermission() {
        if shortcutRegistry.hasAccessibilityPermission {
            setStatus("辅助功能权限已授权", kind: "ready")
            return
        }

        shortcutRegistry.requestAccessibilityPermission()
        setStatus("请在系统设置中启用 CatGPT 的辅助功能权限，完成后重新打开设置", kind: "warning")
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                draftProvider: { [weak self] in self?.draft ?? ConfigDraft.load() },
                stateProvider: { [weak self] in
                    SettingsState(
                        signedIn: self?.credentials != nil,
                        accountId: self?.credentials?.accountId ?? "",
                        screenPermission: Screenshotter.hasPermission(),
                        accessibilityPermission: self?.shortcutRegistry.hasAccessibilityPermission ?? false,
                        statusText: self?.statusText ?? "就绪",
                        hotKeyStatus: self?.hotKeyStatus ?? "快捷键未启用"
                    )
                },
                onApply: { [weak self] candidate, scope in
                    guard let self else { return }
                    try self.applyDraftFromSettings(candidate, scope: scope)
                },
                onLogin: { [weak self] in self?.startLoginFromSettings() },
                onLogout: { [weak self] in self?.logout() },
                onPermission: { [weak self] in self?.requestScreenPermission() },
                onAccessibilityPermission: { [weak self] in self?.requestAccessibilityPermission() },
                onVerifyExternalService: { [weak self] candidate in
                    guard let self else { return }
                    let config = try candidate.makeConfig(codexCredentials: self.credentials)
                    guard config.provider == .openAICompatible else {
                        throw AppError.configuration("当前不是 OpenAI 兼容 API。")
                    }
                    try await LLMClient(config: config).verifyConnection()
                }
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        settingsWindowController?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyDraftFromSettings(
        _ proposed: ConfigDraft,
        scope: SettingsUpdateScope
    ) throws {
        let application = SettingsApplication(
            persist: { $0.save() },
            appearance: { [weak self] candidate in
                self?.applyPanelSettings(from: candidate)
            },
            shortcuts: { [weak self] candidate in
                guard let self else { return }
                try self.registerHotKeys(from: candidate)
            },
            client: { [weak self] candidate in
                self?.rebuildClient(from: candidate)
            }
        )
        try application.apply(proposed, to: &draft, scope: scope)
    }

    private func startLoginFromSettings() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        setStatus("正在打开 ChatGPT 登录页面...", kind: "working")
        settingsWindowController?.reload()

        Task { @MainActor in
            do {
                let credentials = try await CodexOAuthClient().login()
                // 新登录 = 新会话代际，作废旧会话的在途刷新回调。
                self.clientGeneration += 1
                // 走串行队列落盘：与登出删除、刷新保存严格按发起顺序，
                // 同时不在主线程同步阻塞钥匙串调用。
                KeychainStore.saveCodexCredentialsAsync(credentials)
                self.credentials = credentials
                self.credentialsLoaded = true
                self.isLoggingIn = false
                self.reloadRuntime()
                self.lastResult = "登录完成。"
                self.setStatus("登录完成，可截图", kind: "ready")
            } catch {
                self.isLoggingIn = false
                self.lastResult = error.localizedDescription
                self.setStatus(error.localizedDescription, kind: "error")
            }
            self.settingsWindowController?.reload()
        }
    }

    @objc private func captureFromMenu() {
        do {
            try launchImmediateCapture()
        } catch {
            lastResult = error.localizedDescription
            showOutput(text: error.localizedDescription, kind: "error")
        }
    }

    @objc private func selectionCaptureFromMenu() {
        do {
            try launchCapture(selection: true)
        } catch {
            lastResult = error.localizedDescription
            showOutput(text: error.localizedDescription, kind: "error")
        }
    }

    private func chooseCaptureRegionFromShortcut() {
        Task { @MainActor in
            let previousWindow = NSApp.keyWindow
            let shouldRestoreSettings = previousWindow === settingsWindowController?.window
            if shouldRestoreSettings {
                previousWindow?.orderOut(nil)
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            defer {
                if shouldRestoreSettings {
                    NSApp.activate(ignoringOtherApps: true)
                    previousWindow?.makeKeyAndOrderFront(nil)
                }
            }

            guard let rect = try? await SelectionCapture.selectRegion() else { return }
            draft.captureRegionEnabled = true
            draft.captureRegionX = rect.origin.x.rounded()
            draft.captureRegionY = rect.origin.y.rounded()
            draft.captureRegionWidth = rect.width.rounded()
            draft.captureRegionHeight = rect.height.rounded()
            draft.save()
            settingsWindowController?.reload()
            setStatus("固定截图区域已更新", kind: "ready")
        }
    }

    @objc private func cancelFromMenu() {
        cancelCapture()
    }

    @objc private func toggleResultFromMenu() {
        toggleResultPanel()
    }

    private func toggleResultPanel() {
        let text = lastResult.isEmpty ? statusText : lastResult
        if usingTouchBar {
            resultPanel.hideForCapture()
            touchBarResult.toggle(text: text, kind: statusKind)
        } else {
            touchBarResult.hideForCapture()
            resultPanel.toggle(text: text, kind: statusKind)
        }
    }

    @objc private func loginFromMenu() {
        startLoginFromSettings()
    }

    @objc private func logoutFromMenu() {
        logout()
    }

    private func logout() {
        // 取消在途任务并递增会话代际，作废旧回调，
        // 避免正在进行的 token 刷新完成后把凭证写回钥匙串。
        cancelCaptureForReplacementIfNeeded()
        clearBatchCaptureState()
        hideOutputForCapture()
        clientGeneration += 1
        KeychainStore.deleteCodexCredentialsAsync()
        credentials = nil
        credentialsLoaded = true
        lastResult = ""
        reloadRuntime()
        setStatus("已退出登录", kind: "warning")
        settingsWindowController?.reload()
    }

    func applicationWillTerminate(_ notification: Notification) {
        resultPanel.flushPendingFrame()
        clearBatchCaptureState()
    }

    /// 凭证彻底失效（invalid_grant）时清空本地登录状态，
    /// 让菜单/设置回到"请先登录"，而不是每次截图重复同一个报错。
    /// generation 是任务启动时的会话代际快照：旧会话的任务迟到的
    /// authExpired 不应该删掉用户刚重新登录好的新凭证。
    @discardableResult
    private func handleAuthExpiredIfNeeded(_ error: Error, generation: Int) -> Bool {
        guard case AppError.authExpired = error else { return false }
        guard generation == clientGeneration else { return false }
        clientGeneration += 1
        KeychainStore.deleteCodexCredentialsAsync()
        credentials = nil
        credentialsLoaded = true
        client = nil
        updateAccountMenuItems()
        settingsWindowController?.reload()
        return true
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum StatusIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()

        NSColor.black.setFill()

        if let context = NSGraphicsContext.current?.cgContext {
            context.addPath(CatBodyMark.appKitPath(in: CGRect(origin: .zero, size: image.size)))
            context.fillPath()

            // 模板图会由系统统一着色；脸部细节要以透明镂空而非另一种颜色绘制，
            // 才能在浅色和深色菜单栏中都保留嘴巴与胡须。
            let features = CatBodyMark.appKitFacialFeatures(in: CGRect(origin: .zero, size: image.size))
            context.setBlendMode(.clear)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(max(0.8, 2.6 / 100 * image.size.width))
            context.addPath(features.mouth)
            context.strokePath()
            context.addPath(features.mouthStem)
            context.strokePath()
            context.setLineWidth(max(0.7, 2.25 / 100 * image.size.width))
            context.addPath(features.whiskers)
            context.strokePath()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

final class ResultPanelWindow: NSPanel {
    private let resizeBorderWidth: CGFloat = 8

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown,
              let contentView,
              contentView.bounds.insetBy(dx: resizeBorderWidth, dy: resizeBorderWidth)
                .contains(contentView.convert(event.locationInWindow, from: nil)) else {
            super.sendEvent(event)
            return
        }

        performDrag(with: event)
    }
}

final class ResultPanelController: NSObject {
    private var panel: NSPanel?
    private let backgroundView = NSVisualEffectView()
    private let textView = NSTextView()
    private let indicatorView = PhaseIndicatorView()
    private let batchIndicatorView = BatchCaptureIndicatorView()
    private var panelWidth = ConfigDraft.defaultPanelWidth
    private var panelHeight = ConfigDraft.defaultPanelHeight
    private var panelOpacity = ConfigDraft.defaultPanelOpacity
    private var panelTextOpacity = ConfigDraft.defaultPanelTextOpacity
    private var panelFontSize = ConfigDraft.defaultPanelFontSize
    private var panelTextColor = ConfigDraft.defaultPanelTextColor
    private(set) var panelOrigin: NSPoint?
    private var indicatorWidthConstraint: NSLayoutConstraint?
    private var indicatorHeightConstraint: NSLayoutConstraint?
    private var batchIndicatorWidthConstraint: NSLayoutConstraint?
    private var batchIndicatorHeightConstraint: NSLayoutConstraint?
    private var currentText = ""
    private var renderMarkdown = true
    private var frameSaveDebounce: DispatchWorkItem?
    var onFrameChanged: ((Int, Int, Double, Double) -> Void)?

    func configure(
        width: Int,
        height: Int,
        opacity: Double,
        textOpacity: Double,
        fontSize: Double,
        textColor: TouchBarTextColor,
        originX: Double?,
        originY: Double?
    ) {
        panelWidth = width
        panelHeight = height
        panelOpacity = opacity
        panelTextOpacity = textOpacity
        panelFontSize = fontSize
        panelTextColor = textColor
        panelOrigin = if let originX, let originY {
            NSPoint(x: originX, y: originY)
        } else {
            nil
        }
        applyVisualSettings()
        guard let panel else { return }

        let newSize = NSSize(width: CGFloat(width), height: CGFloat(height))
        var frame = panel.frame
        frame.origin.y += frame.height - newSize.height
        frame.size = newSize
        panel.setFrame(frame, display: true)
        place(panel)
    }

    /// isStreaming=true：流式增量帧，用纯文本（跳过 Markdown 解析），
    /// 且面板已在屏时不重新 place/orderFront（避免每个 token 重排、重定位）。
    /// isStreaming=false：最终定稿，做一次完整 Markdown 渲染。
    func show(text: String, kind: String, autoScroll: Bool = false, isStreaming: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.show(text: text, kind: kind, autoScroll: autoScroll, isStreaming: isStreaming)
            }
            return
        }

        let alreadyVisible = panel?.isVisible == true
        let panel = panel ?? makePanel()
        self.panel = panel

        indicatorView.isHidden = true
        batchIndicatorView.isHidden = true
        currentText = text
        renderMarkdown = !isStreaming
        textView.isHidden = false
        applyVisualSettings()

        if autoScroll {
            textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        }

        // 流式帧且面板已在屏：跳过重定位与 orderFront，只更新文本。
        if !(isStreaming && alreadyVisible) {
            place(panel)
            panel.orderFrontRegardless()
        }
    }

    func showPhase(_ phase: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showPhase(phase)
            }
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        currentText = ""
        textView.isHidden = true
        indicatorView.isHidden = false
        batchIndicatorView.isHidden = true
        indicatorView.setPhase(phase)
        applyVisualSettings()

        place(panel)
        panel.orderFrontRegardless()
    }

    func showBatch(count: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.showBatch(count: count) }
            return
        }
        guard count > 0 else {
            hideForCapture()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        currentText = ""
        textView.isHidden = true
        indicatorView.isHidden = true
        batchIndicatorView.isHidden = false
        batchIndicatorView.setCount(count)
        applyVisualSettings()
        place(panel)
        panel.orderFrontRegardless()
    }

    func toggle(text: String, kind: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.toggle(text: text, kind: kind)
            }
            return
        }

        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            show(text: text, kind: kind)
        }
    }

    func hideForCapture() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.hideForCapture()
            }
            return
        }
        panel?.orderOut(nil)
    }

    func flushPendingFrame() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.flushPendingFrame() }
            return
        }
        frameSaveDebounce?.cancel()
        frameSaveDebounce = nil
        flushStoredFrame()
    }

    private func makePanel() -> NSPanel {
        let panel = ResultPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(panelWidth), height: CGFloat(panelHeight)),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.minSize = NSSize(width: 120, height: 42)
        panel.maxSize = NSSize(width: 900, height: 720)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backgroundView)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.isHidden = true
        batchIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        batchIndicatorView.isHidden = true

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(indicatorView)
        content.addSubview(batchIndicatorView)
        panel.contentView = root
        applyVisualSettings()

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: root.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            indicatorView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            indicatorView.topAnchor.constraint(equalTo: content.topAnchor),

            batchIndicatorView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            batchIndicatorView.topAnchor.constraint(equalTo: content.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let indicatorSize = CGFloat(panelFontSize)
        let widthConstraint = indicatorView.widthAnchor.constraint(equalToConstant: indicatorSize)
        let heightConstraint = indicatorView.heightAnchor.constraint(equalToConstant: indicatorSize)
        indicatorWidthConstraint = widthConstraint
        indicatorHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])

        let batchWidthConstraint = batchIndicatorView.widthAnchor.constraint(equalToConstant: 0)
        let batchHeightConstraint = batchIndicatorView.heightAnchor.constraint(equalToConstant: 0)
        batchIndicatorWidthConstraint = batchWidthConstraint
        batchIndicatorHeightConstraint = batchHeightConstraint
        NSLayoutConstraint.activate([batchWidthConstraint, batchHeightConstraint])

        return panel
    }

    private func applyVisualSettings() {
        backgroundView.alphaValue = CGFloat(panelOpacity)
        backgroundView.isHidden = panelOpacity <= 0.001
        let materialAppearance = backgroundView.effectiveAppearance
        textView.appearance = materialAppearance
        indicatorView.appearance = materialAppearance
        batchIndicatorView.appearance = materialAppearance

        // HUD 材质在不同 macOS 版本上可能采用不同的明暗外观。正文不是
        // backgroundView 的子视图（否则背景透明度会连带压低文字透明度），
        // 因此必须显式在材质外观中解析系统颜色，避免 Sequoia 上出现
        // 深色 HUD 配浅色 Aqua 的黑字，模型已返回但肉眼看不到。
        materialAppearance.performAsCurrentDrawingAppearance {
            let textColor = resolvedPanelTextColor()
            indicatorView.alphaValue = 1
            indicatorView.configure(color: textColor, opacity: panelTextOpacity)
            indicatorWidthConstraint?.constant = CGFloat(panelFontSize)
            indicatorHeightConstraint?.constant = CGFloat(panelFontSize)
            let batchStarSize = max(6, CGFloat(panelFontSize) * 0.5)
            batchIndicatorView.configure(color: textColor, opacity: panelTextOpacity, starSize: batchStarSize)
            batchIndicatorWidthConstraint?.constant = batchIndicatorView.intrinsicContentSize.width
            batchIndicatorHeightConstraint?.constant = batchIndicatorView.intrinsicContentSize.height

            let font = NSFont.systemFont(ofSize: CGFloat(panelFontSize))
            let color = textColor.withAlphaComponent(CGFloat(panelTextOpacity))
            textView.font = font
            textView.textColor = color
            if renderMarkdown {
                textView.textStorage?.setAttributedString(
                    MarkdownRenderer.render(currentText, font: font, color: color)
                )
            } else {
                // 流式增量帧：纯文本，跳过每 token 的 Markdown 解析开销。
                textView.textStorage?.setAttributedString(
                    NSAttributedString(string: currentText, attributes: [.font: font, .foregroundColor: color])
                )
            }
        }
    }

    private func resolvedPanelTextColor() -> NSColor {
        switch panelTextColor {
        case .system:
            if panelOpacity <= 0.05 {
                return .black
            }
            return .labelColor
        case .white: return .white
        case .black: return .black
        case .gray: return .systemGray
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }

    private func place(_ panel: NSPanel) {
        let frame = panel.frame

        // 找到存储位置所属的屏幕再做 clamp：accessory 应用几乎没有 key window，
        // NSScreen.main 会回落主屏，若拿主屏 clamp 会把拖到副屏的面板拽回主屏，
        // 还会立刻把被夹取后的坐标写回配置，永久丢掉用户摆放的位置。
        if let origin = panelOrigin {
            let center = NSPoint(x: origin.x + frame.width / 2, y: origin.y + frame.height / 2)
            let target = NSScreen.screens.first { $0.frame.contains(center) }
                ?? NSScreen.screens.first { $0.frame.intersects(NSRect(origin: origin, size: frame.size)) }
            if let target {
                panel.setFrameOrigin(clamped(origin, for: frame, in: target.visibleFrame))
                return
            }
        }

        // 没有存储位置，或所属显示器已被拔掉：回到主屏右上角默认位。
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = NSPoint(
            x: screen.maxX - frame.width - 22,
            y: screen.maxY - frame.height - 22
        )
        panel.setFrameOrigin(clamped(defaultOrigin, for: frame, in: screen))
    }

    private func clamped(_ origin: NSPoint, for frame: NSRect, in screen: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, screen.minX), screen.maxX - frame.width),
            y: min(max(origin.y, screen.minY), screen.maxY - frame.height)
        )
    }

}

extension ResultPanelController: NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) {
        updateStoredFrame(from: notification, persist: true)
    }

    func windowDidMove(_ notification: Notification) {
        // 拖动期间 AppKit 高频 post 移动通知；只更新内存几何，
        // 用去抖延迟落盘，避免每帧写整份配置。
        updateStoredFrame(from: notification, persist: false)
        frameSaveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushStoredFrame() }
        frameSaveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func updateStoredFrame(from notification: Notification, persist: Bool) {
        guard let panel = notification.object as? NSPanel else { return }
        let frame = panel.frame
        panelWidth = Int(frame.width.rounded())
        panelHeight = Int(frame.height.rounded())
        panelOrigin = frame.origin
        if persist {
            flushStoredFrame()
        }
    }

    private func flushStoredFrame() {
        frameSaveDebounce = nil
        guard let origin = panelOrigin else { return }
        onFrameChanged?(panelWidth, panelHeight, Double(origin.x), Double(origin.y))
    }
}

final class PhaseIndicatorView: NSView {
    private let padLayer = CAShapeLayer()
    private let toeLayers = (0..<4).map { _ in CAShapeLayer() }
    private var phase = "sending"
    private var tintColor: NSColor = .labelColor
    private var tintOpacity: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        updatePaths()
    }

    func setPhase(_ phase: String) {
        self.phase = phase
        setAccessibilityLabel(Self.accessibilityText(for: phase))
        updateAppearance()
    }

    private static func accessibilityText(for phase: String) -> String {
        switch phase {
        case "thinking": return "正在思考"
        case "receiving": return "正在接收回答"
        default: return "正在发送截图"
        }
    }

    func configure(color: NSColor, opacity: Double) {
        tintColor = color
        tintOpacity = CGFloat(min(1, max(0, opacity)))
        updateAppearance()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        ([padLayer] + toeLayers).forEach {
            $0.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer($0)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("正在处理")
        updateAppearance()
    }

    private func updatePaths() {
        let side = min(bounds.width, bounds.height)
        let origin = CGPoint(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + x * side,
                y: origin.y + y * side,
                width: w * side,
                height: h * side
            )
        }

        let padRect = rect(0.27, 0.15, 0.46, 0.40)
        padLayer.frame = padRect
        padLayer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: padRect.size), transform: nil)

        let toeRects = [
            rect(0.09, 0.54, 0.22, 0.24),
            rect(0.28, 0.70, 0.20, 0.22),
            rect(0.52, 0.70, 0.20, 0.22),
            rect(0.69, 0.54, 0.22, 0.24)
        ]

        for (layer, frame) in zip(toeLayers, toeRects) {
            layer.frame = frame
            layer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size), transform: nil)
        }
    }

    /// 停止动画（面板隐藏/收起时调用），避免隐藏的层上仍挂无限动画空转。
    func stopAnimating() {
        ([padLayer] + toeLayers).forEach { $0.removeAllAnimations() }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                stopAnimating()
            } else if oldValue {
                updateAppearance()
            }
        }
    }

    private func updateAppearance() {
        ([padLayer] + toeLayers).forEach { $0.removeAllAnimations() }

        let color = tintColor.withAlphaComponent(tintOpacity).cgColor
        padLayer.fillColor = color
        toeLayers.forEach { $0.fillColor = color }

        // 隐藏状态下只更新颜色/路径，不挂无限动画（否则每次显示答案面板都会
        // 在隐藏的猫爪层上重新装一遍动画，一直空转）。
        guard !isHidden else {
            updatePaths()
            return
        }

        let speed: CFTimeInterval
        switch phase {
        case "thinking":
            speed = 0.62
        case "receiving":
            speed = 0.72
        default:
            speed = 0.82
        }

        let now = CACurrentMediaTime()
        for (index, layer) in toeLayers.enumerated() {
            let lift = CABasicAnimation(keyPath: "transform.scale")
            lift.fromValue = 0.84
            lift.toValue = 1.08
            lift.duration = speed
            lift.beginTime = now + Double(index) * 0.12
            lift.autoreverses = true
            lift.repeatCount = .infinity
            layer.add(lift, forKey: "toeLift")
        }

        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.95
        breathe.toValue = 1.05
        breathe.duration = speed * 1.35
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        padLayer.add(breathe, forKey: "padBreath")

        updatePaths()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.finishLaunching()
app.run()
