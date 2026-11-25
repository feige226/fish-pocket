import AVFoundation
import Foundation
import Observation

/// DeepSeek's speech recognition and synthesis, through the engine's `/api/ios-speech` routes
/// (`engine/plugins/ios-speech`). The engine sends the DeepSeek API key stored for the models, else
/// the DeepSeek account sign-in, so the app itself never holds either. DeepSeek refuses the account
/// sign-in for speech for now; it is still tried, so speech works once DeepSeek accepts it.
enum DeepSeekSpeech {
    /// The running engine; set once, when the app model is made.
    nonisolated(unsafe) static var client: EngineClient?

    /// DeepSeek's two voices.
    enum Voice: String, CaseIterable, Identifiable {
        case stella
        case tide

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stella: String(localized: "女声")
            case .tide: String(localized: "男声")
            }
        }
    }

    /// Whether the engine has a DeepSeek credential to send. Not whether DeepSeek accepts it.
    static func ready() async -> Bool {
        guard let client else { return false }
        let request = client.request(route("status"))
        guard let (data, _) = try? await client.session.data(for: request),
              let reply = try? JSONDecoder().decode(JSON.self, from: data) else { return false }
        return reply["ready"].bool ?? false
    }

    /// What is said in `wav` (16-bit PCM, at most two minutes).
    static func transcribe(wav: Data) async throws -> String {
        guard let client else { throw DeepSeekSpeechError.network(nil) }
        var request = client.request(route("asr"))
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 40
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.session.upload(for: request, from: wav)
        } catch {
            throw Task.isCancelled ? CancellationError() : DeepSeekSpeechError.network(error.localizedDescription)
        }
        let reply = try? JSONDecoder().decode(JSON.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = reply?["text"].string else {
            throw DeepSeekSpeechError(reply: reply, response: response)
        }
        return text
    }

    /// The speech for `text` (at most 10,000 billed characters, a Chinese one counting as two):
    /// 24 kHz mono 16-bit PCM, in pieces as it is made. Cancelling the consuming task stops it.
    static func synthesize(_ text: String, voice: Voice) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client else { throw DeepSeekSpeechError.network(nil) }
                    var request = client.request(route("tts"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONEncoder().encode(["text": .string(text), "voice": .string(voice.rawValue)] as JSON)
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await client.session.bytes(for: request)
                    } catch {
                        throw Task.isCancelled ? CancellationError() : DeepSeekSpeechError.network(error.localizedDescription)
                    }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw DeepSeekSpeechError(reply: try? JSONDecoder().decode(JSON.self, from: body), response: response)
                    }
                    var piece = Data()
                    piece.reserveCapacity(chunkBytes)
                    do {
                        for try await byte in bytes {
                            piece.append(byte)
                            if piece.count >= chunkBytes {
                                continuation.yield(piece)
                                piece.removeAll(keepingCapacity: true)
                            }
                        }
                    } catch {
                        // Cut off midway: DeepSeek reports a failure after the audio began this way.
                        throw Task.isCancelled ? CancellationError() : DeepSeekSpeechError.network(error.localizedDescription)
                    }
                    if !piece.isEmpty { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A fifth of a second of 24 kHz 16-bit audio.
    private static let chunkBytes = 9_600

    private static func route(_ name: String) -> URL {
        client!.origin.appendingPathComponent("api/ios-speech/\(name)")
    }

    /// `pcm` (16-bit mono) as a WAV file.
    static func wave(pcm: Data, sampleRate: Int) -> Data {
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// What can go wrong with DeepSeek speech, as the toast says it.
enum DeepSeekSpeechError: LocalizedError {
    case noCredential
    case rejected
    /// The account sign-in was sent and refused: DeepSeek's speech wants an API key for now.
    case accountRefused
    case noBalance
    case busy
    case tooLong
    case server(status: Int, message: String?)
    case network(String?)

    /// From the engine's `{error: {kind, status, message}}`.
    init(reply: JSON?, response: URLResponse) {
        let error = reply?["error"]
        switch error?["kind"].string {
        case "no-credential": self = .noCredential
        case "http":
            let status = error?["status"].int ?? 0
            switch status {
            case 401, 403: self = error?["credential"].string == "account" ? .accountRefused : .rejected
            case 402: self = .noBalance
            case 413: self = .tooLong
            case 429, 503: self = .busy
            default: self = .server(status: status, message: error?["message"].string)
            }
        case "network": self = .network(error?["message"].string)
        default: self = .server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: nil)
        }
    }

    var errorDescription: String? {
        switch self {
        case .noCredential: String(localized: "需要 DeepSeek API Key：请在「设置 → 模型」里填写，只登录 DeepSeek 账号不能用语音")
        case .rejected: String(localized: "DeepSeek 没有接受当前的 API Key")
        case .accountRefused: String(localized: "DeepSeek 语音暂不支持账号登录，请在「设置 → 模型」里填写 DeepSeek API Key")
        case .noBalance: String(localized: "DeepSeek 账户余额不足")
        case .busy: String(localized: "DeepSeek 语音服务繁忙，请稍后再试")
        case .tooLong: String(localized: "录音太长，DeepSeek 一次最多识别两分钟")
        // The status as digits, without the locale's grouping.
        case .server(let status, let message):
            message.map { String(localized: "DeepSeek 语音服务出错（\(String(status))）：\($0)") }
                ?? String(localized: "DeepSeek 语音服务出错（\(String(status))）")
        case .network(let detail):
            detail.map { String(localized: "连不上 DeepSeek 语音服务：\($0)") } ?? String(localized: "连不上 DeepSeek 语音服务")
        }
    }
}

/// Recognition with DeepSeek for one hold: the microphone records while the finger is down and
/// the whole recording is recognized once it lifts. DeepSeek has no running text.
@MainActor
final class DeepSeekTranscriber: SpeechTranscriber {
    private let mic = MicCapture()
    private let recording = Recording()
    private var upload: Task<String, Error>?

    func start(
        partial: @escaping @MainActor (String) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw VoiceError.microphoneDenied }
        let recording = recording
        mic.onChunk = { recording.append($0) }
        mic.onLevel = { value in Task { @MainActor in level(value) } }
        try await mic.start()
    }

    func finish() async throws -> String {
        recording.append(await mic.stop())
        let wav = DeepSeekSpeech.wave(pcm: recording.data, sampleRate: 16_000)
        let upload = Task { try await DeepSeekSpeech.transcribe(wav: wav) }
        self.upload = upload
        return try await upload.value
    }

    func cancel() {
        upload?.cancel()
        Task { _ = await mic.stop() }
    }

    /// The audio so far, appended from the microphone's queue.
    private final class Recording: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
        var data: Data { lock.withLock { bytes } }
    }
}

