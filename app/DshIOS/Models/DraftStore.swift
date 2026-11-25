import UIKit

/// The composer's drafts on disk, one small file per session.
///
/// They are not in `UserDefaults`: SwiftUI's `@AppStorage` follows every change to the
/// defaults, whichever key it is, so a draft written there on each keystroke had every view
/// holding an `@AppStorage` (the root, the main view, the session list, the conversation)
/// work its body out again on each keystroke, and typing in a long conversation dragged.
/// A draft is also written at most twice a second while it changes, off the main thread,
/// and at once as the app leaves the foreground.
@MainActor
final class DraftStore {
    static let shared = DraftStore()

    nonisolated private static let folder = EnginePaths.data.appendingPathComponent("drafts", isDirectory: true)
    /// How long a change may wait to be written.
    private static let delay: Duration = .milliseconds(500)

    /// Not written yet, by session; nil removes the session's draft.
    private var waiting: [String: Data?] = [:]
    private var timer: Task<Void, Never>?
    /// Reads and writes go through here in the order they were asked for.
    private let disk = DispatchQueue(label: "dsh.drafts", qos: .utility)

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func read(_ sessionId: String) -> Data? {
        if let latest = waiting[sessionId] { return latest }
        let file = Self.file(sessionId)
        if let data = disk.sync(execute: { try? Data(contentsOf: file) }) { return data }
        // A draft used to be a string in the defaults: it moves here the first time it is read.
        let key = "dsh.conversation.\(sessionId)"
        guard let old = UserDefaults.standard.string(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        let data = Data(old.utf8)
        write(data, for: sessionId)
        return data
    }

    /// Keep `data` as the session's draft; nil when it has none.
    func write(_ data: Data?, for sessionId: String) {
        waiting.updateValue(data, forKey: sessionId)
        // The write already on its way takes this change along: typing without a pause
        // still reaches the disk, half a second behind.
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        timer?.cancel()
        timer = nil
        guard !waiting.isEmpty else { return }
        let batch = waiting
        waiting = [:]
        disk.async {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            for (sessionId, data) in batch {
                let file = Self.file(sessionId)
                if let data {
                    try? data.write(to: file, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    nonisolated private static func file(_ sessionId: String) -> URL {
        // A session id is letters, digits and hyphens; anything else must not become a path.
        let name = sessionId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? sessionId
        return folder.appendingPathComponent(name + ".json")
    }
}
