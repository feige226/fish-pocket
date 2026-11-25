import AppIntents
import SwiftUI

/// 我的应用 as the widgets and Shortcuts see them. The apps live in the engine's files, which the
/// widget extension cannot reach, so the app writes this list into the App Group whenever it reads
/// the apps, in the order its own page shows them.
struct MiniAppSummary: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// An emoji.
    let icon: String
    /// `#RRGGBB`.
    let color: String
    /// The app's own icon, a file in `MiniAppCatalog.icons`; nil when it has only the emoji.
    var image: String?
}

enum MiniAppCatalog {
    static let widgetKind = "DshMiniApps"

    private static var fileURL: URL? {
        guard let groupId = WidgetSnapshotStore.groupId,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return nil }
        return container.appending(path: "mini-apps.json")
    }

    static func read() -> [MiniAppSummary] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MiniAppSummary].self, from: data)) ?? []
    }

    /// The icons the apps drew themselves, copied where the widget can read them.
    private static var icons: URL? { fileURL?.deletingLastPathComponent().appending(path: "mini-app-icons", directoryHint: .isDirectory) }

    static func icon(_ app: MiniAppSummary) -> UIImage? {
        guard let name = app.image, let folder = icons else { return nil }
        return UIImage(contentsOfFile: folder.appending(path: name).path)
    }

    /// Whether the list changed. `images` is each app's `icon.png`, by id.
    @discardableResult
    static func write(_ apps: [MiniAppSummary], images: [String: URL] = [:]) -> Bool {
        guard apps != read(), let url = fileURL, let data = try? JSONEncoder().encode(apps) else { return false }
        if let icons {
            let files = FileManager.default
            try? files.createDirectory(at: icons, withIntermediateDirectories: true)
            let wanted = Set(apps.compactMap(\.image))
            for name in (try? files.contentsOfDirectory(atPath: icons.path)) ?? [] where !wanted.contains(name) {
                try? files.removeItem(at: icons.appending(path: name))
            }
            for app in apps {
                guard let name = app.image, let source = images[app.id] else { continue }
                let target = icons.appending(path: name)
                if !files.fileExists(atPath: target.path) { try? files.copyItem(at: source, to: target) }
            }
        }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
}

extension Color {
    /// An app's `color`: `#RRGGBB`; anything else is gray.
    init(miniApp hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = Color(red: 0.56, green: 0.56, blue: 0.58)
            return
        }
        self = Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// An app of 我的应用, for Shortcuts and the widget's settings.
struct MiniAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mini App"
    static var defaultQuery = MiniAppQuery()

    let id: String
    let name: String
    let icon: String

    init(_ app: MiniAppSummary) {
        id = app.id
        name = app.name
        icon = app.icon
    }

    var displayRepresentation: DisplayRepresentation {
        // The app's own name, not a phrase to translate.
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "\(icon) \(name)"))
    }
}

struct MiniAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MiniAppEntity] {
        let apps = MiniAppCatalog.read()
        return identifiers.compactMap { id in apps.first { $0.id == id }.map(MiniAppEntity.init) }
    }

    func entities(matching string: String) async throws -> [MiniAppEntity] {
        MiniAppCatalog.read().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(MiniAppEntity.init)
    }

    func suggestedEntities() async throws -> [MiniAppEntity] {
        MiniAppCatalog.read().map(MiniAppEntity.init)
    }
}

/// Opens one app of 我的应用. Added to the home screen from Shortcuts, it goes straight into the
/// app, with no web page on the way (`DshShortcuts` lists one for each app).
struct OpenMiniAppIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 Mini App"
    static var description = IntentDescription("打开一个 Mini App。在快捷指令里把它添加到主屏幕，就是这个 Mini App 的图标。")
    static var openAppWhenRun = true

    @Parameter(title: "Mini App")
    var app: MiniAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("打开\(\.$app)")
    }

    init() {}

    init(app: MiniAppEntity) {
        self.app = app
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        DshIntentBridge.open?(.app(app.id))
        return .result()
    }
}

/// The 我的应用 widget's settings: which apps it shows.
struct MiniAppsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mini Apps"
    static var description = IntentDescription("选择小组件里放哪些 Mini App。")

    @Parameter(title: "Mini Apps", size: [.systemSmall: 1, .systemMedium: 4])
    var apps: [MiniAppEntity]?

    init() {}
}
