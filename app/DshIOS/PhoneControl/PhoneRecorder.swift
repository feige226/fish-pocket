import Perception
import AVFoundation
import SwiftUI

/// Records the screen while the agent operates other apps through iCTRL, so the user can
/// watch afterwards exactly what it did. The recording is the phone's screen as it was:
/// no cuts, captions or edits; only sharing adds our frame (`PhoneRecordingExport`).
///
/// - Starts when a turn's tool call goes through iCTRL's client (`ictrl_rpc`), stops when
///   the turn ends, when the app has been back in front for a few seconds, or at a cap.
/// - The picture is iCTRL's own live stream (fragmented MP4, no sound: XCUITest only
///   captures the screen). The app borrows the key the agent's client stored, so it asks
///   for nothing the user has not already allowed.
/// - Files stay on this phone, keyed by session and turn; the conversation shows them under
///   that turn.
@MainActor @Perceptible
final class PhoneRecorder {
    static let shared = PhoneRecorder()
    static let enabledKey = "phoneControlRecording"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    struct Recording: Codable, Identifiable, Hashable {
        let id: String
        let session: String
        let turn: Int
        let startedAt: Date
        var duration: Double
        /// The user's message that started the turn, shown (if they want) when sharing.
        let request: String?
        let file: String
    }

    private(set) var recordings: [Recording] = []
    /// The turn being recorded now.
    private(set) var current: (session: String, turn: Int)?

    private var stream: StreamFile?
    private var startedAt = Date()
    private var request: String?
    private var stopTask: Task<Void, Never>?
    private var leftApp = false

    /// Long enough for any task the agent should be doing on screen.
    private static let cap: Duration = .seconds(20 * 60)
    private static let directory = EnginePaths.data.appendingPathComponent("phone-recordings", isDirectory: true)
    private static let indexFile = directory.appendingPathComponent("index.json")

    private init() {
        if let data = try? Data(contentsOf: Self.indexFile),
           let saved = try? JSONDecoder().decode([Recording].self, from: data) {
            recordings = saved.filter { FileManager.default.fileExists(atPath: Self.url(of: $0).path) }
        }
    }

    static func url(of recording: Recording) -> URL { directory.appendingPathComponent(recording.file) }

    func recordings(session: String, turn: Int) -> [Recording] {
        recordings.filter { $0.session == session && $0.turn == turn }
    }

    // MARK: - when

    /// Every live event of a session.
    func observe(_ event: JSON, session: String, request: @autoclosure () -> String?) {
        switch event["type"].string {
        case "assistant/message":
            guard current == nil, Self.enabled, let turn = event["data"]["turn"].int else { return }
            let usesICTRL = event["data"]["message"]["content"].array.contains { part in
                guard part["type"].string == "tool-call" else { return false }
                let args = part["arguments"].string
                    ?? (try? JSONEncoder().encode(part["arguments"])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return args.contains("ictrl_rpc")
            }
            if usesICTRL { start(session: session, turn: turn, request: request()) }
        case "turn/end":
            if let current, current.session == session { stop() }
        default:
            break
        }
    }

    /// The agent sends the user back here when it is done; the app in front for a few
    /// seconds means the part worth watching is over, even if the turn goes on.
    func scenePhaseChanged(to phase: ScenePhase) {
        guard current != nil else { return }
        switch phase {
        case .background:
            leftApp = true
            stopTask?.cancel()
            stopTask = nil
        case .active where leftApp:
            stopTask?.cancel()
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        default:
            break
        }
    }

    // MARK: - recording

    private func start(session: String, turn: Int, request: String?) {
        current = (session, turn)
        startedAt = Date()
        self.request = request?.trimmingCharacters(in: .whitespacesAndNewlines)
        leftApp = UIApplication.shared.applicationState == .background
        Task {
            do {
                let url = try await ICTRLClient.streamURL(fps: 15)
                guard current?.session == session, current?.turn == turn else { return }
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let file = Self.directory.appendingPathComponent("\(UUID().uuidString).part.mp4")
                stream = try StreamFile(url: url, to: file)
                startedAt = Date()
                stopTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.cap)
                    guard !Task.isCancelled else { return }
                    self?.stop()
                }
            } catch {
                // No service or no key yet: the agent will say so itself; nothing to record.
                if current?.session == session, current?.turn == turn { current = nil }
            }
        }
    }

    private func stop() {
        guard let current else { return }
        self.current = nil
        stopTask?.cancel()
        stopTask = nil
        guard let stream else { return }
        self.stream = nil
        let partial = stream.finish()
        let started = startedAt
        let request = request
        Task {
            guard let saved = await Self.finalize(partial) else { return }
            let recording = Recording(id: UUID().uuidString, session: current.session, turn: current.turn,
                                      startedAt: started, duration: saved.duration, request: request,
                                      file: saved.file.lastPathComponent)
            recordings.append(recording)
            save()
        }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: Self.url(of: recording))
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: Self.indexFile, options: .atomic)
    }

    /// A stream cut off mid-fragment is not a file players accept everywhere: drop the
    /// incomplete tail, then rewrite it as a plain MP4 so it has a duration to seek in.
    nonisolated private static func finalize(_ partial: URL) async -> (file: URL, duration: Double)? {
        defer { try? FileManager.default.removeItem(at: partial) }
        guard trimToCompleteBoxes(partial) else { return nil }
        let asset = AVURLAsset(url: partial)
        let target = partial.deletingLastPathComponent().appendingPathComponent(
            partial.lastPathComponent.replacingOccurrences(of: ".part.mp4", with: ".mp4"))
        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            do {
                try await export.export(to: target, as: .mp4)
            } catch {
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: partial, to: target)
            }
        }
        guard let duration = try? await AVURLAsset(url: target).load(.duration).seconds, duration >= 1 else {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        return (target, duration)
    }

    /// Cuts the file after its last complete top-level box. False when nothing usable is left.
    nonisolated private static func trimToCompleteBoxes(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        var offset: UInt64 = 0
        var fragments = 0
        while offset + 8 <= length {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            if size == 1, header.count == 16 { size = header.dropFirst(8).reduce(0) { $0 << 8 | UInt64($1) } }
            guard size >= 8, offset + size <= length else { break }
            if header[4..<8].elementsEqual("mdat".utf8) { fragments += 1 }
            offset += size
        }
        try? handle.truncate(atOffset: offset)
        return fragments > 0
    }
}

/// Writes one live HTTP response to a file as it arrives.
private final class StreamFile: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let file: URL
    private var session: URLSession!
    private let lock = NSLock()

    init(url: URL, to file: URL) throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
        self.file = file
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 60 * 60
        config.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session.dataTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { try? handle.write(contentsOf: data) }
    }

    /// Stops reading and returns the file as far as it got.
    func finish() -> URL {
        session.invalidateAndCancel()
        lock.withLock { try? handle.close() }
        return file
    }
}
