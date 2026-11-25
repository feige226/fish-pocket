import AVFoundation
import CryptoKit
import Foundation
import Observation

/// 设置 → 语音消息: where the agent may answer with a voice message, and the rule it follows for
/// when one fits. The engine offers its `send_voice_message` tool only where this allows it
/// (`engine/plugins/ios-voice-message`); the app draws each call as a voice bubble.
@MainActor
@Observable
final class VoiceMessageSettings {
    static let shared = VoiceMessageSettings()

    private static let sessionsKey = "voiceMessage.sessions"
    private static let botsKey = "voiceMessage.bots"
    private static let guidanceKey = "voiceMessage.guidance"

    /// Ordinary sessions: off until the user turns it on (work happens there).
    var allowSessions: Bool = UserDefaults.standard.object(forKey: VoiceMessageSettings.sessionsKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(allowSessions, forKey: Self.sessionsKey); VoiceMessageSync.shared.sync() }
    }
    /// Bot chats: on until the user turns it off.
    var allowBots: Bool = UserDefaults.standard.object(forKey: VoiceMessageSettings.botsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowBots, forKey: Self.botsKey); VoiceMessageSync.shared.sync() }
    }
    /// The user's own rule; nil: the default, which follows the app's language and later versions.
    private(set) var customGuidance: String? = UserDefaults.standard.string(forKey: VoiceMessageSettings.guidanceKey)

    var guidance: String { customGuidance ?? Self.defaultGuidance }

    static var defaultGuidance: String {
        String(localized: "只在闲聊时偶尔发，比如打招呼、聊天、安慰、开玩笑，觉得说出来比打字更合适的时候。干活时不发：做任务、写代码、查资料、给步骤或数据，以及我可能想回头再看的内容，都用文字。我让你发语音时就发。")
    }

    /// Saves `text` as the rule; the default's own words (or nothing) go back to the default.
    func setGuidance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom: String? = trimmed.isEmpty || trimmed == Self.defaultGuidance ? nil : trimmed
        guard custom != customGuidance else { return }
        customGuidance = custom
        UserDefaults.standard.set(custom, forKey: Self.guidanceKey)
        VoiceMessageSync.shared.sync()
    }

    var summary: String {
        switch (allowSessions, allowBots) {
        case (true, true): String(localized: "会话和 Bot")
        case (false, true): String(localized: "仅 Bot")
        case (true, false): String(localized: "仅会话")
        case (false, false): String(localized: "关")
        }
    }
}

/// Tells the engine what `VoiceMessageSettings` allows, which sessions are Bot chats and which
/// belong to groups, and whether there is a speech service to read a voice message with. Sent
/// when the app connects and again whenever any of it changes.
@MainActor
final class VoiceMessageSync {
    static let shared = VoiceMessageSync()

    private weak var app: AppModel?
    private var task: Task<Void, Never>?
    private var sent: [String: JSON]?

    func attach(_ app: AppModel) {
        self.app = app
        sync()
    }

