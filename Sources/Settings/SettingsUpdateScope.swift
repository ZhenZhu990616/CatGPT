import Foundation

enum SettingsUpdateScope: Hashable {
    case appearance
    case shortcuts
    case client
    case storageOnly

    static func changed(from old: ConfigDraft, to new: ConfigDraft) -> Set<Self> {
        var result: Set<Self> = []

        if old.outputDisplayMode != new.outputDisplayMode
            || old.panelOpacity != new.panelOpacity
            || old.panelTextOpacity != new.panelTextOpacity
            || old.panelTextColor != new.panelTextColor
            || old.panelFontSize != new.panelFontSize
            || old.touchBarFontSize != new.touchBarFontSize
            || old.touchBarTextColor != new.touchBarTextColor
            || old.touchBarTextIntensity != new.touchBarTextIntensity
            || old.touchBarTextAlignment != new.touchBarTextAlignment {
            result.insert(.appearance)
        }

        if old.hotKeyText != new.hotKeyText
            || old.selectionHotKeyText != new.selectionHotKeyText
            || old.panelHotKeyText != new.panelHotKeyText
            || old.captureRegionHotKeyText != new.captureRegionHotKeyText
            || old.batchCaptureHotKeyText != new.batchCaptureHotKeyText {
            result.insert(.shortcuts)
        }

        if old.provider != new.provider
            || old.customBaseURL != new.customBaseURL
            || old.customAPIKey != new.customAPIKey
            || old.model != new.model
            || old.thinkingEnabled != new.thinkingEnabled
            || old.reasoningEffort != new.reasoningEffort
            || old.reasoningSummary != new.reasoningSummary
            || old.textVerbosity != new.textVerbosity
            || old.serviceTier != new.serviceTier
            || old.maxOutputTokens != new.maxOutputTokens
            || old.prompt != new.prompt
            || old.instructions != new.instructions
            || old.maxImageEdge != new.maxImageEdge {
            result.insert(.client)
        }

        if old.captureRegionEnabled != new.captureRegionEnabled
            || old.captureRegionX != new.captureRegionX
            || old.captureRegionY != new.captureRegionY
            || old.captureRegionWidth != new.captureRegionWidth
            || old.captureRegionHeight != new.captureRegionHeight
            || old.panelWidth != new.panelWidth
            || old.panelHeight != new.panelHeight
            || old.panelOriginX != new.panelOriginX
            || old.panelOriginY != new.panelOriginY {
            result.insert(.storageOnly)
        }

        return result
    }
}
