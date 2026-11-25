import Foundation

/// Speech for a call: Volcengine's bidirectional streaming synthesis (豆包语音合成模型 2.0). The
/// reply goes in as the model writes it, a few characters at a time, and Volcengine cuts it into
/// sentences and sends the sound back as it is made, so she starts talking before the model has
/// finished. One connection for the whole call; each reply is a session on it. Every reply of a
/// call shares one `section_id`, so Volcengine keeps the tone of the conversation from one to the
/// next, and Markdown is read as the words it marks up. The sound comes as Ogg Opus, a fifth of
/// the bytes of PCM, and is decoded here: `.audio` is 24 kHz mono 16-bit PCM.
final class CallSynthesizer: @unchecked Sendable {
    enum Event: Sendable {
        /// Volcengine starts a sentence of `reply`: the sound until its end belongs to it.
        case sentenceStart(reply: Int)
        case audio(reply: Int, Data)
        /// The sentence's text, once it has been made.
        case sentenceEnd(reply: Int, String)
        /// All of `reply` has been made.
        case finished(reply: Int)
        case failed(reply: Int?, Error)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let credential: VolcCredential
    private let voice: String
    private let section: String
    private let lock = NSLock()
    private let commands: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    private var nextReply = 0
    /// Replies cancelled: their sound, still on its way, is dropped.
    private var cancelled = Set<Int>()

    private enum Command {
        case connect, begin(Int), text(Int, String), end(Int), cancel(Int)
    }

    init(credential: VolcCredential, voice: String, section: String = UUID().uuidString.lowercased()) {
        self.credential = credential
        self.voice = voice
        self.section = section
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            for await command in stream {
                guard let self, !Task.isCancelled else { return }
                await self.handle(command)
            }
        }
    }

    deinit { close() }