/// Which service hold-to-talk uses. Until the user picks one: Volcengine when its key is saved
/// (it shows the text while the user speaks), else DeepSeek with the models' own key.
@MainActor
@Observable
final class VoicePreferences {
    static let shared = VoicePreferences()

    enum Source: String, CaseIterable, Identifiable {
        case deepseek
        case volcengine

        var id: String { rawValue }

        var title: String {
            switch self {
            case .deepseek: "DeepSeek"
            case .volcengine: String(localized: "火山引擎")
            }
        }
    }

    private static let sourceKey = "voiceSource"
    private static let readingSourceKey = "readingSource"
    private static let readingVoiceKey = "readingVoice"
    private var chosen: Source? = UserDefaults.standard.string(forKey: VoicePreferences.sourceKey).flatMap(Source.init(rawValue:))

    /// Which service reads replies aloud, picked by the user: DeepSeek until they pick another,
    /// never switched for them by which key is saved.
    var readingSource: Source = UserDefaults.standard.string(forKey: VoicePreferences.readingSourceKey)
        .flatMap(Source.init(rawValue:)) ?? .deepseek {
        didSet { UserDefaults.standard.set(readingSource.rawValue, forKey: Self.readingSourceKey) }
    }

    /// The DeepSeek voice replies are read in.
    var readingVoice: DeepSeekSpeech.Voice = UserDefaults.standard.string(forKey: VoicePreferences.readingVoiceKey)
        .flatMap(DeepSeekSpeech.Voice.init(rawValue:)) ?? .stella {
        didSet { UserDefaults.standard.set(readingVoice.rawValue, forKey: Self.readingVoiceKey) }
    }

