import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "CatGPTSettings.0.4.0"
    private let model: SettingsViewModel

    init(
        draftProvider: @escaping () -> ConfigDraft,
        stateProvider: @escaping () -> SettingsState,
        onApply: @escaping (ConfigDraft, SettingsUpdateScope) throws -> Void,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void,
        onPermission: @escaping () -> Void,
        onAccessibilityPermission: @escaping () -> Void = {},
        onVerifyExternalService: @escaping (ConfigDraft) async throws -> Void = { _ in }
    ) {
        model = SettingsViewModel(
            initialDraft: draftProvider(),
            draftProvider: draftProvider,
            stateProvider: stateProvider,
            applyDraft: onApply,
            onLogin: onLogin,
            onLogout: onLogout,
            onPermission: onPermission,
            onAccessibilityPermission: onAccessibilityPermission,
            onVerifyExternalService: onVerifyExternalService
        )

        let defaultContentSize = NSSize(width: 800, height: 580)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "CatGPT 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 520)
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        window.contentViewController = hosting
        window.setContentSize(defaultContentSize)
        Self.addSidebarDivider(to: window)

        super.init(window: window)

        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.reload()
    }

    func reload() {
        model.reload()
    }

    func select(sectionRaw: String) {
        if let section = SettingsSection(rawValue: sectionRaw) {
            model.selectedSection = section
        }
    }

    private static func addSidebarDivider(to window: NSWindow) {
        guard let contentView = window.contentView,
              let frameView = contentView.superview else { return }

        let divider = SettingsSidebarDividerView(
            frame: NSRect(x: 148, y: 0, width: 0.5, height: frameView.bounds.height)
        )
        divider.identifier = NSUserInterfaceItemIdentifier("CatGPTSettingsSidebarDivider")
        divider.autoresizingMask = .height
        frameView.addSubview(divider, positioned: .above, relativeTo: nil)
    }
}

private final class SettingsSidebarDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateDividerColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDividerColor()
    }

    private func updateDividerColor() {
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
    }
}