    func sync() {
        guard let app else { return }
        task?.cancel()
        task = Task {
            // A burst of changes (the Bot list loading, typing a rule) is sent once.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let payload = await payload(app)
            guard !Task.isCancelled, payload != sent else { return }
            var request = app.client.request(app.client.origin.appendingPathComponent("api/ios-voice-message/settings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONEncoder().encode(JSON.object(payload))
            request.timeoutInterval = 10
            guard let (_, response) = try? await app.client.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            sent = payload
        }
    }

    private func payload(_ app: AppModel) async -> [String: JSON] {
        let settings = VoiceMessageSettings.shared
        let team = app.botTeam
        var bots = Set<String>()
        var groups = Set<String>()
        for bot in team.bots { bots.insert(bot.sessionId); bots.formUnion(bot.parts) }
        for room in team.rooms { groups.insert(room.sessionId); groups.formUnion(room.sessions) }
        bots.remove("")
        groups.remove("")
        let ready = await SynthesisVoice.available()
        return [
            "allowSessions": .bool(settings.allowSessions),
            "allowBots": .bool(settings.allowBots),
            "ready": .bool(ready),
            "guidance": .string(settings.guidance),
            "bots": .array(bots.sorted().map(JSON.string)),
            "groups": .array(groups.sorted().map(JSON.string)),
        ]
    }
}

/// A service and a voice to speak in: for voice messages and for reading aloud. Only that one:
/// when it fails, the speech fails, rather than another service reading it in a voice that does
/// not match the rest.
enum SynthesisVoice: Equatable {
    case volcengine(VolcCredential?, voice: String)
    case deepseek(DeepSeekSpeech.Voice)

    /// What replies are read in: the service picked in 设置 → 朗读 (never switched on the user's
    /// behalf), in the voice picked for `owner` (`VoiceChoices`), else the default. Volcengine
    /// speaks in the call's voice, so a Bot sounds the same in a call, a voice message and when
    /// read aloud. Its credential is nil until the way to reach it is set up.
    @MainActor
    static func reading(for owner: VoiceOwner?) -> SynthesisVoice {
        switch VoicePreferences.shared.readingSource {
        case .volcengine: .volcengine(VolcSpeech.shared.credential, voice: VoiceChoices.shared.callVoice(for: owner).id)
        case .deepseek: .deepseek(VoiceChoices.shared.readingVoice(for: owner))
        }
    }

    /// What a voice message is read in: Volcengine in the call's voice when it is set up (the
    /// user's own key or the Fish Pocket account, whichever they picked), else DeepSeek in the
    /// reading voice, each the one picked for the Bot or the conversation it was sent in, else
    /// the default.
    @MainActor
    static func chosen(for owner: VoiceOwner? = nil) async -> SynthesisVoice? {
        if let credential = VolcSpeech.shared.credential { return .volcengine(credential, voice: VoiceChoices.shared.callVoice(for: owner).id) }
        if await DeepSeekSpeech.ready() { return .deepseek(VoiceChoices.shared.readingVoice(for: owner)) }
        return nil
    }

    @MainActor
    static func available() async -> Bool { await chosen() != nil }

    /// Names the voice in the cache key, so a new voice reads old messages anew.
    var tag: String {
        switch self {
        case .volcengine(_, let voice): "volc:\(voice)"
        case .deepseek(let voice): "deepseek:\(voice.rawValue)"
        }
    }

    /// `text` as 24 kHz 16-bit mono PCM, in pieces as it is made. Cancelling the consumer stops it.
    func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        switch self {
        case .deepseek(let voice):
            return DeepSeekSpeech.synthesize(text, voice: voice)
        case .volcengine(let credential, let voice):
            return AsyncThrowingStream { continuation in
                guard let credential else {
                    continuation.finish(throwing: CallError.noKey)
                    return
                }
                let synthesizer = CallSynthesizer(credential: credential, voice: voice)
                let heard = FirstOnce()
                synthesizer.onEvent = { event in
                    switch event {
                    case .audio(_, let data): _ = heard.first(); continuation.yield(data)
                    case .finished: continuation.finish()
                    case .failed(_, let error): continuation.finish(throwing: error)
                    default: break
                    }
                }
                let reply = synthesizer.begin()
                // A long reply read aloud goes in a sentence or so at a time, as a call's does.
                for piece in ReadAloud.pieces(of: text, limit: 400) { synthesizer.say(piece + "\n", reply: reply) }
                synthesizer.end(reply: reply)
                // No sound at all: the key or the service is not answering.
                let watchdog = Task {
                    try? await Task.sleep(for: .seconds(15))
                    if heard.first() { continuation.finish(throwing: CallError.noAnswer) }
                }
                continuation.onTermination = { _ in
                    watchdog.cancel()
                    synthesizer.close()
                }
            }
        }
    }
}

/// Plays voice messages, one at a time. The first tap makes the speech and plays it as it comes
/// in, then keeps it as a WAV file in the caches, so playing it again starts at once; the system
/// may clear them, and they are made again then.
@MainActor
@Observable
final class VoiceMessagePlayer {
    static let shared = VoiceMessagePlayer()

    /// The message being made or played (its tool call's id).
    private(set) var current: String?
    private(set) var loading = false
    /// Seconds of each message made so far, by its tool call's id.
    private(set) var durations: [String: Int] = [:]
    /// Messages the user has played at least once (their tool call ids); the rest show a dot.
    private(set) var played: Set<String> = VoiceMessagePlayer.loadPlayed()
    /// A failure worded for a toast; the app model shows it.
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    /// Plays a message while it is still being made.
    @ObservationIgnored private var streamer: PCMPlayer?
    @ObservationIgnored private let ending = Ending()

    private static let sampleRate = 24_000

    /// Elapsed share of the playing message, 0…1, updated while it plays.
    private(set) var fraction: Double = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func progress(of id: String) -> Double { current == id ? fraction : 0 }

    /// Plays `text` in `owner`'s voice, or stops it when it is the one playing.
    func toggle(id: String, text: String, owner: VoiceOwner?) {
        if current == id { stop(); return }
        stop()
        if CallCenter.shared.active {
            onError?(String(localized: "通话中不能播放语音消息"))
            return
        }
        ReadAloud.shared.stop()
        current = id
        loading = true
        task = Task { await play(id: id, text: text, owner: owner) }
    }