    var source: Source {
        get { chosen ?? (VolcSpeech.shared.configured ? .volcengine : .deepseek) }
        set {
            chosen = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.sourceKey)
        }
    }
}

// MARK: - Reading aloud

/// Replies read aloud, one after another, by the service picked in 设置 → 朗读 (DeepSeek or
/// Volcengine). Reading belongs to the conversation on screen (`scope`): moving to another one
/// stops it.
@MainActor
@Observable
final class ReadAloud {
    static let shared = ReadAloud()

    /// The session on screen. A change stops what is being read.
    var scope: String? {
        didSet {
            if scope != oldValue {
                stop()
                VoiceMessagePlayer.shared.stop()
            }
        }
    }
    private(set) var speaking = false
    /// Held where it was; `resume()` goes on from there.
    private(set) var paused = false
    /// A failure worded for a toast; the app model shows it.
    @ObservationIgnored var onError: ((String) -> Void)?
    /// Whose voice reads a conversation (`scope`): its Bot's, else its own. Set by the app model,
    /// which knows the Bots.
    @ObservationIgnored var ownerFor: ((String?) -> VoiceOwner?)?

    @ObservationIgnored private var queue: [(text: String, voice: SynthesisVoice)] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: PCMPlayer?

    /// `owner`: whose voice reads it (a group member's); nil: the conversation's on screen.
    func toggle(_ text: String, owner: VoiceOwner? = nil) {
        if speaking { stop() } else { enqueue(text, owner: owner) }
    }

    func pause() {
        guard speaking, !paused else { return }
        paused = true
        player?.pause()
    }

    func resume() {
        guard speaking, paused, let player else { return }
        paused = false
        // A call, Siri or a route change may have stopped the engine meanwhile, and the session
        // with it: both start again before the player does.
        Task {
            do {
                try await Self.activateSession()
                guard self.player === player, !paused else { return }
                try player.resume()
            } catch {
                guard self.player === player else { return }
                onError?(error.localizedDescription)
                stop()
            }
        }
    }

    /// The system took the audio away mid-read: it holds where it was, as if paused, for 继续.
    private func halted() {
        guard speaking, !paused else { return }
        paused = true
        player?.pause()
    }

