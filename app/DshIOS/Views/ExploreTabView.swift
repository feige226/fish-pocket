import SwiftUI
import WatchConnectivity

/// The 探索 tab: 设置 first, then Mini Apps, then what the agent can be given beyond a
/// conversation of its own — plugins, connectors (with this device's capabilities), phone control,
/// the computers of remote control — then Apple Watch, Shortcuts, the web version and sharing the
/// app, and last the rating, website, feedback and community links. On an iPad before iOS 18
/// these are rows of the sidebar, Apple Watch, sharing and those links stay in 设置, and Mini
/// Apps and 设置 are sheets.
struct ExploreTabView: View {
    enum Route: Hashable { case miniApps, plugins, connectors, phoneControl, remote, watch, shortcuts, share, settings }

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: [Route]
    @State private var phoneControl = PhoneControlService()
    @State private var watch = WatchPairing.current
    @State private var miniApps = MiniAppStore.shared
    /// 设置 and the pages pushed from it wear the settings look, which a page takes from the stack
    /// it is in: put on just before 设置 is pushed, taken off once the stack is back at this page,
    /// which the look does not change. Never in the same update as a push: before iOS 26 the stack,
    /// shown again just after another tab, pushed 设置 a second time when its look changed with it.
    @State private var settingsLook = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    // A button, not a link: the look goes on first and 设置 is pushed after it
                    // (`openSettings`), so the chevron is drawn here as a link's would be.
                    Button(action: openSettings) {
                        label(Text("设置"), .settings, Text("模型、连接方式、语音和外观")) {
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(Palette.ink)
                } header: {
                    Text("通用")
                }
                Section {
                    row(.miniApps, Text(MiniAppsPage.tabTitle), .miniApps, "与 AI 共创",
                        status: miniApps.apps.isEmpty ? nil : String(localized: "\(miniApps.apps.count) 个 Mini App"))
                } header: {
                    Text("创作")
                }
                Section {
                    row(.plugins, Text("插件"), .plugins, "安装和管理插件")
                    row(.connectors, Text("连接器"), .connectors, "GitHub、Notion 等服务和本机能力", status: connectorStatus)
                    row(.phoneControl, Text("操控手机"), .phoneControl, "让智能体点按其他 App", status: phoneControl.state == .running ? String(localized: "运行中") : nil,
                        live: phoneControl.state == .running)
                    row(.remote, Text("远程控制"), .remote, "在手机上管电脑里的智能体", status: remoteStatus,
                        warns: app.remote.expired)
                } header: {
                    Text("扩展智能体")
                }
                Section {
                    if WCSession.isSupported() {
                        row(.watch, Text("Apple Watch"), .watch, "在手腕上看会话、做确认",
                            status: watch == .installed ? String(localized: "已安装") : nil)
                    }
                    row(.shortcuts, Text("快捷指令"), .shortcuts, "用 Siri 和自动化打开 Bot、Mini App")
                    // Opens over everything: the mark of the links that leave the page.
                    Button { Haptics.tap(); app.webRequest = UUID() } label: {
                        label(Text("网页版"), .web, Text("插件自带的界面在这里打开")) { leavesArrow }
                    }
                    .foregroundStyle(Palette.ink)
                    row(.share, Text("分享 Fish Pocket"), .share, "海报、二维码或链接")
                } header: {
                    Text("其他")
                }
                Section {
                    ForEach(SupportLink.all) { link in
                        Link(destination: link.url) {
                            label(Text(link.title), link.glyph, link.detail) { leavesArrow }
                        }
                        .foregroundStyle(Palette.ink)
                        .settlesRating(link.rates)
                    }
                } header: {
                    Text("反馈与社区")
                } footer: {
                    SupportLink.footer
                }
            }
            .tabEdgesSoftened()
            .navigationTitle("探索")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .miniApps: MiniAppsPage()
                case .plugins: PluginStoreView()
                case .connectors: BotConnectorsPage().settingsStyle()
                case .phoneControl: PhoneControlView().environment(\.systemLists, true)
                case .remote: RemoteControlPage().environment(\.systemLists, true)
                case .watch: WatchSetupPage()
                case .shortcuts: ShortcutsGuidePage()
                case .share: ShareAppPage()
                case .settings: SettingsView(pushed: true)
                }
            }
            // The rows say whether iCTRL runs and whether the watch has the app; both change while
            // the user is in another app.
            .task { await phoneControl.refresh() }
            .onAppear { watch = WatchPairing.current; miniApps.refresh() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                watch = WatchPairing.current
                Task { await phoneControl.refresh() }
            }
        }
        .environment(\.systemLists, settingsLook)
        .onChange(of: path.isEmpty) { _, root in if root { settingsLook = false } }
        .inkTint()
    }

    /// The look first, 设置 in the next update (`settingsLook`).
    private func openSettings() {
        settingsLook = true
        // A second tap before it shows pushes nothing more.
        DispatchQueue.main.async { if path.isEmpty { path.append(.settings) } }
    }

    /// Once signed in: computers online, offline, or the sign-in to renew. Before, the line under
    /// the name already says what it is for.
    private var remoteStatus: String? {
        let remote = app.remote
        return remote.signedIn || remote.expired ? DrawerView.remoteControlNote(remote) : nil
    }

    private var connectorStatus: String? {
        let team = app.botTeam
        let connected = team.status == .ready ? team.connectors.filter { $0["state"].string == "ready" }.count : 0
        return connected > 0 ? String(localized: "\(connected) 个已连接") : nil
    }

    private func row(_ route: Route, _ title: Text, _ icon: ExploreGlyph.Kind, _ detail: LocalizedStringKey,
                     status: String? = nil, warns: Bool = false, live: Bool = false) -> some View {
        NavigationLink(value: route) {
            label(title, icon, Text(detail)) {
                if let status {
                    HStack(spacing: 5) {
                        if live { Circle().fill(.green).frame(width: 7, height: 7) }
                        Text(status)
                    }
                    .font(.footnote)
                    .foregroundStyle(warns ? Palette.waiting : Palette.secondary)
                    .lineLimit(1)
                }
            }
        }
    }

    /// The mark of the rows that leave the page: the web version and the links at the foot.
    private var leavesArrow: some View {
        Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
    }

    /// The entry's drawn icon, the name and a line on what it is for, and what it says on the right.
    private func label(_ title: Text, _ icon: ExploreGlyph.Kind, _ detail: Text,
                       @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 14) {
            ExploreGlyph(kind: icon)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.body).foregroundStyle(Palette.ink)
                detail.font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            // The status whole first: cut short it says nothing ("1…" for one service connected),
            // and the line under the name has a second row to go to.
            trailing().layoutPriority(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
