import CryptoKit
import Foundation

/// The apps 我的应用 starts with (MiniAppExamples in the bundle, one folder each): copied into
/// `~/apps` once, so they are the user's like any other. One the user deletes stays deleted, and
/// one added in a later version arrives with it.
enum MiniAppExamples {
    private static let offeredKey = "dsh.miniApps.examplesOffered"
    /// The examples actually copied in: an app of the user's own by an example's name was not.
    private static let installedKey = "dsh.miniApps.examplesInstalled"
    @MainActor private static var done = false

    /// The apps Mini Apps marks as examples, so nobody takes them for a catalog of ours. Installs
    /// from before this was recorded fall back to what was offered.
    static var ids: Set<String> {
        let defaults = UserDefaults.standard
        return Set(defaults.stringArray(forKey: installedKey) ?? defaults.stringArray(forKey: offeredKey) ?? [])
    }

    @MainActor
    static func install() {
        guard !done else { return }
        done = true
        guard let source = Bundle.main.url(forResource: "MiniAppExamples", withExtension: nil) else { return }
        let files = FileManager.default
        renew(from: source)
        var offered = Set(UserDefaults.standard.stringArray(forKey: offeredKey) ?? [])
        let ids = ((try? files.contentsOfDirectory(atPath: source.path)) ?? []).filter(MiniApp.validId).sorted()
        guard ids.contains(where: { !offered.contains($0) }) else { return }
        try? files.createDirectory(at: MiniAppStore.root, withIntermediateDirectories: true)
        var installed = self.ids
        for id in ids where !offered.contains(id) {
            let target = MiniAppStore.root.appending(path: id, directoryHint: .isDirectory)
            // An app of the user's own by that name stays as it is.
            if !files.fileExists(atPath: target.path),
               (try? files.copyItem(at: source.appending(path: id, directoryHint: .isDirectory), to: target)) != nil {
                installed.insert(id)
            }
            offered.insert(id)
        }
        UserDefaults.standard.set(offered.sorted(), forKey: offeredKey)
        UserDefaults.standard.set(installed.sorted(), forKey: installedKey)
    }

    /// Goes up when an example in the bundle is redone.
    private static let revision = 1
    private static let revisionKey = "dsh.miniApps.examplesRevision"
    /// The examples as earlier versions shipped them (`fingerprint`). A copy still like one of
    /// these is replaced by the bundle's; one the user had changed is theirs and stays. What the
    /// example stored is kept either way, so a redone example must still read it.
    private static let shipped: [String: Set<String>] = [
        "days": ["3f54f6ad6835d2b6ac046cb67ccd96b968d8dc32d39331529c14a9d5de15f8a1", "481a122d6f5596d6019031eacb23b8c785e61fe7cf7e0c4dc378779f7ecb8af7"],
        "fruit-flip": ["96e31adcc741eb0546eb624a182bb4ef9cd7218b5477514522356754df8a19e1", "8c0e579fdb041662afd774abdd843ea5b2b613e8be2e5234306c53df1570d1fe"],
        // The same sources as now: this one only gained its icon.
        "pomodoro": ["b788c2e2be8b9f37fb46bc8ecfadb80c8f7db44624e00660b6e9883d78cdfc84"],
    ]

    private static func renew(from source: URL) {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: revisionKey) < revision else { return }
        defaults.set(revision, forKey: revisionKey)
        let files = FileManager.default
        for id in ids {
            let target = MiniAppStore.root.appending(path: id, directoryHint: .isDirectory)
            guard let earlier = shipped[id], let now = fingerprint(target), earlier.contains(now) else { continue }
            let fresh = MiniAppStore.root.appending(path: ".\(id)-renewed", directoryHint: .isDirectory)
            try? files.removeItem(at: fresh)
            guard (try? files.copyItem(at: source.appending(path: id, directoryHint: .isDirectory), to: fresh)) != nil else { continue }
            _ = try? files.replaceItemAt(target, withItemAt: fresh)
        }
    }

    /// SHA-256 over the example's three source files, in this order.
    private static func fingerprint(_ folder: URL) -> String? {
        var hash = SHA256()
        for name in ["App.jsx", "style.css", "i18n.js"] {
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
