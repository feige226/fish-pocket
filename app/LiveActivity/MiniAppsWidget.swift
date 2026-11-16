import SwiftUI
import WidgetKit

/// 我的应用 on the home screen: the apps the user picked (the most recent ones until they pick),
/// each one tap away. iOS 17 uses per-widget App Intents configuration; iOS 16 shows recent apps.
struct MiniAppsWidget: Widget {
    var body: some WidgetConfiguration {
        if #available(iOSApplicationExtension 17.0, *) {
            AppIntentConfiguration(kind: MiniAppCatalog.widgetKind, intent: MiniAppsWidgetIntent.self, provider: MiniAppsProvider()) { entry in
                MiniAppsWidgetView(entry: entry)
            }
            .configurationDisplayName("小工具")
            .description("把你做的小工具和小游戏放到主屏幕上。")
            .supportedFamilies([.systemSmall, .systemMedium])
        } else {
            StaticConfiguration(kind: MiniAppCatalog.widgetKind, provider: MiniAppsLegacyProvider()) { entry in
                MiniAppsWidgetView(entry: entry)
            }
            .configurationDisplayName("小工具")
            .description("把你做的小工具和小游戏放到主屏幕上。")
            .supportedFamilies([.systemSmall, .systemMedium])
        }
    }
}

struct MiniAppsEntry: TimelineEntry {
    let date: Date
    let apps: [MiniAppSummary]
}

/// iOS 16 fallback: display the latest apps without the iOS 17 per-widget picker.
struct MiniAppsLegacyProvider: TimelineProvider {
    func placeholder(in context: Context) -> MiniAppsEntry {
        MiniAppsEntry(date: .now, apps: [MiniAppSummary(id: "demo", name: "记账本", icon: "💰", color: "#FF9500")])
    }

    func getSnapshot(in context: Context, completion: @escaping (MiniAppsEntry) -> Void) {
        completion(makeEntry(context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MiniAppsEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry(context)], policy: .never))
    }

    private func makeEntry(_ context: Context) -> MiniAppsEntry {
        let all = MiniAppCatalog.read()
        let limit = context.family == .systemSmall ? 1 : 4
        return MiniAppsEntry(date: .now, apps: Array(all.prefix(limit)))
    }
}

@available(iOSApplicationExtension 17.0, *)
struct MiniAppsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MiniAppsEntry {
        MiniAppsEntry(date: .now, apps: [MiniAppSummary(id: "demo", name: String(localized: "记账本"), icon: "💰", color: "#FF9500")])
    }

    func snapshot(for configuration: MiniAppsWidgetIntent, in context: Context) async -> MiniAppsEntry {
        entry(configuration, context)
    }

    func timeline(for configuration: MiniAppsWidgetIntent, in context: Context) async -> Timeline<MiniAppsEntry> {
        Timeline(entries: [entry(configuration, context)], policy: .never)
    }

    /// The picked apps still there, with their current names; none picked, the most recent.
    private func entry(_ configuration: MiniAppsWidgetIntent, _ context: Context) -> MiniAppsEntry {
        let all = MiniAppCatalog.read()
        let limit = context.family == .systemSmall ? 1 : 4
        let picked = (configuration.apps ?? []).compactMap { pick in all.first { $0.id == pick.id } }
        return MiniAppsEntry(date: .now, apps: Array((picked.isEmpty ? all : picked).prefix(limit)))
    }
}

private struct MiniAppsWidgetView: View {
    let entry: MiniAppsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(WidgetPalette.background, for: .widget)
        } else {
            content.background(WidgetPalette.background)
        }
    }

    private var content: some View {
        Group {
            if entry.apps.isEmpty {
                empty
            } else if family == .systemSmall, let app = entry.apps.first {
                small(app).widgetURL(DshLink.app(app.id).url)
            } else {
                medium
            }
        }
    }

    private func icon(_ app: MiniAppSummary, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color(miniApp: app.color).gradient)
            .frame(width: size, height: size)
            .overlay { Text(verbatim: app.icon).font(.system(size: size * 0.5)) }
    }

    private func small(_ app: MiniAppSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            icon(app, size: 64)
            Spacer(minLength: 4)
            Text(verbatim: app.name).font(.headline).lineLimit(2)
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(entry.apps) { app in
                Link(destination: DshLink.app(app.id).url) {
                    VStack(spacing: 6) {
                        icon(app, size: 56)
                        Text(verbatim: app.name).font(.caption).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            ForEach(entry.apps.count..<4, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            FishMark(size: 18)
            Spacer(minLength: 0)
            Text("小工具").font(.headline)
            Text("在对话里让 Agent 做一个小工具").font(.caption).foregroundStyle(WidgetPalette.secondary).lineLimit(2)
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "\(DshLink.scheme)://"))
    }
}
