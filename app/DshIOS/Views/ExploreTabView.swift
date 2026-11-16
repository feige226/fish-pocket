import SwiftUI
import Perception
import WatchConnectivity

/// The 探索 tab: what the agent can be given beyond a conversation of its own — plugins,
/// connectors, this device's capabilities, phone control — then the other devices (the computers
/// of remote control, Apple Watch), the web version and sharing the app. Before iOS 18 these are
/// rows of the sidebar, and Apple Watch and sharing stay in 设置.
struct ExploreTabView: View {
    enum Route: Hashable { case plugins, connectors, capabilities, phoneControl, remote, watch, share }

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: [Route]
    @State private var phoneControl = PhoneControlService()
    @State private var watch = WatchPairing.current

    var body: some View {
        WithPerceptionTracking {

        NavigationStack(path: $path) {
            List {
                Section {
                    row(.plugins, "插件", "puzzlepiece.extension", "发现、安装和管理插件")
                    row(.connectors, "连接器", "point.3.connected.trianglepath.dotted", "接入 GitHub、Notion 等外部服务", status: connectorStatus)
                    row(.capabilities, "本机能力", "iphone", "日历、健康、照片等本机数据和功能")
                    row(.phoneControl, "操控手机", "hand.tap", "让智能体点按其他 App", status: phoneControl.state == .running ? String(localized: "运行中") : nil,
                        live: phoneControl.state == .running)
                } header: {
                    Text("扩展智能体")
                }
                Section {
                    row(.remote, "远程控制", "laptopcomputer.and.iphone", "在手机上管电脑里的智能体", status: remoteStatus,
                        warns: app.remote.expired)
                    if WCSession.isSupported() {
                        row(.watch, "Apple Watch", "applewatch", "在手腕上看会话、做确认",
                            status: watch == .installed ? String(localized: "已安装") : nil)
                    }
                } header: {
                    Text("更多设备")
                }
                Section {
                    // Opens over everything: the mark of the links that leave the page.
                    Button { Haptics.tap(); app.webRequest = UUID() } label: {
                        label("网页版", "globe", "插件自带的界面在这里打开") {
                            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(Palette.ink)
                    row(.share, "分享 Fish Pocket", "square.and.arrow.up", "海报、二维码或链接")
                }
            }
            .navigationTitle("探索")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .plugins: PluginStoreView()
                case .connectors: BotConnectorsPage().settingsStyle()
                case .capabilities: NativeCapabilitiesView().environment(\.systemLists, true)
                case .phoneControl: PhoneControlView().environment(\.systemLists, true)
                case .remote: RemoteControlPage().environment(\.systemLists, true)
                case .watch: WatchSetupPage()
                case .share: ShareAppPage()
                }
            }
            // The rows say whether iCTRL runs and whether the watch has the app; both change while
            // the user is in another app.
            .task { await phoneControl.refresh() }
            .onAppear { watch = WatchPairing.current }
            .onChangeCompat(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                watch = WatchPairing.current
                Task { await phoneControl.refresh() }
            }
        }
    
        }}

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

    private func row(_ route: Route, _ title: LocalizedStringKey, _ icon: String, _ detail: LocalizedStringKey,
                     status: String? = nil, warns: Bool = false, live: Bool = false) -> some View {
        NavigationLink(value: route) {
            label(title, icon, detail) {
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

    /// An icon on an ink tile, the name and a line on what it is for, and what it says on the right.
    private func label(_ title: LocalizedStringKey, _ icon: String, _ detail: LocalizedStringKey,
                       @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.onInk)
                .frame(width: 38, height: 38)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            // The name and its line first; a status that does not fit is what gives way.
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
