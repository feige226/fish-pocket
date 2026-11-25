import AVFoundation
import Observation
import SwiftUI

/// 设置 → 语音通话: the voice the answers are spoken in, each one heard before picking it, and
/// the Volcengine key with a check that recognition and synthesis 2.0 both work. Also the sheet the
/// call button opens without a key; `onReady` then runs once the check passes.
struct VoiceCallSettingsPage: View {
    var onReady: (() -> Void)?
    @State private var speech = VolcSpeech.shared
    @State private var voice = CallVoice.chosen
    @State private var preview = VoicePreview.shared

    var body: some View {
        List {
            Section {
                Text("在会话和 Bot 的聊天里，输入框空着时点右边的波形按钮，就能像打电话一样和它说话：直接说，说完停一下它就回答；它说话时你一开口，它就停下来听你说。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            // Without a key the key comes first: nothing works until it is in.
            if speech.configured {
                voices
                VolcKeySection(purpose: .call, onReady: onReady)
            } else {
                VolcKeySection(purpose: .call, onReady: onReady)
                voices
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("语音通话")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: voice) { CallVoice.chosen = voice }
        .onDisappear { preview.stop() }
    }

    private var voices: some View {
        Section {
            ForEach(CallVoice.all) { item in
                CallVoiceRow(voice: item, selected: voice == item) { voice = item }
            }
        } header: {
            Text("声音")
        } footer: {
            Text("回答用这个声音念出来，是豆包语音合成模型 2.0 的音色。试听也按火山引擎的价格计费；通话中改了声音，下一通电话生效。")
        }
        .groupedRow()
    }
}

/// One voice to pick, with a button to hear it first.
struct CallVoiceRow: View {
    let voice: CallVoice
    let selected: Bool
    /// What the sample line says it is for.
    var purpose: VoicePreview.Purpose = .call
    let select: () -> Void
    @State private var speech = VolcSpeech.shared
    @State private var preview = VoicePreview.shared

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.select()
                select()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: voice.name).foregroundStyle(Palette.ink)
                        Text(voice.kind).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                Haptics.tap()
                if preview.playing == voice.id { preview.stop() } else { preview.play(voice, for: purpose) }
            } label: {
                Group {
                    if preview.loading == voice.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: preview.playing == voice.id ? "stop.circle.fill" : "play.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(Palette.ink)
                    }
                }
                .frame(width: 30, height: 30)
                .hitTarget()
            }
            .buttonStyle(.plain)
            .disabled(!speech.configured || CallCenter.shared.active)
            .accessibilityLabel(preview.playing == voice.id ? Text("停止试听") : Text("试听"))
        }
    }
}

/// 声音 for one Bot or one conversation: voices of its own for reading aloud and for calls, or the
/// defaults. Reading with Volcengine goes with the call voice, so then there is one list for both.
struct VoicePickerPage: View {
    let owner: VoiceOwner
    @State private var choices = VoiceChoices.shared
    @State private var preferences = VoicePreferences.shared
    @State private var speech = VolcSpeech.shared
    @State private var preview = VoicePreview.shared
    @State private var reading = ReadAloud.shared
    /// The reading voice being tried here.
    @State private var trying: DeepSeekSpeech.Voice?

    var body: some View {
        let readingPicked = choices.readingVoice(of: owner)
        let callPicked = choices.callVoice(of: owner)
        let readsWithVolcengine = preferences.readingSource == .volcengine
        List {
            if !readsWithVolcengine { Section {
                DefaultVoiceRow(current: VoicePreferences.shared.readingVoice.title, selected: readingPicked == nil) {
                    choices.setReadingVoice(nil, for: owner)
                }
                ForEach(DeepSeekSpeech.Voice.allCases) { voice in
                    ReadingVoiceRow(voice: voice, selected: readingPicked == voice, trying: $trying) {
                        choices.setReadingVoice(voice, for: owner)
                    }
                }
            } header: {
                Text("朗读")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    switch owner {
                    case .bot: Text("朗读这个 Bot 的回复时用这里选的声音，群聊里它的发言也一样。跟随默认时，用「设置 → 朗读」里选的声音。")
                    case .session: Text("朗读这个会话的回复时用这里选的声音。跟随默认时，用「设置 → 朗读」里选的声音。")
                    }
                    // Voice messages are read by Volcengine when its key is saved, else by DeepSeek.
                    if !speech.configured { Text("AI 发来的语音消息也用这里的声音。") }
                }
            }
            .groupedRow() }
            Section {
                DefaultVoiceRow(current: CallVoice.chosen.name, selected: callPicked == nil) {
                    choices.setCallVoice(nil, for: owner)
                }
                ForEach(CallVoice.all) { item in
                    CallVoiceRow(voice: item, selected: callPicked == item) { choices.setCallVoice(item, for: owner) }
                }
            } header: {
                Text(readsWithVolcengine ? "通话和朗读" : "通话")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    switch owner {
                    case .bot: Text("和这个 Bot 通话时用这里选的声音。跟随默认时，用「设置 → 语音通话」里选的声音。")
                    case .session: Text("在这个会话里通话时用这里选的声音。跟随默认时，用「设置 → 语音通话」里选的声音。")
                    }
                    if readsWithVolcengine {
                        switch owner {
                        case .bot: Text("朗读用的是火山引擎，这个 Bot 的回复和它在群聊里的发言也用这里的声音朗读。")
                        case .session: Text("朗读用的是火山引擎，这个会话的回复也用这里的声音朗读。")
                        }
                    }
                    if speech.configured {
                        Text("AI 发来的语音消息也用这里的声音。")
                        Text("试听按火山引擎的价格计费；通话中改了声音，下一通电话生效。")
                    } else {
                        Text("试听和通话要先在「设置 → 语音通话」里填好火山引擎的 API Key。")
                    }
                }
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("声音")
        .navigationBarTitleDisplayMode(.inline)
        // One voice heard at a time.
        .onChange(of: preview.loading) { _, voice in
            if voice != nil, trying != nil { reading.stop(); trying = nil }
        }
        .onDisappear {
            preview.stop()
            if trying != nil { reading.stop() }
        }
    }
}

