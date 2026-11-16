import SwiftUI

/// 小工具: the small tools and games the agent made, as icons on a grid. They run on this
/// phone only, each on its own. The ones the app came with sit apart under 示例, so they read
/// as examples of what to ask for rather than a catalog of ours.
struct MiniAppsPage: View {
    /// The phone's 小工具 tab, under a large title; otherwise a sheet with its close button.
    var asTab = false
    @State private var store = MiniAppStore.shared
    @State private var deleting: MiniApp?
    @Environment(\.scenePhase) private var scenePhase
    /// An iPad or an open Duo: the page uses the whole width, as a home screen does.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var wide: Bool { sizeClass == .regular }
    private var iconSize: CGFloat { wide ? 72 : 60 }
    private var columns: [GridItem] {
        wide ? [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16, alignment: .top)]
             : [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 12, alignment: .top)]
    }

    var body: some View {
        let examples = MiniAppExamples.ids
        let mine = store.apps.filter { !examples.contains($0.id) }
        let samples = store.apps.filter { examples.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                createCard
                if !mine.isEmpty {
                    section(String(localized: "我做的"), mine)
                }
                if !samples.isEmpty {
                    section(String(localized: "示例"), samples,
                            note: String(localized: "自带的几个示例，看看 Agent 能做出什么。用不上可以长按删除。"))
                }
                Text("小工具只在这台设备上运行，彼此隔离，读不到你的文件和对话，可以联网。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, wide ? 24 : 16)
            .padding(.top, 12)
        }
        .refreshable { store.refresh() }
        .background(Palette.background)
        .navigationTitle(Self.tabTitle)
        .navigationBarTitleDisplayMode(asTab ? .large : .inline)
        .onAppear { store.refresh() }
        .onChangeCompat(of: scenePhase) { _, phase in if phase == .active { store.refresh() } }
        .confirmationDialog("删除「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除小工具", role: .destructive) {
                guard let app = deleting else { return }
                Task { await store.delete(app) }
            }
        } message: {
            Text("小工具的文件和它保存的数据都会删除，无法恢复。")
        }
    }

    /// The 小工具 tab's name and the page's title.
    static var tabTitle: String {
        String(localized: "tab.apps", defaultValue: "小工具", comment: "Tab and page title: the small tools and games the user had the agent make")
    }

    /// The page's one way in for a tool of the user's own, first on the page whatever is already there.
    /// Full width everywhere: stacked on a phone, one row with the button at its end when wide.
    @ViewBuilder
    private var createCard: some View {
        Group {
            if wide {
                HStack(alignment: .center, spacing: 16) {
                    cardIcon
                    cardText
                    Spacer(minLength: 16)
                    startButton.buttonStyle(.capsule(.primary, height: 44, fill: false))
                }
                .padding(20)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        cardIcon
                        cardText
                    }
                    startButton.buttonStyle(.capsule(.primary, height: 46))
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var cardIcon: some View {
        Image(systemName: "wand.and.stars")
            .font(.title2)
            .foregroundStyle(Palette.ink)
            .frame(width: 32)
    }

    private var cardText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("做一个自己的小工具").font(.headline).foregroundStyle(Palette.ink)
            Text("说说你想要什么，比如「做个记账本」「做个背单词卡片」，Agent 做好后会放在这里，点开就能用。")
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startButton: some View {
        Button { create() } label: {
            Label("开始做", systemImage: "plus")
        }
    }

    private func section(_ title: String, _ apps: [MiniApp], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                if let note {
                    Text(note).font(.footnote).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(apps) { app in
                    Button { open(app) } label: { tile(app) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(app) }
                }
            }
        }
    }

    private func tile(_ app: MiniApp) -> some View {
        VStack(spacing: 6) {
            MiniAppIcon(icon: app.icon, color: app.color, size: iconSize)
            Text(app.name).font(.caption).foregroundStyle(Palette.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func menu(_ app: MiniApp) -> some View {
        Button("打开", systemImage: "arrow.up.forward.app") { open(app) }
        Button("让 Agent 修改", systemImage: "wand.and.stars") { ask(MiniAppPresenter.editDraft(app)) }
        Button("添加到主屏幕", systemImage: "plus.square.on.square") { MiniAppHomeScreen.add(app) }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { deleting = app }
    }

    private func open(_ app: MiniApp) {
        Haptics.tap()
        MiniAppPresenter.open(app.id)
    }

    private func create() {
        ask(String(localized: "帮我做一个小工具："))
    }

    /// A new conversation with `draft` in the composer; the shell closes this sheet to show it.
    private func ask(_ draft: String) {
        LinkInbox.shared.request = LinkRequest(link: .new(draft: draft))
    }
}

/// An app's icon: its emoji on its color, in the home screen's shape.
struct MiniAppIcon: View {
    let icon: String
    let color: String
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color(miniApp: color).gradient)
            .frame(width: size, height: size)
            .overlay { Text(verbatim: icon).font(.system(size: size * 0.5)) }
            .accessibilityHidden(true)
    }
}

/// A reply's link to a tool on a line of its own (`[记账本](fishapp://ledger)`), as a card that
/// opens it.
struct MiniAppCard: View {
    let id: String
    let title: String
    @State private var app: MiniApp?
    @State private var looked = false

    /// The id, when `paragraph` is nothing but a link to an app.
    static func linkedApp(_ paragraph: String) -> (id: String, title: String)? {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.wholeMatch(of: /\[([^\]\n]+)\]\(fishapp:\/\/([a-z0-9-]+)\/?\)/) else { return nil }
        return (String(match.output.2), String(match.output.1))
    }

    var body: some View {
        Button {
            Haptics.tap()
            MiniAppPresenter.open(id)
        } label: {
            HStack(spacing: 12) {
                MiniAppIcon(icon: app?.icon ?? MiniApp.defaultIcon, color: app?.color ?? MiniApp.defaultColor, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app?.name ?? title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(looked && app == nil ? String(localized: "小工具已删除") : app?.summary ?? String(localized: "小工具"))
                        .font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if app != nil {
                    Text("打开")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Palette.ink, in: Capsule())
                }
            }
            .padding(12)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(looked && app == nil)
        .task(id: id) {
            app = MiniAppStore.shared.app(id)
            looked = true
        }
    }
}
