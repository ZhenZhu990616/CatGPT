import SwiftUI

struct ServiceSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsPage(
            title: "服务",
            subtitle: "管理账号、系统权限和 CatGPT 的运行状态。"
        ) {
            VStack(spacing: 24) {
                SettingsGroup("当前服务") {
                    SettingsRow("接口类型", subtitle: model.draft.provider.title) {
                        EmptyView()
                    }
                    if model.draft.provider == .openAICompatible {
                        SettingsDivider()
                        SettingsRow(
                            "连接状态",
                            subtitle: model.externalServiceStatusText
                        ) {
                            Image(
                                systemName: model.isVerifyingExternalService
                                    ? "hourglass"
                                    : (model.externalServiceVerificationSucceeded
                                        ? "checkmark.circle.fill"
                                        : "circle")
                            )
                            .foregroundStyle(
                                model.externalServiceVerificationSucceeded ? .green : .secondary
                            )
                        }
                    }
                }

                if model.draft.provider == .codex {
                    SettingsGroup("Codex 账号") {
                        SettingsRow("账号", subtitle: model.accountText) {
                            HStack(spacing: 8) {
                                if model.state.signedIn {
                                    Button("退出登录", role: .destructive) { model.logout() }
                                }
                                Button(model.state.signedIn ? "重新登录…" : "登录 ChatGPT…") { model.login() }
                            }
                        }
                    }
                } else {
                    SettingsGroup("OpenAI 兼容服务") {
                        SettingsRow("API 地址", subtitle: "可填写服务根地址，也可直接填写 /chat/completions") {
                            TextField("https://api.openai.com/v1", text: model.textBinding(\ConfigDraft.customBaseURL, field: .customBaseURL))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .settingsInputSurface()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 280)
                                .accessibilityLabel("API 地址")
                        }
                        if let error = model.error(for: .customBaseURL) {
                            SettingsInlineMessage(text: error, systemImage: "exclamationmark.triangle.fill", color: .red)
                        }

                        SettingsDivider()
                        SettingsRow("API Key", subtitle: "保存在 macOS 钥匙串；本地服务可留空") {
                            SecureField("可选", text: model.textBinding(\ConfigDraft.customAPIKey, field: .customAPIKey))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .settingsInputSurface()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 220)
                                .accessibilityLabel("API Key")
                        }
                        SettingsDivider()
                        SettingsRow(
                            "验证连接",
                            subtitle: "发送一次最小请求，检查地址、API Key 和模型"
                        ) {
                            Button {
                                model.verifyExternalServiceConnection()
                            } label: {
                                HStack(spacing: 6) {
                                    if model.isVerifyingExternalService {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "checkmark.shield")
                                    }
                                    Text(model.isVerifyingExternalService ? "验证中…" : "验证连接")
                                }
                            }
                            .disabled(model.isVerifyingExternalService)
                            .accessibilityLabel("验证外部 LLM 连接")
                        }
                        if let message = model.externalServiceVerificationMessage,
                           !model.isVerifyingExternalService {
                            SettingsInlineMessage(
                                text: message,
                                systemImage: model.externalServiceVerificationSucceeded
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill",
                                color: model.externalServiceVerificationSucceeded ? .green : .red
                            )
                        }
                    }
                }

                SettingsGroup("权限") {
                    SettingsRow("屏幕录制", subtitle: model.permissionText) {
                        HStack(spacing: 8) {
                            Image(systemName: model.state.screenPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(model.state.screenPermission ? .green : .orange)
                            Button("打开系统设置…") { model.requestScreenPermission() }
                        }
                    }
                    SettingsDivider()
                    SettingsRow("辅助功能", subtitle: model.accessibilityPermissionText) {
                        HStack(spacing: 8) {
                            Image(systemName: model.state.accessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(model.state.accessibilityPermission ? .green : .orange)
                            Button("请求授权…") { model.requestAccessibilityPermission() }
                        }
                    }
                }

                SettingsGroup("运行") {
                    SettingsRow("状态", subtitle: model.state.statusText) {
                        EmptyView()
                    }
                    SettingsDivider()
                    SettingsRow("快捷键", subtitle: model.state.hotKeyStatus) {
                        EmptyView()
                    }
                    SettingsDivider()
                    SettingsRow(
                        "开机自启",
                        subtitle: model.launchAtLoginAvailable
                            ? (model.launchAtLoginError ?? "登录系统后自动运行 CatGPT")
                            : "需要以 .app 打包运行后才能启用"
                    ) {
                        SettingsCheckbox(
                            isOn: launchAtLoginBinding,
                            accessibilityLabel: "开机自启"
                        )
                    }
                    .disabled(!model.launchAtLoginAvailable)
                    if let error = model.launchAtLoginError {
                        SettingsInlineMessage(text: error, systemImage: "exclamationmark.triangle.fill", color: .orange)
                    }
                }

                SettingsGroup("关于") {
                    SettingsRow("版本", subtitle: versionText) {
                        EmptyView()
                    }
                    SettingsDivider()
                    SettingsRow("运行方式", subtitle: "菜单栏常驻，截图、框选与浮窗均由快捷键触发") {
                        EmptyView()
                    }
                }
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
    }
}