/// A reading voice to pick, with a button to hear it first.
private struct ReadingVoiceRow: View {
    let voice: DeepSeekSpeech.Voice
    let selected: Bool
    @Binding var trying: DeepSeekSpeech.Voice?
    let select: () -> Void
    @State private var reading = ReadAloud.shared

    private var playing: Bool { reading.speaking && trying == voice }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.select()
                select()
            } label: {
                HStack(spacing: 12) {
                    Text(voice.title).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                Haptics.tap()
                let stopping = playing
                reading.stop()
                VoicePreview.shared.stop()
                trying = stopping ? nil : voice
                if !stopping { reading.enqueue(String(localized: "你好，我会用这个声音为你朗读。"), voice: .deepseek(voice)) }
            } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 30, height: 30)
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .disabled(CallCenter.shared.active)
            .accessibilityLabel(playing ? Text("停止试听") : Text("试听"))
        }
    }
}

/// 跟随默认, with the default it goes with now.
private struct DefaultVoiceRow: View {
    let current: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            select()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("跟随默认").foregroundStyle(Palette.ink)
                    Text(verbatim: current).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A voice heard before it is picked: a line spoken through the same synthesis a call uses.
@MainActor
@Observable
final class VoicePreview {
    static let shared = VoicePreview()

    /// Where the voice will be heard, which the sample line says.
    enum Purpose { case call, reading }

    /// The voice being heard, and the one whose sound has not come yet.
    private(set) var playing: String?
    private(set) var loading: String?

    @ObservationIgnored private var synthesizer: CallSynthesizer?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var made = false
    @ObservationIgnored private var carry: UInt8?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private init() {}

    func play(_ voice: CallVoice, for purpose: Purpose = .call) {
        stop()
        guard let credential = VolcSpeech.shared.credential else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
        } catch {
            stop()
            return
        }
        playing = voice.id
        loading = voice.id
        made = false
        let synthesizer = CallSynthesizer(credential: credential, voice: voice.id)
        synthesizer.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        self.synthesizer = synthesizer
        let reply = synthesizer.begin()
        let line = switch (purpose, voice.english) {
        case (.call, true): "Hi, this is how I'll sound on your calls. Just talk to me, and pause when you're done."
        case (.call, false): String(localized: "你好，通话时我会用这个声音回答你。想说什么直接说，说完停一下就好。")
        case (.reading, true): "Hi, this is how I'll sound reading replies to you."
        case (.reading, false): String(localized: "你好，我会用这个声音为你朗读。")
        }
        synthesizer.say(line, reply: reply)
        synthesizer.end(reply: reply)
    }

    func stop() {
        synthesizer?.close()
        synthesizer = nil
        player?.stop()
        engine?.stop()
        if engine != nil, !CallCenter.shared.active {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        engine = nil
        player = nil
        pending = 0
        carry = nil
        playing = nil
        loading = nil
    }

    private func handle(_ event: CallSynthesizer.Event) {
        guard playing != nil else { return }
        switch event {
        case .audio(_, let pcm):
            loading = nil
            schedule(pcm)
        case .finished:
            made = true
            if pending == 0 { stop() }
        case .failed:
            stop()
        default:
            break
        }
    }

    private func schedule(_ pcm: Data) {
        guard let player else { return }
        var bytes = [UInt8](pcm)
        if let carry { bytes.insert(carry, at: 0) }
        carry = bytes.count % 2 == 1 ? bytes.removeLast() : nil
        let frames = bytes.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frames {
            let value = Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
            samples[index] = Float(value) / 32_768
        }
        pending += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.pending -= 1
                if self.made && self.pending == 0 { self.stop() }
            }
        }
    }
}
