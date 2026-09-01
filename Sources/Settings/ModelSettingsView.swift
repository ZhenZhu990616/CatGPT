import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsPage(
            title: "模型",
            subtitle: "配置服务模型、推理强度与回答输出。"
        ) {
            VStack(spacing: 24) {
                SettingsGroup("服务") {
                    SettingsRow("接口类型", subtitle: "选择内置 ChatGPT/Codex，或使用任意 OpenAI 兼容服务") {
                        SettingsMenuPicker(
                            selection: model.binding(\ConfigDraft.provider, scope: .client),
                            options: LLMProvider.allCases,
                            title: \.title,
                            accessibilityLabel: "接口类型"
                        )
                        .frame(width: 190)
                    }

                }
                SettingsGroup("模型") {
                    SettingsRow(
                        "模型 ID",
                        subtitle: model.draft.provider == .codex
                            ? "发送给 Codex Responses 的 model 字段"
                            : "发送给 /chat/completions 的 model 字段"
                    ) {
                        TextField("模型 ID", text: model.textBinding(\ConfigDraft.model, field: .model))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .settingsInputSurface()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 240)
                            .help("请输入支持的模型 ID")
                            .accessibilityLabel("模型 ID")
                    }
                    if let error = model.error(for: .model) {
                        SettingsInlineMessage(text: error, systemImage: "exclamationmark.triangle.fill", color: .red)
                    }

                    SettingsDivider()
                    SettingsRow("Thinking", subtitle: "关闭时发送 reasoning.effort = none") {
                        SettingsCheckbox(
                            isOn: model.binding(\ConfigDraft.thinkingEnabled, scope: .client),
                            accessibilityLabel: "Thinking"
                        )
                    }
                    SettingsDivider()
                    SettingsRow("智能程度", subtitle: "对应 reasoning.effort；超高仅部分模型支持") {
                        SettingsSegmentedPicker(
                            selection: model.binding(\ConfigDraft.reasoningEffort, scope: .client),
                            options: ReasoningEffort.allCases,
                            title: \.title,
                            accessibilityLabel: "智能程度"
                        )
                        .frame(width: 280)
                    }
                    .disabled(!model.draft.thinkingEnabled)
                    SettingsDivider()
                    SettingsRow("思考摘要", subtitle: "对应 reasoning.summary；关闭时不传该字段") {
                        SettingsMenuPicker(
                            selection: model.binding(\ConfigDraft.reasoningSummary, scope: .client),
                            options: ReasoningSummary.allCases,
                            title: \.title,
                            accessibilityLabel: "思考摘要"
                        )
                        .frame(width: 132)
                    }
                    .disabled(!model.draft.thinkingEnabled)
                }

                SettingsGroup("输出") {
                    SettingsRow("输出详略", subtitle: "控制回答的文字密度") {
                        SettingsSegmentedPicker(
                            selection: model.binding(\ConfigDraft.textVerbosity, scope: .client),
                            options: TextVerbosity.allCases,
                            title: \.title,
                            accessibilityLabel: "输出详略"
                        )
                        .frame(width: 190)
                    }
                    SettingsDivider()
                    SettingsRow("服务层级", subtitle: "系统默认表示不传 service_tier 字段") {
                        SettingsMenuPicker(
                            selection: model.binding(\ConfigDraft.serviceTier, scope: .client),
                            options: ServiceTier.allCases,
                            title: \.title,
                            accessibilityLabel: "服务层级"
                        )
                        .frame(width: 132)
                    }
                    SettingsDivider()
                    SettingsRow("输出上限", subtitle: "max_output_tokens；0 表示不设置") {
                        TextField("0", value: maxOutputTokensBinding, format: .number.grouping(.never))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .settingsInputSurface()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 92)
                    }
                    SettingsDivider()
                    SettingsRow("图片最大边长", subtitle: "截图等比压缩到该边长以内，最小 640") {
                        TextField("1600", value: maxImageEdgeBinding, format: .number.grouping(.never))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .settingsInputSurface()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 92)
                    }
                }
            }
        }
    }

    private var maxOutputTokensBinding: Binding<Int> {
        Binding(
            get: { model.draft.maxOutputTokens },
            set: { model.setMaxOutputTokens($0) }
        )
    }

    private var maxImageEdgeBinding: Binding<Int> {
        Binding(
            get: { model.draft.maxImageEdge },
            set: { model.setMaxImageEdge($0) }
        )
    }
}
