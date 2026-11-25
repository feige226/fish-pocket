import SwiftUI

/// 设置 → 语音消息: where the agent may answer with a voice message (ordinary sessions and Bot
/// chats apart), the rule it follows for when one fits, and which speech reads them.
struct VoiceMessageSettingsPage: View {
    @State private var settings = VoiceMessageSettings.shared
    /// The rule as typed; saved after a pause and when leaving, not on every key.
    @State private var draft = VoiceMessageSettings.shared.guidance
    /// nil while it is being found out.
    @State private var voice: SynthesisVoice??

    var body: some View {
        List {
            Section {
                Text("允许后，AI 会自己判断什么时候用语音回复你，像微信里的语音消息一样，轻点就能听。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            Section {
                Toggle("会话", isOn: $settings.allowSessions)
                Toggle("Bot 聊天", isOn: $settings.allowBots)
            } header: {
                Text("允许发送语音消息")
            } footer: {
                Text("群聊、子智能体、语音通话中，以及从微信等 IM 渠道发来的消息，都不会收到语音消息。")
            }
            .groupedRow()

            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 140)
                    .font(.body)
                if draft != VoiceMessageSettings.defaultGuidance {
                    Button("恢复默认") {
                        Haptics.tap()
                        draft = VoiceMessageSettings.defaultGuidance
                        settings.setGuidance(draft)
                    }
                }
            } header: {
                Text("什么时候发")
            } footer: {
                Text("这段话会告诉 AI 什么时候适合发语音，可以按你的习惯改。语音里怎么说（口语、简短、不念代码和链接）由 App 固定告诉它，不用写在这里。")
            }
            .groupedRow()

            Section {
                voiceLine
            } header: {
                Text("声音")
            }
            .groupedRow()
        }
        .groupedList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("语音消息")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: draft) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            settings.setGuidance(draft)
        }
        .task {
            let first = await SynthesisVoice.chosen()
            voice = .some(first)
        }
        .onDisappear { settings.setGuidance(draft) }
    }

    @ViewBuilder
    private var voiceLine: some View {
        switch voice {
        case nil:
            ProgressView()
        case .some(nil):
            Label {
                Text("还没有可用的语音合成，AI 暂时不会发语音消息。在「语音通话」里填写火山引擎的 API Key，或在「模型」里填写 DeepSeek API Key 后就能用。")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.waiting)
            }
        case .some(.volcengine?):
            VStack(alignment: .leading, spacing: 6) {
                Text("用火山引擎，和语音通话同一个声音（\(CallVoice.chosen.name)），费用由火山引擎按字数收取。")
                    .font(.subheadline)
                ownVoices
            }
        case .some(.deepseek(let reading)?):
            VStack(alignment: .leading, spacing: 6) {
                Text("用 DeepSeek，和朗读同一个声音（\(reading.title)），费用由 DeepSeek 按字数收取。")
                    .font(.subheadline)
                ownVoices
            }
        }
    }

    private var ownVoices: some View {
        Text("Bot 和会话可以单独选声音：Bot 详情页、会话标题菜单里的「声音」。没单独选的用这个。")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