    func stop() {
        paused = false
        queue.removeAll()
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        if speaking {
            speaking = false
            Self.sessionQueue.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// The audio session is switched on and off here, in order, off the main thread: activating
    /// it waits on the system's audio server.
    private static let sessionQueue = DispatchQueue(label: "read-aloud.session")

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

    /// Read after whatever is being read now, in `owner`'s voice, else the conversation's on screen.
    func enqueue(_ text: String, owner: VoiceOwner? = nil) {
        enqueue(text, voice: SynthesisVoice.reading(for: owner ?? ownerFor?(scope)))
    }

    /// Read after whatever is being read now, in `voice` (one being tried).
    func enqueue(_ text: String, voice: SynthesisVoice) {
        let plain = Self.plain(text)
        guard !plain.isEmpty else { return }
        // A call holds the audio: reading aloud would take it over.
        if CallCenter.shared.active {
            onError?(String(localized: "通话中不能朗读"))
            return
        }
        if case .volcengine(nil, _) = voice {
            onError?(String(localized: "朗读还没设置好，请在「设置 → 朗读」里选择火山引擎的接入方式"))
            return
        }
        VoiceMessagePlayer.shared.stop()
        queue.append((plain, voice))
        guard task == nil else { return }
        speaking = true
        task = Task { await run() }
    }

    private func run() async {
        do {
            try await Self.activateSession()
            try Task.checkCancellation()
            let player = try PCMPlayer()
            player.onHalt = { [weak self] in self?.halted() }
            self.player = player
            if paused { player.pause() }
            while true {
                while !queue.isEmpty {
                    let (text, voice) = queue.removeFirst()
                    // Every piece is fetched as fast as it is made and queued on the player, so the
                    // next piece is ready before the last one ends. DeepSeek takes a long reply in
                    // several requests; Volcengine in one session, fed a sentence or so at a time.
                    let parts: [String]
                    if case .deepseek = voice { parts = Self.pieces(of: text) } else { parts = [text] }
                    for piece in parts {
                        for try await pcm in voice.stream(piece) {
                            try Task.checkCancellation()
                            player.schedule(pcm)
                        }
                    }
                }
                await player.drained()
                try Task.checkCancellation()
                if queue.isEmpty { break }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            onError?(error.localizedDescription)
        }
        guard !Task.isCancelled else { return }
        task = nil
        stop()
    }

    /// The reply as it is heard: no code blocks, link targets or Markdown marks.
    static func plain(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[`*_#>|~]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DeepSeek takes at most 10,000 billed characters a request (a Chinese one counts as two):
    /// a long reply goes in pieces, cut between paragraphs, else after a sentence.
    nonisolated static func pieces(of text: String, limit: Int = 6_000) -> [String] {
        func cost<S: StringProtocol>(_ s: S) -> Int { s.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E7F ? 2 : 1) } }
        var pieces: [String] = []
        var current = ""
        var currentCost = 0
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
            currentCost = 0
        }
        func add<S: StringProtocol>(_ part: S) {
            let partCost = cost(part)
            if currentCost + partCost > limit { flush() }
            current += String(part)
            currentCost += partCost
        }
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(paragraph) + "\n"
            if cost(line) <= limit {
                add(line)
                continue
            }
            // One paragraph past the limit: by sentences, and a sentence past it by length.
            var sentence = ""
            for character in line {
                sentence.append(character)
                if "。！？.!?；;\n".contains(character) || cost(sentence) >= limit / 2 {
                    add(sentence)
                    sentence = ""
                }
            }
            if !sentence.isEmpty { add(sentence) }
        }
        flush()
        return pieces
    }
}

/// 24 kHz mono 16-bit PCM played as it arrives.
/// 24 kHz mono speech played as it arrives: read-aloud replies and voice messages heard the first time.
@MainActor
final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    /// Buffers queued and not yet heard.
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// A byte left over from a piece that split a sample.
    private var carry: UInt8?
    private var stopped = false
    /// The system stopped the engine: an interruption (a call, Siri, an alarm) or a route change.
    var onHalt: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() throws {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began { MainActor.assumeIsolated { self?.onHalt?() } }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onHalt?() }
            },
        ]
    }

    func schedule(_ pcm: Data) {
        guard !stopped else { return }
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
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played() }
        }
    }

    func pause() { if !stopped { node.pause() } }

    /// Seconds heard so far.
    var playedSeconds: Double {
        guard !stopped, let now = node.lastRenderTime, let time = node.playerTime(forNodeTime: now) else { return 0 }
        return max(0, Double(time.sampleTime) / time.sampleRate)
    }

    /// Playing on a stopped engine raises (iOS 17), so the engine starts again first.
    func resume() throws {
        guard !stopped else { return }
        if !engine.isRunning { try engine.start() }
        node.play()
    }

    /// Returns once everything queued has been heard, or the player stops.
    func drained() async {
        guard pending > 0, !stopped else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        node.stop()
        engine.stop()
        release()
    }

    private func played() {
        guard !stopped else { return }
        pending -= 1
        if pending == 0 { release() }
    }

    private func release() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}