    func stop() {
        task?.cancel()
        task = nil
        ticker?.cancel()
        ticker = nil
        fraction = 0
        player?.stop()
        player = nil
        streamer?.stop()
        streamer = nil
        loading = false
        if current != nil {
            current = nil
            Self.sessionQueue.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// Seconds a message lasts: exact once it was made, else guessed from its words.
    func seconds(id: String, text: String, owner: VoiceOwner?) -> Int {
        if let known = durations[id] { return known }
        if let url = cached(text, owner: owner), let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            return max(1, Int((Double(size - 44) / Double(Self.sampleRate * 2)).rounded()))
        }
        return Self.estimate(text)
    }

    /// About 4.5 Chinese characters or 2.6 other words a second.
    static func estimate(_ text: String) -> Int {
        var cjk = 0
        for scalar in text.unicodeScalars where scalar.value >= 0x2E80 && scalar.value <= 0x9FFF { cjk += 1 }
        let words = text.unicodeScalars.filter { $0.value < 0x2E80 }.map(Character.init).split { $0.isWhitespace || $0.isPunctuation }.count
        return max(1, Int((Double(cjk) / 4.5 + Double(words) / 2.6).rounded()))
    }

    private func play(id: String, text: String, owner: VoiceOwner?) async {
        do {
            try await Self.activateSession()
            try Task.checkCancellation()
            if let url = cached(text, owner: owner) {
                try playFile(id: id, url: url)
            } else {
                try await stream(id: id, text: text, owner: owner)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, current == id else { return }
            stop()
            onError?(String(localized: "语音消息播放失败：\(error.localizedDescription)"))
        }
    }

    /// A message made before: from its file, at once.
    private func playFile(id: String, url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = ending
        ending.onEnd = { [weak self] in Task { @MainActor in if self?.player === player { self?.stop() } } }
        durations[id] = max(1, Int(player.duration.rounded()))
        self.player = player
        loading = false
        player.play()
        markPlayed(id)
        follow { player.duration > 0 ? player.currentTime / player.duration : 0 }
    }

    /// A message heard for the first time: played as the speech comes in, then kept.
    private func stream(id: String, text: String, owner: VoiceOwner?) async throws {
        guard let voice = await SynthesisVoice.chosen(for: owner) else { throw VoiceMessageError.noVoice }
        let streamer = try PCMPlayer()
        streamer.onHalt = { [weak self] in if self?.streamer === streamer { self?.stop() } }
        self.streamer = streamer
        var pcm = Data()
        var finished = false
        let estimate = Double(Self.estimate(text))
        for try await piece in voice.stream(text) {
            try Task.checkCancellation()
            streamer.schedule(piece)
            if pcm.isEmpty {
                loading = false
                markPlayed(id)
                // Until the whole length is known, the guess stands in (never less than what has come).
                follow {
                    let total = finished ? Double(pcm.count) / Double(Self.sampleRate * 2) : max(estimate, Double(pcm.count) / Double(Self.sampleRate * 2))
                    return total > 0 ? streamer.playedSeconds / total : 0
                }
            }
            pcm.append(piece)
        }
        guard !pcm.isEmpty else { throw VoiceMessageError.empty }
        finished = true
        durations[id] = max(1, Int((Double(pcm.count) / Double(Self.sampleRate * 2)).rounded()))
        let url = Self.folder.appendingPathComponent("\(Self.digest(text, tag: voice.tag)).wav")
        let wave = DeepSeekSpeech.wave(pcm: pcm, sampleRate: Self.sampleRate)
        Self.sessionQueue.async { try? wave.write(to: url, options: .atomic) }
        await streamer.drained()
        if self.streamer === streamer { stop() }
    }

    /// Updates `fraction` from `elapsed` every tenth of a second until the message stops.
    private func follow(_ elapsed: @escaping () -> Double) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.current != nil else { return }
                self.fraction = min(1, max(0, elapsed()))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Played

    private static let playedFile: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("voice-messages-played.json")
    }()

    private static func loadPlayed() -> Set<String> {
        guard let data = try? Data(contentsOf: playedFile),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Kept in a file of its own: writing UserDefaults would redraw every view that reads it.
    private func markPlayed(_ id: String) {
        guard !played.contains(id) else { return }
        played.insert(id)
        let ids = played.sorted()
        let file = Self.playedFile
        Self.sessionQueue.async {
            try? JSONEncoder().encode(ids).write(to: file, options: .atomic)
        }
    }

    // MARK: Files

    private static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("voice-messages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A file already made for `text` in the voice set up now.
    private func cached(_ text: String, owner: VoiceOwner?) -> URL? {
        let url = Self.folder.appendingPathComponent("\(Self.digest(text, tag: Self.currentTag(owner))).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func digest(_ text: String, tag: String) -> String {
        String(SHA256.hash(data: Data("\(tag)\n\(text)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// The tag of the voice `SynthesisVoice.chosen` picks, without asking DeepSeek.
    private static func currentTag(_ owner: VoiceOwner?) -> String {
        if VolcSpeech.shared.configured { return SynthesisVoice.volcengine(nil, voice: VoiceChoices.shared.callVoice(for: owner).id).tag }
        return SynthesisVoice.deepseek(VoiceChoices.shared.readingVoice(for: owner)).tag
    }

    // MARK: Audio session

    private static let sessionQueue = DispatchQueue(label: "voice-message.session")

    private static func activateSession() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    try session.setActive(true)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private final class Ending: NSObject, AVAudioPlayerDelegate {
        var onEnd: (() -> Void)?
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onEnd?() }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onEnd?() }
    }
}

enum VoiceMessageError: LocalizedError {
    case noVoice
    case empty

    var errorDescription: String? {
        switch self {
        case .noVoice: String(localized: "还没有可用的语音合成，到「设置 → 语音消息」看看怎么设置")
        case .empty: String(localized: "没有合成出声音")
        }
    }
}
