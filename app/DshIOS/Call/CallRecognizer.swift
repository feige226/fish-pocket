import Foundation

/// Recognition for a whole call: one Volcengine streaming session (豆包流式语音识别模型 2.0) that
/// hears everything the microphone sends and says, sentence by sentence, what was said. When a
/// sentence ends is Volcengine's call (its own pause detection, `end_window_size`); the app adds no
/// rules of its own. A dropped connection is opened again at once, with the last few seconds of
/// audio sent again, and is only reported while it stays down.
final class CallRecognizer: @unchecked Sendable {
    enum Event: Sendable {
        /// The sentence being said, as heard so far; empty once there is none.
        case partial(String)
        /// A sentence Volcengine heard to its end.
        case sentence(String)
        /// The connection dropped and is being opened again.
        case unstable
        /// Connected (again).
        case steady
        /// Given up: the key was refused, or the connection stayed down.
        case failed(Error)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let credential: VolcCredential
    private let lock = NSLock()
    private var outbox: AsyncStream<Data>.Continuation?
    /// Audio that arrived while no connection was open: the last three seconds.
    private var backlog: [Data] = []
    private var context: [(user: Bool, text: String)] = []
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var stopped = false

    private static let backlogLimit = 15
    private static let attempts = 6

    init(credential: VolcCredential) {
        self.credential = credential
    }

    func start() {
        worker = Task.detached(priority: .userInitiated) { [weak self] in await self?.run() }
    }

    /// 16 kHz mono 16-bit PCM from the microphone, encoded as Ogg Opus on its way out.
    func send(_ pcm: Data) {
        lock.withLock {
            guard !stopped else { return }
            if let outbox {
                outbox.yield(pcm)
            } else {
                backlog.append(pcm)
                if backlog.count > Self.backlogLimit { backlog.removeFirst(backlog.count - Self.backlogLimit) }
            }
        }
    }

    /// The conversation's last turns, oldest first: Volcengine hears better knowing what was said.
    /// Used from the next connection on.
    func setContext(_ turns: [(user: Bool, text: String)]) {
        lock.withLock { context = turns }
    }

    func stop() {
        let (socket, worker) = lock.withLock { () -> (URLSessionWebSocketTask?, Task<Void, Never>?) in
            stopped = true
            outbox?.finish()
            outbox = nil
            backlog = []
            return (self.socket, self.worker)
        }
        worker?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func run() async {
        var failures = 0
        while !isStopped, !Task.isCancelled {
            do {
                try await connection { failures = 0 }
                // The server ended the session (its own limit): open the next one at once.
            } catch {
                if isStopped || Task.isCancelled { return }
                if VolcCredential.fatal(error) {
                    onEvent?(.failed(error))
                    return
                }
                failures += 1
                if failures == 1 { onEvent?(.unstable) }
                if failures > Self.attempts {
                    onEvent?(.failed(error))
                    return
                }
                try? await Task.sleep(for: .milliseconds(min(250 * (1 << (failures - 1)), 4_000)))
            }
        }
    }

    /// One session, until the server ends it or it fails. `connected` runs once it is open.
    private func connection(connected: () -> Void) async throws {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: credential.request(.recognition))
        socket.maximumMessageSize = 4 << 20
        let (packets, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(50))
        let (backlog, turns) = lock.withLock { () -> ([Data], [(user: Bool, text: String)]) in
            self.socket = socket
            outbox = continuation
            defer { self.backlog = [] }
            return (self.backlog, context)
        }
        defer {
            lock.withLock {
                if self.socket === socket {
                    self.socket = nil
                    outbox = nil
                }
            }
            continuation.finish()
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        socket.resume()
        let parameters = Self.parameters(context: turns)
        // The first frame waits for the handshake: once it is out, the connection is up.
        do {
            try await socket.send(.data(VolcFrame.request(sequence: 1, json: parameters)))
        } catch {
            throw credential.refusal(socket.response, .recognition) ?? error
        }
        connected()
        onEvent?(.steady)
        let sender = Task {
            var sequence: Int32 = 1
            // Each connection is a stream of its own, header pages first: a new encoder each time.
            let encoder = OggOpusEncoder()
            do {
                for chunk in backlog {
                    sequence += 1
                    try await socket.send(.data(VolcFrame.audio(sequence: sequence, encoded: encoder.encode(chunk), last: false)))
                }
                for await chunk in packets {
                    sequence += 1
                    try await socket.send(.data(VolcFrame.audio(sequence: sequence, encoded: encoder.encode(chunk), last: false)))
                }
                // Hung up: the last packet closes the session.
                sequence += 1
                try await socket.send(.data(VolcFrame.audio(sequence: sequence, encoded: encoder.finish(), last: true)))
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
        defer { sender.cancel() }

        var finished = Set<Int>()
        var partial = ""
        do {
            while true {
                let message = try await socket.receive()
                guard case .data(let data) = message, let frame = VolcFrame.parse(data) else { continue }
                if let code = frame.errorCode {
                    switch code {
                    case 45_000_292: throw VoiceError.noQuota
                    case 55_000_031: throw VoiceError.busy
                    default: throw VoiceError.server(code: code, message: frame.message ?? "")
                    }
                }
                for utterance in frame.utterances where utterance.definite && !finished.contains(utterance.start) {
                    finished.insert(utterance.start)
                    let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { onEvent?(.sentence(text)) }
                }
                let heard = frame.utterances.last { !$0.definite && !finished.contains($0.start) }?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if heard != partial {
                    partial = heard
                    onEvent?(.partial(heard))
                }
                if frame.last { return }
            }
        } catch {
            if partial != "" { onEvent?(.partial("")) }
            throw credential.refusal(socket.response, .recognition) ?? VolcCredential.closure(socket.closeCode) ?? error
        }
    }

    /// A conversation: punctuation, numbers as numbers, filler words dropped, each sentence
    /// recognized a second time once it ends, and each sentence in its own result.
    private static func parameters(context turns: [(user: Bool, text: String)]) -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "enable_nonstream": true,
            "show_utterances": true,
            "result_type": "single",
        ]
        if !turns.isEmpty {
            let dialog: [String: Any] = [
                "context_type": "dialog_ctx",
                "context_data": turns.map { ["speaker": $0.user ? "user" : "bot", "text": $0.text] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dialog), let text = String(data: data, encoding: .utf8) {
                request["corpus"] = ["context": text]
            }
        }
        let json: [String: Any] = [
            "audio": VolcFrame.audioFormat,
            "request": request,
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}
