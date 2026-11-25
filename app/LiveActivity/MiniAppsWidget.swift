import SwiftUI
import WidgetKit

/// 我的应用 on the home screen: the apps the user picked (the newest ones until they pick),
/// each one tap away. Opening one needs no engine.
struct MiniAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: MiniAppCatalog.widgetKind, intent: MiniAppsWidgetIntent.self, provider: MiniAppsProvider()) { entry in
            MiniAppsWidgetView(entry: entry)
        }
        .configurationDisplayName("Mini Apps")
        .description("把你做的 Mini App 放到主屏幕上。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MiniAppsEntry: TimelineEntry {
    let date: Date
    let apps: [MiniAppSummary]
}

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

    /// The picked apps still there, with their current names; none picked, the newest.
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
        Group {
            if entry.apps.isEmpty {
                empty
            } else if family == .systemSmall, let app = entry.apps.first {
                small(app).widgetURL(DshLink.app(app.id).url)
            } else {
                medium
            }
        }
        .containerBackground(WidgetPalette.background, for: .widget)
    }

    @ViewBuilder
    private func icon(_ app: MiniAppSummary, size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        if let image = MiniAppCatalog.icon(app) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(shape)
        } else {
            Text(verbatim: app.icon)
                .font(.system(size: size * 0.5))
                .frame(width: size, height: size)
                .widgetFill(Color(miniApp: app.color).gradient, in: shape)
        }
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
            Text("Mini Apps").font(.headline)
            Text("在对话里让 Agent 做一个 Mini App").font(.caption).foregroundStyle(WidgetPalette.secondary).lineLimit(2)
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "\(DshLink.scheme)://"))
    }
}
