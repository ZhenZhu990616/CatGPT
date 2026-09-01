import XCTest
@testable import CatGPT

final class ConfigDefaultsTests: XCTestCase {
    func testFloatingPanelUsesReadableFirstLaunchSize() {
        XCTAssertEqual(ConfigDraft.defaultPanelWidth, 520)
        XCTAssertEqual(ConfigDraft.defaultPanelHeight, 320)

        let aspectRatio = Double(ConfigDraft.defaultPanelWidth) / Double(ConfigDraft.defaultPanelHeight)
        XCTAssertGreaterThan(aspectRatio, 1.55)
        XCTAssertLessThan(aspectRatio, 1.70)
    }

    func testDefaultShortcutsUseModifierDoubleTaps() throws {
        XCTAssertEqual(ConfigDraft.defaultHotKey, "cmd double tap")
        XCTAssertEqual(ConfigDraft.defaultSelectionHotKey, "ctrl double tap")
        XCTAssertEqual(ConfigDraft.defaultPanelHotKey, "opt double tap")
        XCTAssertEqual(ConfigDraft.defaultCaptureRegionHotKey, "cmd+e")
        XCTAssertEqual(ConfigDraft.defaultBatchCaptureHotKey, "shift double tap")

        XCTAssertEqual(try Shortcut.parse(ConfigDraft.defaultHotKey).displayText, "⌘ double tap")
        XCTAssertEqual(try Shortcut.parse(ConfigDraft.defaultSelectionHotKey).displayText, "⌃ double tap")
        XCTAssertEqual(try Shortcut.parse(ConfigDraft.defaultPanelHotKey).displayText, "⌥ double tap")
        XCTAssertEqual(try Shortcut.parse(ConfigDraft.defaultCaptureRegionHotKey).displayText, "⌘ E")
        XCTAssertEqual(try Shortcut.parse(ConfigDraft.defaultBatchCaptureHotKey).displayText, "⇧ double tap")
    }

    func testCaptureRegionShortcutDefaultsWhenNoValueIsStored() {
        let defaults = UserDefaults.standard
        let key = "catGPT.captureRegionHotKey"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)

        XCTAssertEqual(ConfigDraft.load().captureRegionHotKeyText, ConfigDraft.defaultCaptureRegionHotKey)
    }

    func testLegacyCaptureRegionShortcutMigratesWithoutOverwritingCustomShortcut() {
        let defaults = UserDefaults.standard
        let keys = ["catGPT.captureRegionHotKey", "catGPT.captureRegionShortcutMigrationVersion"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.removeObject(forKey: "catGPT.captureRegionShortcutMigrationVersion")
        defaults.set("shift double tap", forKey: "catGPT.captureRegionHotKey")
        XCTAssertEqual(ConfigDraft.load().captureRegionHotKeyText, "cmd+e")

        defaults.removeObject(forKey: "catGPT.captureRegionShortcutMigrationVersion")
        defaults.set("cmd+shift+r", forKey: "catGPT.captureRegionHotKey")
        XCTAssertEqual(ConfigDraft.load().captureRegionHotKeyText, "cmd+shift+r")
    }

    func testLegacyDefaultShortcutsMigrateWithoutOverwritingCustomShortcut() {
        let defaults = UserDefaults.standard
        let keys = [
            "catGPT.hotKey",
            "catGPT.selectionHotKey",
            "catGPT.panelHotKey",
            "catGPT.shortcutDefaultsMigrationVersion"
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.removeObject(forKey: "catGPT.shortcutDefaultsMigrationVersion")
        defaults.set("cmd+shift+l", forKey: "catGPT.hotKey")
        defaults.set("cmd+shift+k", forKey: "catGPT.selectionHotKey")
        defaults.set("cmd+shift+p", forKey: "catGPT.panelHotKey")

        let draft = ConfigDraft.load()

        XCTAssertEqual(draft.hotKeyText, ConfigDraft.defaultHotKey)
        XCTAssertEqual(draft.selectionHotKeyText, ConfigDraft.defaultSelectionHotKey)
        XCTAssertEqual(draft.panelHotKeyText, "cmd+shift+p")
        XCTAssertEqual(defaults.string(forKey: "catGPT.hotKey"), ConfigDraft.defaultHotKey)
        XCTAssertEqual(defaults.string(forKey: "catGPT.selectionHotKey"), ConfigDraft.defaultSelectionHotKey)
        XCTAssertEqual(defaults.string(forKey: "catGPT.panelHotKey"), "cmd+shift+p")
    }

    func testSupportedGPT55ModelIsNotMigratedOnNextLaunch() {
        let defaults = UserDefaults.standard
        let key = "catGPT.model"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set("gpt-5.5", forKey: key)

        XCTAssertEqual(ConfigDraft.load().model, "gpt-5.5")
    }

    func testUnknownModelCannotBuildClientConfiguration() {
        var draft = ConfigDraft.load()
        draft.model = "gpt-not-a-real-model"
        let credentials = CodexOAuthCredentials(
            access: "access",
            refresh: "refresh",
            expires: Date().timeIntervalSince1970 + 3600,
            accountId: "account"
        )

        XCTAssertThrowsError(try draft.makeConfig(codexCredentials: credentials)) { error in
            XCTAssertEqual(error.localizedDescription, "模型输入有误。")
        }
    }

    func testOpenAICompatibleConfigurationDoesNotRequireCodexCredentials() throws {
        var draft = ConfigDraft.load()
        draft.provider = .openAICompatible
        draft.customBaseURL = "https://example.com/v1"
        draft.customAPIKey = "test-key"
        draft.model = "local-vision-model"

        let config = try draft.makeConfig(codexCredentials: nil)

        XCTAssertEqual(config.provider, .openAICompatible)
        XCTAssertNil(config.codexCredentials)
        XCTAssertEqual(config.customBaseURL, "https://example.com/v1")
        XCTAssertEqual(config.customAPIKey, "test-key")
        XCTAssertEqual(config.model, "local-vision-model")
    }
}
