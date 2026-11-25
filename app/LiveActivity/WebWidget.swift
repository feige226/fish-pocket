import SwiftUI
import WidgetKit

/// 网页版: one tap into the app's 网页版, with no web page on the way (the other home-screen way,
/// `HomeScreenShortcut`, goes through Safari).
struct WebWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DshWeb", provider: WebProvider()) { _ in
            WebWidgetView()
                .widgetURL(DshLink.web.url)
        }
        .configurationDisplayName("网页版")
        .description("点一下就打开网页版。")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// Nothing on it changes.
private struct WebProvider: TimelineProvider {
    func placeholder(in context: Context) -> WebEntry { WebEntry() }
    func getSnapshot(in context: Context, completion: @escaping (WebEntry) -> Void) { completion(WebEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WebEntry>) -> Void) {
        completion(Timeline(entries: [WebEntry()], policy: .never))
    }
}

private struct WebEntry: TimelineEntry {
    let date = Date.now
}

private struct WebWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "globe").font(.system(size: 22, weight: .semibold))
            }
            .accessibilityLabel(Text("网页版"))
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
        } else {
            small.containerBackground(WidgetPalette.background, for: .widget)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                FishMark(size: 18)
                Spacer()
                Image(systemName: "globe")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .widgetFill(WidgetPalette.ink, in: Circle(), content: WidgetPalette.onInk)
            }
            Spacer(minLength: 4)
            Text("网页版").font(.title3.weight(.bold))
            Text(verbatim: "Fish Pocket").font(.footnote).foregroundStyle(WidgetPalette.secondary).lineLimit(1)
        }
        .foregroundStyle(WidgetPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
