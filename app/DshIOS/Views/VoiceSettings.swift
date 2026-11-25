import AVFoundation
import SwiftUI

/// 设置 → 语音输入: which service recognizes hold-to-talk. DeepSeek uses the key or account the
/// models already use; Volcengine (豆包语音) takes the user's own API Key: how to get one, where
/// it goes, and a check that it works. Also the sheet the microphone button opens when
/// Volcengine is chosen without a key; `onReady` then runs once a working service is set up.
struct VoiceInputSettingsPage: View {
    var onReady: (() -> Void)?
    @State private var preferences = VoicePreferences.shared
    @State private var checking = false
    @State private var status: Status?

    private enum Status: Equatable {
        case passed
        case failed(String)
    }

    var body: some View {
        List {
            Section {
                Text("按住输入栏说话，松手把识别出的文字发出去。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            Section {
                Picker("识别服务", selection: $preferences.source) {
                    ForEach(VoicePreferences.Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerValueTint()
            } footer: {
                switch preferences.source {
                case .deepseek:
                    Text("用你在「模型」里填写的 DeepSeek API Key，没有 Key 时用登录的 DeepSeek 账号（DeepSeek 目前还不支持账号登录使用语音），费用由 DeepSeek 按录音时长收取。松手后整段识别，说话时不显示文字。录音直接发给 DeepSeek 识别，App 不保存录音。")
                case .volcengine:
                    if FishPocketAPI.available {
                        Text("说话时文字就会出现。用 Fish Pocket 账号还是自己的 API Key 接入火山引擎，在下面选。")
                    } else {
                        Text("说话时文字就会出现。需要你自己开通火山引擎的豆包语音并填写 API Key，费用由火山引擎按你的用量收取。API Key 只保存在这台设备本地，只用来连接火山引擎，不会上传到其他任何地方。")
                    }
                }
            }
            .groupedRow()
            .onChange(of: preferences.source) { status = nil }

            if preferences.source == .deepseek {
                Section {
                    Button { checkDeepSeek() } label: {
                        HStack(spacing: 8) {
                            if checking { ProgressView().tint(Palette.onInk) }
                            Text("测试连接")
                        }
                    }
                    .buttonStyle(.capsule(height: 50))
                    .disabled(checking)
                } footer: {
                    switch status {
                    case .passed:
                        Label("连接成功，可以按住说话了", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    case nil:
                        EmptyView()
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else {
                VolcKeySection(purpose: .input, onReady: onReady)
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("语音输入")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Half a second of silence through DeepSeek: an empty answer means the key works.
    private func checkDeepSeek() {
        Haptics.tap()
        checking = true
        status = nil
        Task {
            do {
                _ = try await DeepSeekSpeech.transcribe(wav: DeepSeekSpeech.wave(pcm: Data(count: 16_000), sampleRate: 16_000))
                status = .passed
                Haptics.success()
                if let onReady {
                    try? await Task.sleep(for: .milliseconds(600))
                    onReady()
                }
            } catch {
                status = .failed(error.localizedDescription)
                Haptics.error()
            }
            checking = false
        }
    }
}

/// How Volcengine (豆包语音) is reached, picked by the user: their Fish Pocket account, paid in
/// credits through its relay, or their own API Key (where it goes, the billing it was opened with,
/// how to get one). Either way a check that it works for what it is for: hold-to-talk needs
/// streaming recognition; reading aloud needs synthesis 2.0; a call needs both, and the check
/// tries both. The two ways never stand in for each other.
struct VolcKeySection: View {
    enum Purpose { case input, call, reading }

    let purpose: Purpose
    var onReady: (() -> Void)?
    @Environment(AppModel.self) private var app
    @State private var speech = VolcSpeech.shared
    @State private var draft = ""
    @State private var checking = false
    @State private var status: Status?

    private enum Status: Equatable {
        case passed
        case failed(String)
    }

    var body: some View {
        if FishPocketAPI.available {
            Section {
                Picker("接入方式", selection: $speech.route) {
                    ForEach(VolcSpeech.Route.allCases) { Text($0.title).tag($0) }
                }
                .pickerValueTint()
            } header: {
                Text("火山引擎")
            } footer: {
                switch speech.route {
                case .fishPocket:
                    Text("不用自己开通火山引擎：费用从 Fish Pocket 账号的积分里扣，按用量计费。声音经 Fish Pocket 的服务器转给火山引擎，服务器不保存录音。")
                case .ownKey:
                    Text("用你自己在火山引擎开通的服务和 API Key，费用由火山引擎按你的用量收取。声音直接发给火山引擎。")
                }
            }
            .groupedRow()
            .onChange(of: speech.route) { status = nil }
        }

        switch speech.route {
        case .fishPocket: fishPocket
        case .ownKey: ownKey
        }

        Section {
            Button {
                if speech.route == .ownKey, !speech.configured { use(draft) } else { check() }
            } label: {
                HStack(spacing: 8) {
                    if checking { ProgressView().tint(Palette.onInk) }
                    Text(speech.route == .ownKey && !speech.configured ? "保存并测试" : "测试连接")
                }
            }
            .buttonStyle(.capsule(height: 50))
            .disabled(checking || !canCheck)
        } footer: {
            statusFooter
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())

        if speech.route == .ownKey, !speech.configured {
            Section {
                step(1, "登录火山引擎的豆包语音控制台，没有账号先注册并完成实名认证。")
                switch purpose {
                case .input: step(2, "开通「豆包流式语音识别模型 2.0」。")
                case .call: step(2, "开通「豆包流式语音识别模型 2.0」和「豆包语音合成模型 2.0」。")
                case .reading: step(2, "开通「豆包语音合成模型 2.0」。")
                }
                step(3, "在「API Key 管理」里创建一个 Key 并复制，回到这里粘贴到上面。")
                Link(destination: VolcSpeech.keysURL) {
                    Label("打开豆包语音控制台", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("还没有 API Key？")
            }
            .groupedRow()
        }
    }

    private var canCheck: Bool {
        switch speech.route {
        case .fishPocket: speech.configured
        case .ownKey: speech.configured || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The account the credits come from, or the way to sign in.
    private var fishPocket: some View {
        Section {
            let account = app.fishPocket
            if account.signedIn {
                NavigationLink { FishPocketPage() } label: {
                    LabeledContent {
                        if let balance = account.balance {
                            Text("\(balance) 积分").monospacedDigit()
                        }
                    } label: {
                        Text(account.user?.label ?? String(localized: "已登录"))
                    }
                }
            } else {
                NavigationLink { FishPocketPage() } label: {
                    Text("登录 Fish Pocket 账号")
                }
            }
        } header: {
            Text("Fish Pocket 账号")
        } footer: {
            switch purpose {
            case .input:
                Text("识别用的是豆包流式语音识别模型 2.0，按录音时长计费。")
            case .call:
                Text("听你说话用豆包流式语音识别模型 2.0，按通话时长计费；回答的声音用豆包语音合成模型 2.0，按字数计费。余额用完时通话会挂断。")
            case .reading:
                Text("朗读用豆包语音合成模型 2.0，按字数计费。")
            }
        }
        .groupedRow()
        .task { await app.fishPocket.refresh() }
    }

    /// The user's own key: the key comes first, in the top half of the page, where the keyboard
    /// never covers it.
    @ViewBuilder
    private var ownKey: some View {
        Section {
            if let key = speech.key, !key.isEmpty {
                LabeledContent("API Key") {
                    Text(verbatim: Self.masked(key)).monospaced().foregroundStyle(.secondary)
                }
                Button("删除 Key", role: .destructive) {
                    speech.removeKey()
                    status = nil
                }
            } else {
                HStack(spacing: 10) {
                    SecureField("粘贴或输入 API Key", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { use(draft) }
                    // The system's paste button: one tap fills the key in and checks it, without a paste prompt.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in use(text) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .inkTint()
                }
            }
            // How recognition is paid for: reading aloud does not recognize anything.
            if purpose != .reading {
                Picker("计费方式", selection: $speech.resource) {
                    ForEach(VolcSpeech.Resource.allCases) { Text($0.title).tag($0) }
                }
                .pickerValueTint()
            }
        } header: {
            Text(FishPocketAPI.available ? "API Key" : "火山引擎")
        } footer: {
            switch purpose {
            case .input:
                Text("识别用的是豆包流式语音识别模型 2.0。计费方式要和你在控制台开通的一致，没特别选过就用「小时版」。录音直接发给火山引擎识别，App 不保存录音。")
            case .call:
                Text("听你说话用豆包流式语音识别模型 2.0，回答的声音用豆包语音合成模型 2.0，两个都要在控制台开通，费用由火山引擎按你的用量收取。计费方式指识别的计费方式，要和控制台开通的一致，没特别选过就用「小时版」。通话的声音直接发给火山引擎，App 不保存录音。API Key 和按住说话共用，只保存在这台设备本地。")
            case .reading:
                Text("朗读用豆包语音合成模型 2.0，要在控制台开通，费用由火山引擎按字数收取。API Key 和按住说话、语音通话共用，只保存在这台设备本地。")
            }
        }
        .groupedRow()
        .onChange(of: speech.resource) { status = nil }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Palette.onInk)
                .frame(width: 20, height: 20)
                .background(Palette.ink, in: Circle())
            Text(text).font(.subheadline)
        }
    }

    /// Save a pasted or typed key and check it.
    private func use(_ text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        dismissKeyboard()
        speech.save(key: key)
        draft = ""
        check()
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch status {
        case .passed:
            Group {
                switch purpose {
                case .input: Label("连接成功，可以按住说话了", systemImage: "checkmark.circle.fill")
                case .call: Label("连接成功，可以打电话了", systemImage: "checkmark.circle.fill")
                case .reading: Label("连接成功，可以朗读了", systemImage: "checkmark.circle.fill")
                }
            }
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity)
        case .failed(let message):
            Text(message).foregroundStyle(.red).frame(maxWidth: .infinity).multilineTextAlignment(.center)
        case nil:
            EmptyView()
        }
    }

    private func passed() {
        status = .passed
        Haptics.success()
        if let onReady {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                onReady()
            }
        }
    }

    private func check() {
        guard let credential = speech.credential else { return }
        Haptics.tap()
        checking = true
        status = nil
        let purpose = purpose
        Task {
            do {
                if purpose != .reading { try await VolcSpeech.check(credential) }
                if purpose != .input { try await CallSynthesizer.check(credential) }
                passed()
            } catch {
                status = .failed(error.localizedDescription)
                Haptics.error()
            }
            checking = false
        }
    }

    /// The first and last four characters.
    private static func masked(_ key: String) -> String {
        guard key.count > 10 else { return String(repeating: "•", count: key.count) }
        return key.prefix(4) + "••••" + key.suffix(4)
    }
}

/// 设置 → 朗读: which service reads replies aloud, picked by the user, and its voice. DeepSeek has
/// voices of its own; Volcengine speaks in the call's voice and is reached the way calls are.
struct ReadAloudSettingsPage: View {
    @State private var preferences = VoicePreferences.shared
    @State private var reading = ReadAloud.shared
    @State private var speech = VolcSpeech.shared
    @State private var callVoice = CallVoice.chosen
    @State private var preview = VoicePreview.shared

    var body: some View {
        List {
            Section {
                Picker("朗读服务", selection: $preferences.readingSource) {
                    ForEach(VoicePreferences.Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerValueTint()
            } footer: {
                switch preferences.readingSource {
                case .deepseek:
                    Text("朗读回复用 DeepSeek 的声音，同样用「模型」里的 DeepSeek API Key，费用由 DeepSeek 按字数收取。没有设置火山引擎时，语音消息也用这个声音。")
                case .volcengine:
                    Text("朗读回复用豆包语音合成模型 2.0，声音和接入方式都和语音通话共用。")
                }
            }
            .groupedRow()

            switch preferences.readingSource {
            case .deepseek:
                deepSeekVoices
                Section {
                    Button {
                        Haptics.tap()
                        if reading.speaking {
                            reading.stop()
                        } else {
                            reading.enqueue(String(localized: "你好，我会用这个声音为你朗读。"), voice: .deepseek(preferences.readingVoice))
                        }
                    } label: {
                        Text(reading.speaking ? "停止" : "试听")
                    }
                    .buttonStyle(.capsule(height: 50))
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            case .volcengine:
                // Without a way in, that comes first: nothing is read until it is set up.
                if speech.configured {
                    volcengineVoices
                    VolcKeySection(purpose: .reading)
                } else {
                    VolcKeySection(purpose: .reading)
                    volcengineVoices
                }
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("朗读")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: preferences.readingVoice) { ReadAloud.shared.stop() }
        .onChange(of: preferences.readingSource) {
            ReadAloud.shared.stop()
            preview.stop()
        }
        .onChange(of: callVoice) { CallVoice.chosen = callVoice }
        .onDisappear {
            ReadAloud.shared.stop()
            preview.stop()
        }
    }

    private var deepSeekVoices: some View {
        Section {
            ForEach(DeepSeekSpeech.Voice.allCases) { voice in
                Button {
                    Haptics.select()
                    preferences.readingVoice = voice
                } label: {
                    HStack {
                        Text(voice.title).foregroundStyle(Palette.ink)
                        Spacer()
                        if preferences.readingVoice == voice {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("声音")
        }
        .groupedRow()
    }

    private var volcengineVoices: some View {
        Section {
            ForEach(CallVoice.all) { item in
                CallVoiceRow(voice: item, selected: callVoice == item, purpose: .reading) { callVoice = item }
            }
        } header: {
            Text("声音")
        } footer: {
            Text("和语音通话、语音消息是同一个声音，在这里改了那边也跟着变。试听按火山引擎的价格计费。")
        }
        .groupedRow()
    }
}

/// The microphone permission: asked for on the first press of the voice bar.
@MainActor
enum MicrophoneAccess {
    enum State { case granted, denied, undecided }

    static var state: State {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undecided
        }
    }

    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