    /// Whether synthesis 2.0 works with `credential`: one word, until its first sound comes back.
    static func check(_ credential: VolcCredential) async throws {
        let synthesizer = CallSynthesizer(credential: credential, voice: CallVoice.all[0].id)
        defer { synthesizer.close() }
        let once = FirstOnce()
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                if once.first() { waiter.resume(with: result) }
            }
            synthesizer.onEvent = { event in
                switch event {
                case .audio: finish(.success(()))
                case .failed(_, let error): finish(.failure(error))
                default: break
                }
            }
            let reply = synthesizer.begin()
            synthesizer.say("你好", reply: reply)
            synthesizer.end(reply: reply)
            Task {
                try? await Task.sleep(for: .seconds(12))
                finish(.failure(CallError.noAnswer))
            }
        }
    }

    /// Open the connection ahead of the first reply.
    func warmUp() { commands.yield(.connect) }

    /// A new reply; whatever reply was open is cancelled.
    func begin() -> Int {
        let reply = lock.withLock { () -> Int in
            nextReply += 1
            return nextReply
        }
        commands.yield(.begin(reply))
        return reply
    }

    func say(_ text: String, reply: Int) {
        guard !text.isEmpty else { return }
        commands.yield(.text(reply, text))
    }

    /// No more text for `reply`: the rest of it is made, then `.finished`.
    func end(reply: Int) { commands.yield(.end(reply)) }

    /// Stop `reply` at once: nothing more of it is made or reported.
    func cancel(reply: Int) {
        lock.withLock { _ = cancelled.insert(reply) }
        commands.yield(.cancel(reply))
    }

    func close() {
        commands.finish()
        worker?.cancel()
        let socket = lock.withLock { self.socket }
        socket?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    // MARK: Worker (one command at a time, in order)

    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiver: Task<Void, Never>?
    /// The reply on the connection and its session id.
    private var current: (reply: Int, session: String)?
    private var sessions: [String: Int] = [:]
    /// Each session's sound is an Ogg stream of its own.
    private var decoders: [String: OggOpusDecoder] = [:]
    private var waiters: [String: CheckedContinuation<Data, Error>] = [:]
    /// Events that came before anyone waited for them (a fast answer, a session nobody waits on).
    private var arrived: [String: Result<Data, Error>] = [:]

    private func handle(_ command: Command) async {
        do {
            switch command {
            case .connect:
                try await connect()
            case .begin(let reply):
                try await connect()
                if let open = lock.withLock({ current }) { try await close(open) }
                guard !isCancelled(reply) else { return }
                let session = UUID().uuidString.lowercased()
                lock.withLock {
                    current = (reply, session)
                    sessions[session] = reply
                }
                try await send(event: 100, session: session, payload: startPayload())
                _ = try await wait(for: "\(150):\(session)", seconds: 8)
            case .text(let reply, let text):
                guard let open = lock.withLock({ current }), open.reply == reply, !isCancelled(reply) else { return }
                try await send(event: 200, session: open.session, payload: ["event": 200, "namespace": "BidirectionalTTS", "req_params": ["text": text]])
            case .end(let reply):
                guard let open = lock.withLock({ current }), open.reply == reply, !isCancelled(reply) else { return }
                try await send(event: 102, session: open.session, payload: [:])
            case .cancel(let reply):
                guard let open = lock.withLock({ current }), open.reply == reply else { return }
                try await send(event: 101, session: open.session, payload: [:])
            }
        } catch {
            let reply: Int? = switch command {
            case .begin(let r), .text(let r, _), .end(let r), .cancel(let r): r
            case .connect: nil
            }
            if let reply, isCancelled(reply) { return }
            onEvent?(.failed(reply: reply, error))
            // The connection is opened again for the next reply.
            drop()
        }
    }

    /// Before a new session starts, the last one must be over. A session still making its text
    /// is cancelled; one already given all its text (`FinishSession`) goes on until it has made
    /// it, which can take seconds for a long answer: rather than wait, the connection is dropped
    /// and the new reply opens a fresh one. Nothing of the old reply is wanted any more.
    private func close(_ open: (reply: Int, session: String)) async throws {
        let ended = lock.withLock { sessions[open.session] == nil }
        if !ended {
            if !isCancelled(open.reply) {
                lock.withLock { _ = cancelled.insert(open.reply) }
            }
            try? await send(event: 101, session: open.session, payload: [:])
            _ = try? await wait(for: "end:\(open.session)", seconds: 0.5)
            if lock.withLock({ sessions[open.session] != nil }) {
                drop()
                try await connect()
                return
            }
        }
        lock.withLock { if current?.session == open.session { current = nil } }
    }

    private func startPayload() -> [String: Any] {
        let additions: [String: Any] = ["disable_markdown_filter": true, "section_id": section]
        let encoded = (try? JSONSerialization.data(withJSONObject: additions)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return [
            "event": 100,
            "namespace": "BidirectionalTTS",
            "req_params": [
                "speaker": voice,
                // Opus only comes at 48 kHz; it is decoded to 24 kHz here.
                "audio_params": ["format": "ogg_opus", "sample_rate": 48_000, "bit_rate": 64_000],
                "additions": encoded,
            ],
        ]
    }

    private func isCancelled(_ reply: Int) -> Bool { lock.withLock { cancelled.contains(reply) } }

    // MARK: Connection

    private func connect() async throws {
        if lock.withLock({ socket != nil }) { return }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: credential.request(.synthesis))
        socket.maximumMessageSize = 8 << 20
        lock.withLock {
            self.socket = socket
            urlSession = session
        }
        socket.resume()
        receiver = Task.detached(priority: .userInitiated) { [weak self] in await self?.receive(socket) }
        do {
            try await send(event: 1, session: nil, payload: [:])
            _ = try await wait(for: "50", seconds: 8)
        } catch {
            throw credential.refusal(socket.response, .synthesis) ?? error
        }
    }

    /// The connection failed: everything waiting on it gives up, and the next reply opens a new one.
    private func drop() {
        let (socket, session, waiting) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?, [CheckedContinuation<Data, Error>]) in
            defer {
                self.socket = nil
                urlSession = nil
                current = nil
                sessions = [:]
                decoders = [:]
                waiters = [:]
                arrived = [:]
            }
            return (self.socket, urlSession, Array(waiters.values))
        }
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
    }

    private func send(event: Int32, session: String?, payload: [String: Any]) async throws {
        guard let socket = lock.withLock({ self.socket }) else { throw CancellationError() }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var frame = Data([0x11, 0x14, 0x10, 0x00])
        frame.appendBigEndian(UInt32(bitPattern: event))
        if let session {
            let id = Data(session.utf8)
            frame.appendBigEndian(UInt32(id.count))
            frame.append(id)
        }
        frame.appendBigEndian(UInt32(body.count))
        frame.append(body)
        try await socket.send(.data(frame))
    }

    /// The payload of the event named `key` (`"<event>"` or `"<event>:<session>"`, or `"end:<session>"`
    /// for a session finishing, cancelled or failed).
    private func wait(for key: String, seconds: Double) async throws -> Data {
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let waiter = lock.withLock { waiters.removeValue(forKey: key) }
            waiter?.resume(throwing: VoiceError.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { waiter in
            let early = lock.withLock { () -> Result<Data, Error>? in
                if let result = arrived.removeValue(forKey: key) { return result }
                waiters[key] = waiter
                return nil
            }
            if let early { waiter.resume(with: early) }
        }
    }

    private func resolve(_ key: String, _ payload: Data) { settle(key, .success(payload)) }

    private func fail(_ key: String, _ error: Error) { settle(key, .failure(error)) }

    private func settle(_ key: String, _ result: Result<Data, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            if let waiter = waiters.removeValue(forKey: key) { return waiter }
            if arrived.count > 64 { arrived.removeAll() }
            arrived[key] = result
            return nil
        }
        waiter?.resume(with: result)
    }

    private func receive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                guard lock.withLock({ self.socket === socket }) else { return }
                let reply = lock.withLock { current?.reply }
                let failure = credential.refusal(socket.response, .synthesis) ?? VolcCredential.closure(socket.closeCode) ?? error
                if let reply, !isCancelled(reply) { onEvent?(.failed(reply: reply, failure)) }
                drop()
                return
            }
            guard case .data(let data) = message, let frame = Frame(data) else { continue }
            if let code = frame.errorCode {
                let error = Self.serverError(code, frame.payload)
                // An error frame carries no session: it ends whatever was waiting.
                let waiting = lock.withLock { Array(waiters.keys) }
                waiting.forEach { fail($0, error) }
                let reply = lock.withLock { current?.reply }
                if let reply, !isCancelled(reply) { onEvent?(.failed(reply: reply, error)) }
                continue
            }
            let session = frame.id ?? ""
            let reply = lock.withLock { sessions[session] }
            switch frame.event {
            case 50: resolve("50", frame.payload)
            case 51: fail("50", Self.serverError(0, frame.payload))
            case 150: resolve("150:\(session)", frame.payload)
            case 350:
                if let reply, !isCancelled(reply) { onEvent?(.sentenceStart(reply: reply)) }
            case 351:
                if let reply, !isCancelled(reply) {
                    let text = (try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])?["text"] as? String ?? ""
                    onEvent?(.sentenceEnd(reply: reply, text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            case 352:
                guard let reply, !isCancelled(reply), !frame.payload.isEmpty else { break }
                let decoder = lock.withLock { () -> OggOpusDecoder in
                    if let decoder = decoders[session] { return decoder }
                    let decoder = OggOpusDecoder(outputRate: 24_000)
                    decoders[session] = decoder
                    return decoder
                }
                let pcm = decoder.decode(frame.payload)
                if !pcm.isEmpty { onEvent?(.audio(reply: reply, pcm)) }
            case 151, 152, 153:
                lock.withLock {
                    sessions[session] = nil
                    decoders[session] = nil
                    if current?.session == session { current = nil }
                }
                if frame.event == 153 {
                    let error = Self.serverError(0, frame.payload)
                    fail("150:\(session)", error)
                    if let reply, !isCancelled(reply) { onEvent?(.failed(reply: reply, error)) }
                } else if frame.event == 152, let reply, !isCancelled(reply) {
                    onEvent?(.finished(reply: reply))
                }
                resolve("end:\(session)", frame.payload)
            default:
                break
            }
        }
    }

    private static func serverError(_ code: UInt32, _ payload: Data) -> Error {
        let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let message = json?["message"] as? String ?? json?["error"] as? String ?? String(data: payload, encoding: .utf8) ?? ""
        let status = json?["status_code"] as? Int ?? Int(code)
        // "requested resource not granted" and the like: synthesis 2.0 is not enabled for this key.
        if message.localizedCaseInsensitiveContains("resource") && message.localizedCaseInsensitiveContains("grant") {
            return CallError.synthesisRefused
        }
        return CallError.synthesis(code: status, message: message)
    }

    // MARK: Frames

    /// A server frame: header, then for an event its number and the connection's or session's id,
    /// then the payload. An error frame has its code in place of the event.
    private struct Frame {
        var event: Int32 = 0
        var id: String?
        var errorCode: UInt32?
        var payload = Data()

        init?(_ data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { return nil }
            let type = bytes[1] >> 4
            let flags = bytes[1] & 0x0f
            let compression = bytes[2] & 0x0f
            var index = Int(bytes[0] & 0x0f) * 4
            func word() -> UInt32? {
                guard index + 4 <= bytes.count else { return nil }
                defer { index += 4 }
                return bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
            }
            func chunk() -> Data? {
                guard let size = word(), index + Int(size) <= bytes.count else { return nil }
                defer { index += Int(size) }
                return Data(bytes[index..<index + Int(size)])
            }
            if type == 0b1111 {
                errorCode = word()
            } else if flags & 0b0100 != 0 {
                guard let value = word() else { return nil }
                event = Int32(bitPattern: value)
                if let raw = chunk() { id = String(data: raw, encoding: .utf8) }
            }
            payload = chunk() ?? Data()
            if compression == 0b0001, let inflated = Gzip.decompress(payload) { payload = inflated }
        }
    }
}

/// What goes wrong with a call, as the call screen says it.
enum CallError: LocalizedError {
    case synthesisRefused
    case synthesis(code: Int, message: String)
    case noKey
    case microphone(String)
    case noAnswer

    var errorDescription: String? {
        switch self {
        case .synthesisRefused: String(localized: "火山引擎没有接受这个 Key 的语音合成，请在控制台开通「豆包语音合成模型 2.0」")
        case .synthesis(let code, let message): String(localized: "语音合成出错（\(String(code))）：\(message)")
        case .noKey: String(localized: "语音通话还没设置好，请在设置 → 语音通话里选择连接方式")
        case .microphone(let detail): String(localized: "麦克风打不开：\(detail)")
        case .noAnswer: String(localized: "火山引擎的语音合成没有回应，请稍后再试")
        }
    }
}

/// True the first time it is asked, from any thread.
final class FirstOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
