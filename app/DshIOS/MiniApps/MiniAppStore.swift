import CryptoKit
import Foundation
import Observation
import WidgetKit
import WebKit

/// One app of 我的应用: a folder the agent wrote under `~/apps` (the engine's path), run full
/// screen in a web view of its own. The mini-apps skill (engine/skills/mini-apps) is what the
/// agent reads; the format is described there.
struct MiniApp: Identifiable, Hashable {
    /// The folder's name, and the app's address: `fishapp://<id>/`.
    let id: String
    let name: String
    let icon: String
    let color: String
    /// `icon.png` in the folder, when the app drew an icon of its own: it stands in for the emoji.
    let iconImage: URL?
    let summary: String?
    let folder: URL

    var catalogEntry: MiniAppSummary {
        // Named by what the file is now, so a redrawn icon reaches the widget.
        let stamp = iconImage.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            .map { "\(id)-\($0[.size] as? Int ?? 0)-\(Int(($0[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)).png" }
        return MiniAppSummary(id: id, name: name, icon: icon, color: color, image: stamp)
    }
    static let iconFile = "icon.png"
    /// Where the agent finds it.
    var enginePath: String { "~/apps/\(id)" }

    static let defaultIcon = "🧩"
    static let defaultColor = "#8E8E93"
    /// A JSX or TypeScript entry exporting the app's component, when there is no `index.html`.
    static let componentEntries = ["App.jsx", "App.tsx", "App.js", "App.ts"]

    /// Lower-case letters, digits and hyphens: it is a host name.
    static func validId(_ id: String) -> Bool {
        guard (1...63).contains(id.count), id.first != "-", id.last != "-" else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The app in `folder`, if it is one: a valid name and something to open.
    static func load(_ folder: URL) -> MiniApp? {
        let id = folder.lastPathComponent
        let files = FileManager.default
        guard validId(id), entry(in: folder) != nil else { return nil }
        let manifest = folder.appending(path: "app.json")
        let json = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        // A string, or one per language (`{"zh-Hans": …, "en": …}`): the app's language, else English.
        func text(_ key: String) -> String? {
            let value: String?
            if let byLanguage = json[key] as? [String: String] {
                let language = Bundle.main.preferredLocalizations.first ?? "en"
                let base = language.split(separator: "-").first.map(String.init) ?? language
                value = byLanguage[language] ?? byLanguage[base] ?? byLanguage["en"] ?? byLanguage.values.first
            } else {
                value = json[key] as? String
            }
            return value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let image = folder.appending(path: iconFile)
        return MiniApp(id: id, name: text("name").map { String($0.prefix(40)) } ?? id, icon: emoji(text("icon")) ?? defaultIcon,
                       color: text("color") ?? defaultColor, iconImage: files.fileExists(atPath: image.path) ? image : nil,
                       summary: text("description"), folder: folder)
    }

    /// `index.html`, else the first of `componentEntries`.
    static func entry(in folder: URL) -> URL? {
        (["index.html"] + componentEntries).lazy.map { folder.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Each app keeps its storage (localStorage, IndexedDB, cookies) in a store of its own,
    /// named by the app: deleting the app deletes it.
    var dataStoreId: UUID { Self.dataStoreId(id) }

    static func dataStoreId(_ id: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("fishapp:\(id)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The first character of `icon`, if it is an emoji.
    private static func emoji(_ icon: String?) -> String? {
        guard let first = icon?.first, let scalar = first.unicodeScalars.first, scalar.properties.isEmoji,
              scalar.properties.isEmojiPresentation || first.unicodeScalars.count > 1 else { return nil }
        return String(first)
    }
}

/// The apps in `~/apps`, newest first by when each was made. Opening or changing one doesn't move
/// it: the grid keeps its order, as a home screen does.
@MainActor @Observable
final class MiniAppStore {
    static let shared = MiniAppStore()

    /// Where the agent writes them.
    nonisolated static let enginePath = "/home/dsh/apps"
    nonisolated static var root: URL { EnginePaths.real(enginePath) }

    private(set) var apps: [MiniApp] = []
    private(set) var loaded = false

    func refresh() {
        MiniAppExamples.install()
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        func made(_ app: MiniApp) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: app.folder.path))?[.creationDate] as? Date ?? .distantPast
        }
        apps = folders.compactMap(MiniApp.load)
            .map { ($0, made($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .map(\.0)
        loaded = true
        // What the agent wrote while no one looked: published now, not when it is opened. Not while an
        // agent works, which may be halfway through an app; its turn's end comes back here.
        if !MiniAppPublisher.agentBusy {
            let apps = apps
            Task.detached(priority: .utility) {
                for app in apps { await MiniAppPublisher.shared.publish(app) }
            }
        }
        let images = Dictionary(uniqueKeysWithValues: apps.compactMap { app in app.iconImage.map { (app.id, $0) } })
        if MiniAppCatalog.write(apps.map(\.catalogEntry), images: images) {
            WidgetCenter.shared.reloadTimelines(ofKind: MiniAppCatalog.widgetKind)
            // Siri's phrases that name a Mini App.
            DshShortcuts.updateAppShortcutParameters()
        }
    }

    func app(_ id: String) -> MiniApp? {
        guard MiniApp.validId(id) else { return nil }
        return MiniApp.load(Self.root.appending(path: id, directoryHint: .isDirectory))
    }

    /// The folder and everything the app stored.
    func delete(_ app: MiniApp) async {
        try? FileManager.default.removeItem(at: app.folder)
        try? await WKWebsiteDataStore.remove(forIdentifier: app.dataStoreId)
        refresh()
    }
}
