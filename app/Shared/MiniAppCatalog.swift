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

    /// Whether the list changed.
    @discardableResult
    static func write(_ apps: [MiniAppSummary]) -> Bool {
        guard apps != read(), let url = fileURL, let data = try? JSONEncoder().encode(apps) else { return false }
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
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "小工具"
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

/// Opens one app of 我的应用. Added to the home screen from Shortcuts, it is the app's own icon there.
struct OpenMiniAppIntent: AppIntent {
    static var title: LocalizedStringResource = "打开小工具"
    static var description = IntentDescription("打开一个小工具。在快捷指令里把它添加到主屏幕，就是这个小工具的图标。")
    static var openAppWhenRun = true

    @Parameter(title: "小工具")
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

/// Per-widget App Intents configuration is available from iOS 17.
@available(iOS 17.0, *)
struct MiniAppsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "小工具"
    static var description = IntentDescription("选择小组件里放哪些小工具。")

    @Parameter(title: "小工具")
    var apps: [MiniAppEntity]?

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}
