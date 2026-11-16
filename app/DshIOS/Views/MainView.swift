import StoreKit
import SwiftUI

import Perception
/// The root. From iOS 18 the system's adaptable tab bar in every width: 会话, Bot, 应用, 探索 and 设置,
/// at the bottom on a phone, at the top or as a sidebar where there is room (iPad, iPhone Duo open).
/// The 会话 tab pushes a conversation over its list where it is narrow and keeps one beside it where it
/// is wide. Before iOS 18 the session list is the split view's sidebar beside a conversation, always
/// (with nothing selected a blank session opens), and on a phone a drawer that slides in from the left.
struct MainView: View {
    /// The phone's tabs.
    enum HomeTab: Hashable { case sessions, bot, apps, explore, settings }

    enum Sheet: String, Identifiable { case settings, plugins, store, schedules, signIn, cordis, share, watch, capabilities, connectors, phoneControl, remote, fishPocket, miniApps; var id: String { rawValue } }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @AppStorage("dsh.currentWorkspace") private var workspaceId = ""
    @State private var selection: String?
    @State private var sheet: Sheet?
    /// In regular width the plugin store takes the conversation's place beside the sidebar.
    @State private var storeOpen = false
    @State private var webOpen = false
    /// The Bot pages take the conversation's place (the drawer's Bot card opens them).
    @State private var botOpen = false
    @State private var botPath: [BotRoute] = []
    /// The sidebar, in regular width.
    @State private var sidebar = NavigationSplitViewVisibility.all
    @State private var windowWidth: CGFloat = 0
    @State private var searchRequest = 0
    @State private var drawerOpen = false
    @State private var tab = HomeTab.sessions
    /// The 会话 tab's stack: the archive, and the conversation on screen (`selection`) on top.
    @State private var sessionsPath: [DrawerView.Route]
    /// The 探索 tab's stack: the plugin store is pushed on it when something asks for it.
    @State private var explorePath: [ExploreTabView.Route] = []
    /// The 会话 tab's own split view, where it is wide: the list can make way for the workbench.
    @State private var sessionsColumns = NavigationSplitViewVisibility.all
    @State private var drag: CGFloat = 0
    /// The way a drag on the shell set off, fixed by its first move; nil between drags.
    /// A plain reference filled by the drawer's rows.
    @State private var rowFrames = DrawerRowFrames()
    @State private var creating = false
    @State private var onboarding: Onboarding?
    /// 「添加 API Key」 was chosen in the sign-in sheet: its key editor follows once that sheet is gone.
    @State private var keyEditorRef: String?
    /// 「Fish Pocket 账号」 was chosen in the sign-in sheet: its page follows once that sheet is gone.
    @State private var fishPocketAfterOnboarding = false
    /// The ask for a Star or a share (`SupportPrompt`'s `.support`).
    @State private var supportDialog = false
    /// 「新功能」 after an update (`WhatsNew`).
    @State private var whatsNew: WhatsNew.Release?
    /// The plugins safe mode switched off on the launch screen (NodeEngine.requestSafeMode).
    @State private var safeModeDisabled: [String]?
    /// It was shown: no update toast on top of it this time.
    @State private var newsShown = false
    /// 「在电脑上新建会话」, once whatever sheet asked for it has gone.
    @State private var remoteTarget: RemoteSessionTarget?
    /// The launch has gone back to the page the app was last on (`place`); from then on the page
    /// in front is kept for the next launch. A window opened on a session stays on it.
    @State private var placeRestored: Bool
    /// The launch went back to a Bot page: the blank conversation made under it does not take its place.
    @State private var launchedUnderBot = false

    /// A `dsh://` link this window received (`RootView`), until it is followed.
    @Binding private var link: LinkRequest?

    /// `session`: the one this window opened on, when it opened on one.
    init(session: String? = nil, link: Binding<LinkRequest?> = .constant(nil)) {
        _selection = State(initialValue: session)
        _sessionsPath = State(initialValue: session.map { [.session($0)] } ?? [])
        _placeRestored = State(initialValue: session != nil)
        _link = link
    }

    private static let placeKey = "dsh.lastPlace"

    /// The page in front, as it is kept for the next launch: a conversation, the Bot list, a
    /// Bot's chat or a group.
    private var place: String? {
        // On the tab bar only 会话 and Bot are kept: from the other tabs the next launch goes back
        // to whichever of the two was last in front.
        if usesTabs, tab != .sessions, tab != .bot { return nil }
        // On the tab bar the list with nothing pushed is a place too: the next launch stays there.
        guard botOpen else { return selection.map { "session:\($0)" } ?? (usesTabs ? "sessions" : nil) }
        switch botPath.last {
        case .bot(let id)?: return "bot:\(id)"
        case .room(let id)?: return "room:\(id)"
        case nil: return "bots"
        }
    }

    /// Back to the page the app was last on, when it is still there; a link or a notification
    /// that opened the app has already picked its own.
    private func restorePlace() {
        guard selection == nil, let kept = UserDefaults.standard.string(forKey: Self.placeKey) else { return }
        let parts = kept.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "session":
            // A session on a computer is taken on trust while signed in: its page says so if it has gone.
            // A Bot's own session is its chat's, not a conversation to put back.
            if RemoteStore.sessionId(of: id) != nil ? app.remote.signedIn : app.workspace(of: id).map({ !isTeamWorkspace($0) }) == true && !app.isArchived(id) { selection = id }
        case "bot": openBots([.bot(id)])
        case "room": openBots([.room(id)])
        case "bots": openBots([])
        default: break
        }
    }

    private func openBots(_ path: [BotRoute]) {
        launchedUnderBot = true
        botOpen = true
        if usesTabs { tab = .bot }
        botPath = path
    }

    /// The credential sheets (`settings.onboarding`'s steps). Unlike the web they never open by
    /// themselves at launch: the interface comes first, and a message sent with nothing to answer
    /// it asks for them (`SessionModel`), as do the sign-in buttons.
    enum Onboarding: Identifiable {
        case signIn(ref: String, autoStart: Bool = false)
        case key(ref: String)
        var id: String {
            switch self {
            case .signIn: "sign-in"
            case .key: "key"
            }
        }
    }

    /// Where a new conversation goes: the current workspace, else the first-use one, never the Bot
    /// team's, which holds the Bots' sessions alone (a blank one there would be reused: a Bot's chat).
    private var workspace: Workspace? {
        let usable = app.workspaces.filter { !isTeamWorkspace($0) }
        return usable.first { $0.id == workspaceId } ?? usable.first { $0.title == "default-workspace" } ?? usable.first ?? app.workspaces.first
    }

    /// The Bot team's workspace: by the team's word once it answers, before that (the launch races the
    /// Bot plugin) by ds-bot's default folder. The engine lists it before the first-use workspace.
    private func isTeamWorkspace(_ workspace: Workspace) -> Bool {
        workspace.id == app.botTeam.teamWorkspaceId || workspace.path.hasSuffix("/.dsh/bot/workspace")
    }

    /// The workspace a session shown here belongs to becomes the current one; the Bot team's never does.
    private func remember(workspaceOf id: String) {
        if let owner = app.workspace(of: id), !isTeamWorkspace(owner) { workspaceId = owner.id }
    }

    /// A button of the support dialog: the ask is answered for good.
    private func settleSupport(then action: () -> Void) {
        Haptics.tap()
        SupportPrompt.settle()
        supportDialog = false
        action()
    }

    /// The width the layout is made for: the size class, as it was last seen on screen. Leaving the
    /// screen, iOS draws the app at its other width for the app switcher's snapshot and then back
    /// (iPhone Duo open: folded, then open again). Following that would make the layout over twice
    /// out of sight, and whatever a page had presented (a file's preview) would be gone, or on a
    /// device be left standing empty.
    @State private var settledWidth: UserInterfaceSizeClass?
    private var layoutWidth: UserInterfaceSizeClass? { settledWidth ?? sizeClass }

    /// Announcements are made once, so never under a sheet.
    private var canAnnounce: Bool {
        scenePhase == .active && onboarding == nil && sheet == nil && whatsNew == nil
    }

    /// The width's own layout, with the way into the plugin store.
    private var layout: some View {
        Group {
            if #available(iOS 18.0, *) {
                tabLayout
            } else if layoutWidth == .regular {
                split
            } else {
                drawerLayout
            }
        }
        // The drawer and the new conversation page, which have no way to the store themselves.
        .onChangeCompat(of: app.pluginStoreRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.pluginStoreRequest = nil
            openPlugins()
        }
        .onChangeCompat(of: app.webRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.webRequest = nil
            webOpen = true
        }
        .onChangeCompat(of: app.botTeam.openRequest?.token) { _, token in
            guard token != nil, let request = app.botTeam.openRequest else { return }
            app.botTeam.openRequest = nil
            sheet = nil
            storeOpen = false
            botOpen = true
            if usesTabs { tab = .bot }
            botPath = request.route.map { route in request.push && botPath.last != route ? botPath + [route] : [route] } ?? []
            setDrawer(false)
        }
        // The sidebar's own row; the page is also still under Settings.
        .onChangeCompat(of: app.nativeCapabilitiesRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.nativeCapabilitiesRequest = nil
            sheet = .capabilities
        }
        .onChangeCompat(of: app.remoteRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.remoteRequest = nil
            setDrawer(false)
            sheet = .remote
        }
        // Asked for from the sidebar, a conversation or a page inside a sheet: that sheet goes first.
        .onChangeCompat(of: app.remoteSessionRequest) { _, request in
            guard let request, scenePhase != .background else { return }
            app.remoteSessionRequest = nil
            setDrawer(false)
            let wait = sheet != nil
            sheet = nil
            Task {
                if wait { try? await Task.sleep(for: .milliseconds(450)) }
                remoteTarget = request
            }
        }
        .sheet(item: $remoteTarget) { RemoteNewSessionSheet(target: $0).sheetNotices() }
        // Signed out of remote control (or the server ended it): its conversation has nothing to show.
        .onChangeCompat(of: app.remote.signedIn) { _, signedIn in
            if !signedIn, RemoteStore.sessionId(of: selection) != nil { selection = nil }
        }
        // Its computer was taken off the account: the same.
        .onChangeCompat(of: app.remote.departed) { _, gone in
            if let id = RemoteStore.sessionId(of: selection), gone.contains(id) { selection = nil }
        }
        .onChangeCompat(of: app.connectorsRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.connectorsRequest = nil
            sheet = .connectors
        }
        .onChangeCompat(of: app.phoneControlRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.phoneControlRequest = nil
            sheet = .phoneControl
        }
        .fullScreenCover(isPresented: $webOpen) { WebFallbackView() }
        // The Live Activity and the widgets; a cold launch keeps the link until this view is up.
        .onChangeCompat(of: link?.token, initial: true) {
            guard let request = link else { return }
            link = nil
            Task { await follow(request.link) }
        }
        .onChange(of: workspaceId) { WidgetSnapshotWriter.shared.refresh() }
        .onAppear { settledWidth = sizeClass }
        .onChangeCompat(of: sizeClass) { _, size in
            if scenePhase == .active { settle(size) }
        }
        // On the tab bar the Bot pages are its Bot tab. A conversation left pushed under another
        // tab is not on screen: what finishes there meanwhile is marked unread, and the watch told.
        .onChangeCompat(of: tab) { _, tab in
            guard usesTabs else { return }
            botOpen = tab == .bot
            app.currentSession = shownSession
        }
        .onChangeCompat(of: botOpen) { _, open in if usesTabs, open { tab = .bot } }
        // Back to the list (or the archive) on the 会话 tab: no conversation on screen any more.
        .onChangeCompat(of: sessionsPath) { _, path in
            guard usesTabs else { return }
            let top = path.last?.session
            if top != selection { selection = top }
        }
    }

    /// The layout with what the window follows: its launch, the page it is on, and the requests
    /// the model raises. Apart from `body`, as `layout` is: one chain of all of it is more than
    /// the compiler type-checks in the time it allows itself (Xcode 26 gives up on it).
    private var shell: some View {
        layout
        .tint(Palette.ink)
        .onGeometryChangeCompat(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .focusedSceneValue(\.windowCommands, windowCommands)
        .task(id: app.workspaces.map(\.id)) { launched() }
        .onChangeCompat(of: place) { _, place in
            if placeRestored, let place { UserDefaults.standard.set(place, forKey: Self.placeKey) }
        }
        // Which store this copy came from: only an App Store install is asked for a rating.
        .task { await AppDistribution.refresh() }
        // The sidebar's 我的应用 row; on the tab bar the page is a tab.
        .onChangeCompat(of: app.miniAppsRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.miniAppsRequest = nil
            if usesTabs { tab = .apps } else { sheet = .miniApps }
        }
        .task(id: canAnnounce) {
            guard canAnnounce else { return }
            if let names = NodeEngine.shared.takeSafeModeReport() {
                safeModeDisabled = names
                return
            }
            if let release = WhatsNew.take() {
                newsShown = true
                whatsNew = release
                return
            }
            await UpdateChecker.shared.checkIfDue()
            guard !newsShown, let update = UpdateChecker.shared.takeAnnouncement() else { return }
            app.showToast(String(localized: "发现新版本 \(update.version)"), action: String(localized: "更新")) { openURL(update.url) }
        }
        // After a pause, and only into a quiet app: otherwise the next finished turn asks instead.
        .task(id: app.supportMoment) {
            guard app.supportMoment > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, canAnnounce, app.toast == nil, app.currentSession == selection,
                  !app.sessions.values.contains(where: \.running), let ask = SupportPrompt.take() else { return }
            switch ask {
            // The system decides whether its sheet shows, and never says.
            case .review: requestReview()
            case .support: supportDialog = true
            }
        }
        // Windows take turns: what is read is the one in front.
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active {
                // Folded or opened while away: that one counts.
                settle(sizeClass)
                app.currentSession = shownSession
                ReadAloud.shared.scope = onScreen
            }
        }
        // Reading aloud belongs to the conversation on screen: moving to another one stops it.
        .onChangeCompat(of: onScreen, initial: true) { _, session in ReadAloud.shared.scope = session }
        .onChangeCompat(of: selection) { _, id in
            app.currentSession = shownSession
            if usesTabs {
                showInTabs(id)
                return
            }
            if launchedUnderBot { launchedUnderBot = false } else { botOpen = false }
            if let id {
                remember(workspaceOf: id)
            } else {
                newConversation(in: workspace)
            }
        }
        // An archived current session leaves the main view (here, the drawer, a follow push).
        .onChangeCompat(of: app.archived) { _, archived in
            if let selection, archived.contains(selection) { self.selection = nil }
        }
        // `app.open(session:)`: toasts, the subagent catalog, schedules…
        .onChangeCompat(of: app.openRequest?.token) { _, token in
            guard token != nil, scenePhase != .background, let id = app.openRequest?.id else { return }
            app.openRequest = nil
            // Asked for over a sheet (a toast there): the sheet goes, or the session opens unseen behind it.
            sheet = nil
            botOpen = false
            selection = id
            if usesTabs { showInTabs(id) }
            setDrawer(false)
        }
        .onChangeCompat(of: app.newSessionRequest?.token) { _, token in
            guard token != nil, scenePhase != .background, let request = app.newSessionRequest else { return }
            app.newSessionRequest = nil
            sheet = nil
            storeOpen = false
            // The conversation shows in place of the Bot pages too. The engine may hand back the
            // blank conversation already selected, and then no change of selection closes them.
            botOpen = false
            launchedUnderBot = false
            let target = request.workspaceId.flatMap { id in app.workspaces.first { $0.id == id } } ?? workspace
            if let target { workspaceId = target.id }
            newConversation(in: target, agentPreset: request.agentPreset, draft: request.draft, prompt: request.prompt)
            setDrawer(false)
        }
        .onChangeCompat(of: app.credentialRequest?.token) { _, token in
            guard token != nil, scenePhase != .background, let step = app.credentialRequest?.step else { return }
            app.credentialRequest = nil
            Task { await openCredentials(step) }
        }
        #if DEBUG
        .task { openForChecks() }
        #endif
    }

    /// The workspaces are known, and with them which sessions there are: back to the page the
    /// app was last on, or a blank conversation.
    private func launched() {
        guard !app.workspaces.isEmpty else { return }
        if !placeRestored {
            placeRestored = true
            restorePlace()
            // On the tab bar someone with no conversation yet has nothing to see in the list: the
            // new conversation page is where they start. Back from it is the (empty) list.
            if usesTabs, selection == nil, tab == .sessions, !hasConversations { newConversation(in: workspace) }
        }
        if selection == nil, !usesTabs { newConversation(in: workspace) }
    }

    /// Any conversation of the user's, archived ones and those on a computer included; the Bots' are not.
    private var hasConversations: Bool {
        if app.remote.signedIn { return true }
        let team = app.botTeam.teamWorkspaceId
        return app.workspaces.contains { $0.id != team && !app.sessions(in: $0, includeArchived: true).isEmpty }
            || !app.sessions(in: nil, includeArchived: true).isEmpty
    }

    /// The conversation the user is looking at (`AppModel.currentSession`): on the tab bar, only
    /// while the 会话 tab is in front.
    private var shownSession: String? {
        usesTabs && tab != .sessions ? nil : selection
    }

    /// The tab bar is the layout (`layout`), in every width.
    private var usesTabs: Bool {
        if #available(iOS 18.0, *) { true } else { false }
    }

    /// Where there is room for the session list beside the conversation, on the tab bar's 会话 tab.
    private var sessionsSideBySide: Bool { usesTabs && layoutWidth == .regular }

    /// The window's width changed on screen (an iPad window resized, iPhone Duo folded or opened).
    private func settle(_ size: UserInterfaceSizeClass?) {
        guard size != layoutWidth else { return }
        settledWidth = size
        // Before iOS 18, a window narrowed past the sidebar has no place beside it for the store.
        // The tab bar keeps its tabs in every width.
        if !usesTabs, size != .regular, storeOpen {
            storeOpen = false
            sheet = .store
        }
        // Wide again: the system put the 会话 tab's list away on the way down, before the
        // conversation was pushed over it. It comes back.
        if usesTabs, size == .regular { sessionsColumns = .all }
    }

    /// `selection` on the tab bar: a session is pushed on the 会话 tab, in front; none, it is popped.
    private func showInTabs(_ id: String?) {
        guard let id else {
            sessionsPath.removeAll { $0.session != nil }
            return
        }
        remember(workspaceOf: id)
        launchedUnderBot = false
        tab = .sessions
        // Over the archive when it was open, so back returns there.
        if sessionsPath.last != .session(id) {
            sessionsPath = sessionsPath.filter { $0.session == nil } + [.session(id)]
        }
    }

    #if DEBUG
    /// Screenshots and UI checks: `simctl launch … -dshOpen drawer|workbench|approval|question|timeline|settings|plugins|store|schedules|signin|support|share|watch|connectors|whatsnew|capabilities|phonecontrol|remote|start|fishpocket|topup|miniapps`.
    private func openForChecks() {
        switch UserDefaults.standard.string(forKey: "dshOpen") {
        case "drawer": drawerOpen = true
        case "settings": sheet = .settings
        case "plugins": sheet = .plugins
        case "store": openPlugins()
        case "schedules": sheet = .schedules
        case "signin": sheet = .signIn
        case "support": supportDialog = true
        case "share": sheet = .share
        case "watch": sheet = .watch
        case "connectors": sheet = .connectors
        case "whatsnew": whatsNew = WhatsNew.current
        case "capabilities": sheet = .capabilities
        case "phonecontrol": sheet = .phoneControl
        case "remote": sheet = .remote
        case "start": Task { await openCredentials(.start) }
        case "fishpocket": sheet = .fishPocket
        case "topup": app.fishPocket.quotaPrompt = true
        case "miniapps": if usesTabs { tab = .apps } else { sheet = .miniApps }
        default: break
        }
    }
    #endif

    /// What a sheet of the shell shows.
    @ViewBuilder
    private func page(of sheet: Sheet) -> some View {
        switch sheet {
        case .settings: SettingsView()
        // Pages 设置 also holds look the same opened from here: the system's lists.
        case .plugins: SheetStack { PluginsView() }.environment(\.systemLists, true)
        case .store: SheetStack { PluginStoreView() }
        case .schedules: SheetStack { SchedulesView(openSession: open(session:)) }.environment(\.systemLists, true)
        case .signIn: SignInSheet()
        case .cordis: CordisPanelView(currentSession: selection)
        case .share: SheetStack { ShareAppPage() }
        case .watch: SheetStack { WatchSetupPage() }
        case .capabilities: SheetStack { NativeCapabilitiesView() }.environment(\.systemLists, true)
        // The services ordinary conversations and Bots both reach; the Bot team's settings hold the same page.
        case .connectors: SheetStack { BotConnectorsPage() }.settingsStyle()
        case .phoneControl: SheetStack { PhoneControlView() }.environment(\.systemLists, true)
        case .remote: SheetStack { RemoteControlPage() }.environment(\.systemLists, true)
        case .fishPocket: SheetStack { FishPocketPage() }
        case .miniApps: SheetStack { MiniAppsPage() }
        }
    }

    var body: some View {
        WithPerceptionTracking {

        shell
        .sheet(item: $sheet) { page(of: $0).sheetNotices() }
        .sheet(item: $onboarding, onDismiss: onboardingDismissed) { step in
            switch step {
            case .signIn(let ref, let autoStart):
                SignInSheet(
                    autoStart: autoStart,
                    addAPIKey: { keyEditorRef = ref },
                    useFishPocket: fishPocketOption
                )
            case .key(let ref):
                OnboardingKeySheet(ref: ref) { onboarding = nil }
            }
        }
        .sheet(item: $whatsNew) { WhatsNewSheet(release: $0) }
        .modifier(ShellDialogs())
        .overlay { ShellNotices() }
        .overlay {
            if supportDialog {
                SupportDialog(
                    star: { settleSupport { openURL(AppLinks.repository) } },
                    share: { settleSupport { sheet = .share } },
                    later: { supportDialog = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(.snappy, value: supportDialog)
        // A live turn ran out of account balance: offer Platform's top-up page, then re-read balances.
        .alert("当前无可用余额", isPresented: Binding(get: { app.account.quotaPrompt }, set: { app.account.quotaPrompt = $0 })) {
            Button("取消", role: .cancel) {}
            Button("去充值") {
                guard let url = app.account.topUpURL else { return }
                InAppSafari.open(url) { Task { await app.account.refreshDetails() } }
            }
        } message: {
            Text("充值后才能开始新会话，也可稍后在「设置 → 账号与余额」充值。")
        }
        // A live turn ran out of Fish Pocket credits: the packs, bought in the app.
        .sheet(isPresented: Binding(get: { app.fishPocket.quotaPrompt }, set: { app.fishPocket.quotaPrompt = $0 })) {
            FishPocketTopUpSheet().sheetNotices()
        }
        .alert("已停用 \(safeModeDisabled?.count ?? 0) 个第三方插件", isPresented: Binding(get: { safeModeDisabled != nil }, set: { if !$0 { safeModeDisabled = nil } })) {
            Button("去插件页") { sheet = .plugins }
            Button("好", role: .cancel) {}
        } message: {
            Text("它们仍然装着。可以在插件页逐个重新打开，找出是哪个卡住了引擎。\n\n\((safeModeDisabled ?? []).joined(separator: "\n"))")
        }
        .onChangeCompat(of: app.lastError) { _, error in if error != nil { Haptics.error() } }
        .alert("出错了", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(app.lastError ?? "")
        }
        .environment(\.openSession) { open(session: $0) }
    
        }}

    // MARK: Credentials

    /// Without a reference (the official route is off) the key lives in settings, and signing in is all that is left.
    private func openCredentials(_ step: AppModel.CredentialStep) async {
        sheet = nil
        if case .settings = step { sheet = .settings; return }
        if case .fishPocket = step { sheet = .fishPocket; return }
        guard let ref = await app.officialKeyRef() else {
            if case .officialKey = step { sheet = .settings } else { sheet = .signIn }
            return
        }
        switch step {
        case .start, .signIn:
            if case .signIn = step { onboarding = .signIn(ref: ref, autoStart: true) } else { onboarding = .signIn(ref: ref) }
        case .officialKey:
            onboarding = .key(ref: ref)
        case .settings, .fishPocket:
            break
        }
    }

    /// The sign-in sheet's Fish Pocket way in, when this build has the service.
    private var fishPocketOption: (() -> Void)? {
        guard app.fishPocket.available else { return nil }
        return { fishPocketAfterOnboarding = true }
    }

    /// 「添加 API Key」 in the sign-in sheet hands over to the key editor once that sheet is gone.
    private func onboardingDismissed() {
        if fishPocketAfterOnboarding {
            fishPocketAfterOnboarding = false
            sheet = .fishPocket
            return
        }
        guard let ref = keyEditorRef else { return }
        keyEditorRef = nil
        onboarding = .key(ref: ref)
    }

    // MARK: Layouts

    private var split: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            // A width that follows the fold hangs the split view, on the one layout pass where
            // the window has turned and the width has not. These fit every pose.
            drawer.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
                .toolbar(.hidden, for: .navigationBar)
                .modifier(SidebarToggle(system: systemSidebarButton))
        } detail: {
            Group {
                if storeOpen {
                    NavigationStack { PluginStoreView(openSidebar: hideSidebar) }
                } else if botOpen {
                    botStack(openDrawer: hideSidebar)
                } else {
                    NavigationStack { conversation(openDrawer: hideSidebar) }
                }
            }
            .modifier(PastTheFold())
            // Every conversation in the detail, a Bot's chat too, can ask for the sidebar's room.
            .environment(\.splitSidebar, SplitSidebar(makeRoom: makeRoomForWorkbench))
        }
        // Side by side wherever both fit. Where they do not, the system keeps the sidebar
        // away and its button slides it over the conversation.
        .navigationSplitViewStyle(.balanced)
    }

    /// Whether the system's sidebar button stays. From iOS 27.1 it has to: removed, a split
    /// view too narrow for both columns (iPhone Duo open and held upright) has no way to put
    /// the sidebar away, and its layout never settles: the app hangs there and on the next
    /// rotation. Before that there is no such device, and the system's button cannot be
    /// counted on: with the sidebar away, iPadOS 26 shows none in the conversation's bar.
    private var systemSidebarButton: Bool {
        if #available(iOS 27.1, *) { true } else { false }
    }

    /// Our button puts a shown sidebar away. Where the system's button stays, a hidden one
    /// comes back with it, in the same place in the bar: one of the two at a time. Elsewhere
    /// ours does both.
    private var hideSidebar: (() -> Void)? {
        systemSidebarButton && sidebar == .detailOnly ? nil : toggleSidebar
    }

    private var windowCommands: WindowCommands {
        WindowCommands(
            newConversation: {
                sheet = nil
                storeOpen = false
                newConversation(in: workspace)
                setDrawer(false)
            },
            newWindow: supportsMultipleWindows ? { openWindow(id: DshIOSApp.window) } : nil,
            search: {
                sheet = nil
                if usesTabs {
                    // Search is the 会话 tab's own field: over the list where the list is under the
                    // conversation, beside it where it is wide (the conversation stays).
                    tab = .sessions
                    if sessionsSideBySide {
                        withAnimation { sessionsColumns = .all }
                    } else {
                        sessionsPath.removeAll()
                    }
                    searchRequest += 1
                    return
                }
                if layoutWidth == .regular { withAnimation { sidebar = .all } } else { setDrawer(true) }
                searchRequest += 1
            },
            toggleSidebar: toggleSidebar,
            openSettings: { sheet = .settings }
        )
    }

    private func toggleSidebar() {
        // On the tab bar the 会话 tab's list, where it is beside the conversation.
        if usesTabs {
            if sessionsSideBySide, tab == .sessions { toggleSessionsList() }
            return
        }
        if layoutWidth == .regular {
            withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
        } else {
            setDrawer(!drawerOpen)
        }
    }

    /// The workbench takes about 420 pt: under this much, the conversation would be left too little.
    private func makeRoomForWorkbench() {
        if windowWidth < 1100 { withAnimation { sidebar = .detailOnly } }
    }

    private var drawerLayout: some View {
        GeometryReader { geometry in
            let width = min(326, geometry.size.width - 64)
            // Closed, the drawer has to clear the leading safe area too: in landscape that strip
            // (the camera's side) is on screen, and the drawer's edge would show in it.
            let travel = width + geometry.safeAreaInsets.leading
            let progress = min(1, max(0, (drawerOpen ? 1 : 0) + drag / width))
            ZStack(alignment: .leading) {
                Group {
                    if botOpen {
                        botStack(openDrawer: { setDrawer(true) })
                    } else {
                        NavigationStack { conversation(openDrawer: { setDrawer(true) }) }
                    }
                }
                .accessibilityHidden(drawerOpen)
                Palette.scrim
                    .opacity(progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(progress > 0)
                    .onTapGesture { setDrawer(false) }
                    .accessibilityLabel("关闭侧边栏")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHidden(!drawerOpen)
                drawer
                    .frame(width: width)
                    .offset(x: (progress - 1) * travel)
                    .accessibilityHidden(!drawerOpen)
            }
            .background {
                DrawerEdgePan(enabled: !drawerOpen) { translation in
                    if drag == 0 { dismissKeyboard() }
                    drag = max(0, translation)
                } ended: { predicted in
                    settleDrawer(predicted: predicted, width: width)
                }
            }
            // A leftward swipe closes, from the dimmed side or anywhere in the drawer but a session
            // row (there it reveals the row's actions). It follows the finger and settles by distance
            // or speed. A recogniser that only begins sideways, not a drag gesture on this view: that
            // one ran through every scroll of the session list, and redrew this view as each began and ended.
            .background {
                DrawerClosePan(enabled: drawerOpen) { start in
                    start.x > width || !rowFrames.hasRow(atY: start.y)
                } changed: { translation in
                    drag = min(0, translation)
                } ended: { predicted in
                    if predicted == 0, drag != 0 {
                        withAnimation(.snappy(duration: 0.25)) { drag = 0 }
                    } else {
                        settleDrawer(predicted: predicted, width: width)
                    }
                }
            }
        }
    }

    private func settleDrawer(predicted: CGFloat, width: CGFloat) {
        guard drag != 0 else { return }
        let open = drawerOpen ? predicted > -width / 2 : predicted > width / 2
        if open != drawerOpen { Haptics.select() }
        withAnimation(.snappy(duration: 0.25)) {
            drawerOpen = open
            drag = 0
        }
    }

    /// Show `id` from wherever it was asked for: over a sheet it closes first.
    private func open(session id: String) {
        sheet = nil
        botOpen = false
        selection = id
        if usesTabs { showInTabs(id) }
        setDrawer(false)
    }

    /// 插件, from the sidebar or the new conversation page.
    private func openPlugins() {
        setDrawer(false)
        if usesTabs {
            sheet = nil
            tab = .explore
            if explorePath.last != .plugins { explorePath = [.plugins] }
        } else if layoutWidth == .regular { storeOpen = true } else { sheet = .store }
    }

    private func setDrawer(_ open: Bool) {
        if open { dismissKeyboard() }
        withAnimation(.snappy(duration: 0.25)) { drawerOpen = open }
    }

    private var drawer: some View { drawer(.sidebar) }

    private func drawer(_ style: DrawerView.Style) -> some View {
        DrawerView(
            selection: selection,
            workspace: workspace,
            rowFrames: rowFrames,
            pluginsSelected: storeOpen,
            select: { id in storeOpen = false; botOpen = false; selection = id; if usesTabs { showInTabs(id) }; setDrawer(false) },
            newConversation: { workspace in storeOpen = false; botOpen = false; workspaceId = workspace.id; newConversation(in: workspace); setDrawer(false) },
            openSettings: { sheet = .settings },
            openSchedules: { sheet = .schedules },
            openCordis: { sheet = .cordis },
            openSignIn: { sheet = .signIn },
            searchRequest: searchRequest,
            openInWindow: supportsMultipleWindows ? { openWindow(id: DshIOSApp.window, value: SessionWindow(session: $0)) } : nil,
            style: style
        )
    }

    // MARK: Tab bar

    /// The layout from iOS 18. Where the bar is at the bottom, a conversation, a Bot's chat or a
    /// group, pushed, hides it: their input sits where it would be.
    @available(iOS 18.0, *)
    private var tabLayout: some View {
        TabView(selection: $tab) {
            Tab(value: HomeTab.sessions) {
                if sessionsSideBySide { sessionsSplit } else { sessionsStack }
            } label: {
                tabLabel(Text(DrawerView.sessionsTitle), "bubble.left.and.bubble.right", .sessions)
            }
            .badge(waitingCount)
            Tab(value: HomeTab.bot) {
                botStack(openDrawer: nil)
            } label: {
                tabLabel(Text(verbatim: "Bot"), "face.smiling", .bot, filled: "face.smiling.inverse")
            }
            .badge(botPendingCount)
            // 我的应用: the user's own tools and games, opened as often as a home screen's.
            Tab(value: HomeTab.apps) {
                NavigationStack { MiniAppsPage(asTab: true) }
            } label: {
                tabLabel(Text(MiniAppsPage.tabTitle), "square.grid.2x2", .apps)
            }
            Tab(value: HomeTab.explore) {
                ExploreTabView(path: $explorePath)
            } label: {
                tabLabel(Text("探索"), "safari", .explore)
            }
            Tab(value: HomeTab.settings) {
                SettingsView(asTab: true)
            } label: {
                tabLabel(Text("设置"), "gearshape", .settings)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // iPhone Duo open keeps a column at its trailing edge for the bar buttons and the tab bar. The
        // system settles what goes there when the tab view is made: made folded, then opened, the
        // buttons of the conversation beside the list never show. Made again at each fold, it holds
        // everything that counts outside it (the tab, each tab's path, the conversation).
        .id(ThisDevice.isDuo ? layoutWidth : nil)
    }

    /// The 会话 tab where it is narrow: the list, with the conversation pushed over it.
    @available(iOS 18.0, *)
    private var sessionsStack: some View {
        NavigationStack(path: $sessionsPath) {
            drawer(.sessions)
                .navigationDestination(for: DrawerView.Route.self) { route in
                    switch route {
                    case .archived: drawer(.archived)
                    case .session(let id): pushedConversation(id).toolbar(.hidden, for: .tabBar)
                    }
                }
        }
    }

    /// The 会话 tab where it is wide: the list beside the conversation, which is always there, as the
    /// split view's: with none selected (at launch, after archiving) a blank one opens.
    @available(iOS 18.0, *)
    private var sessionsSplit: some View {
        NavigationSplitView(columnVisibility: $sessionsColumns) {
            drawer(.sessions)
                .navigationDestination(for: DrawerView.Route.self) { route in
                    switch route {
                    case .archived: drawer(.archived)
                    case .session(let id): pushedConversation(id)
                    }
                }
                // Widths as the split view's (`split`): a width that follows the fold hangs it.
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
                .modifier(SidebarToggle(system: systemSidebarButton))
        } detail: {
            NavigationStack {
                if let selection { pushedConversation(selection) } else { conversation(openDrawer: nil) }
            }
            .modifier(PastTheFold())
            // The list's button where the system's cannot be counted on (`systemSidebarButton`), and
            // room for the workbench.
            .environment(\.splitSidebar, SplitSidebar(makeRoom: makeRoomInSessions, toggle: sessionsListToggle))
        }
        .navigationSplitViewStyle(.balanced)
        // Only while this tab is in front: a conversation archived from another one does not pull it here.
        .task(id: selection == nil && !app.workspaces.isEmpty && tab == .sessions) {
            if selection == nil, !app.workspaces.isEmpty, tab == .sessions { newConversation(in: workspace) }
        }
    }

    /// The 会话 tab's list button in the conversation's bar, where the system's is removed
    /// (`systemSidebarButton`). From iOS 27.1 the system's is there, beside the list's own buttons
    /// and in the conversation's bar once the list is away: a second one would say the same.
    private var sessionsListToggle: (() -> Void)? {
        systemSidebarButton ? nil : toggleSessionsList
    }

    private func toggleSessionsList() {
        withAnimation { sessionsColumns = sessionsColumns == .detailOnly ? .all : .detailOnly }
    }

    /// The workbench takes about 420 pt: under this much, the list makes way for it, as the sidebar does.
    private func makeRoomInSessions() {
        if windowWidth < 1100 { withAnimation { sessionsColumns = .detailOnly } }
    }

    /// A tab's name and icon: outlined, and filled while it is the one in front. Left alone the
    /// system fills every icon that has a filled form, so it is told not to.
    private func tabLabel(_ title: Text, _ symbol: String, _ value: HomeTab, filled: String? = nil) -> some View {
        Label { title } icon: { Image(systemName: tab == value ? filled ?? "\(symbol).fill" : symbol) }
            .environment(\.symbolVariants, .none)
    }

    /// What the 会话 tab's list shows waiting on the user: this phone's conversations and those on
    /// the computers. The Bots' and the groups' sessions are left out, as the list leaves them out:
    /// they count on the Bot tab.
    private var waitingCount: Int {
        let team = app.botTeam
        let teamSessions = team.teamSessionIds
        let local = app.sessions.keys.filter { id in
            app.isWaiting(id) && !app.isArchived(id) && !teamSessions.contains(id)
                && (team.teamWorkspaceId == nil || app.workspace(of: id)?.id != team.teamWorkspaceId)
        }
        let remote = app.remote.signedIn ? app.remote.listed().filter { $0.deviceOnline && $0.waiting }.count : 0
        return local.count + remote
    }

    /// What the Bots wait on the user for, on the Bot tab.
    private var botPendingCount: Int {
        let team = app.botTeam
        return team.bots.reduce(0) { $0 + team.pendingCount(of: $1) }
    }

    /// A conversation on the 会话 tab's stack. Back is the system's; there is no drawer to open.
    @ViewBuilder
    private func pushedConversation(_ id: String) -> some View {
        if let remote = RemoteStore.sessionId(of: id) {
            RemoteConversationView(sessionId: remote, selection: $selection, openDrawer: nil)
                .id(id)
        } else {
            ConversationView(sessionId: id, selection: $selection, openDrawer: nil, switchWorkspace: { workspace in
                workspaceId = workspace.id
                newConversation(in: workspace)
            })
            .id(id)
        }
    }

    /// The session on screen: a Bot's chat or a group when the Bot pages are open, else the conversation.
    private var onScreen: String? {
        guard botOpen else { return selection }
        switch botPath.last {
        case .bot(let id): return app.botTeam.bot(id)?.sessionId ?? "bot:\(id)"
        case .room(let id): return app.botTeam.room(id)?.sessionId ?? "room:\(id)"
        case nil: return "bots"
        }
    }

    /// The Bot list, with a Bot's chat or a group pushed on it.
    private func botStack(openDrawer: (() -> Void)?) -> some View {
        NavigationStack(path: $botPath) {
            BotHomeView(openDrawer: openDrawer)
                .navigationDestination(for: BotRoute.self) { route in
                    Group {
                        switch route {
                        case .bot(let id): BotChatView(botId: id)
                        case .room(let id): BotRoomView(roomId: id)
                        }
                    }
                    // Set here as well: what the split view sets does not reach a pushed page. A pushed
                    // chat has a back button where the conversation has its sidebar button, so the
                    // sidebar's goes beside it.
                    .environment(\.splitSidebar, SplitSidebar(makeRoom: makeRoomForWorkbench, toggle: layoutWidth == .regular ? hideSidebar : nil))
                    // iPhone Duo open: no inspector on a pushed chat (see `workbenchInSheet`).
                    .environment(\.workbenchInSheet, usesTabs && ThisDevice.isDuo)
                    // Its input takes the bar's place where the bar is at the bottom.
                    .toolbar(usesTabs && layoutWidth != .regular ? .hidden : .automatic, for: .tabBar)
                }
        }
    }

    @ViewBuilder
    private func conversation(openDrawer: (() -> Void)?) -> some View {
        if let selection, let remote = RemoteStore.sessionId(of: selection) {
            RemoteConversationView(sessionId: remote, selection: $selection, openDrawer: openDrawer)
                .id(selection)
        } else if let selection {
            ConversationView(sessionId: selection, selection: $selection, openDrawer: openDrawer, switchWorkspace: { workspace in
                workspaceId = workspace.id
                newConversation(in: workspace)
            })
            .id(selection)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.background)
                .toolbar { if let openDrawer { ToolbarItem(placement: .navigationBarLeading) { DrawerButton(action: openDrawer) } } }
        }
    }

    /// `dsh://session/<id>` opens the session; `dsh://new` a new conversation with the keyboard up,
    /// once the workspaces are known and the launch's own blank conversation is in place.
    private func follow(_ link: DshLink) async {
        // Taken already (by another window, or found waiting as the app came to the front): nothing to do.
        var shared: ShareInbox.Taken?
        if case .share(let id) = link {
            shared = ShareInbox.take(id)
            if shared == nil { return }
        }
        sheet = nil
        storeOpen = false
        setDrawer(false)
        switch link {
        case .session(let id):
            // A computer's session from the lock screen or a widget, after signing out: nothing to open.
            if RemoteStore.sessionId(of: id) != nil, !app.remote.signedIn { return }
            selection = id
            if usesTabs { showInTabs(id) }
        case .new(let workspaceId, let preset, let draft):
            let deadline = ContinuousClock.now + .seconds(10)
            while app.workspaces.isEmpty || creating, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let target = workspaceId.flatMap { id in app.workspaces.first { $0.id == id } } ?? workspace
            if let target { self.workspaceId = target.id }
            newConversation(in: target, agentPreset: preset, draft: draft, focus: true)
        case .share:
            if let shared { await receive(shared) }
        case .app(let id):
            MiniAppPresenter.open(id)
        }
    }

    /// What another app shared (the share extension): into the composer of the Bot, the group or
    /// the new conversation picked there, keyboard up, nothing sent.
    private func receive(_ shared: ShareInbox.Taken) async {
        let files = shared.files.isEmpty ? nil : SharedFiles(urls: shared.files, folder: shared.folder)
        if files == nil { try? FileManager.default.removeItem(at: shared.folder) }
        if case .bot(let botId) = shared.target {
            // A cold launch: the team arrives a moment after the engine.
            let deadline = ContinuousClock.now + .seconds(10)
            while app.botTeam.bot(botId) == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let bot = app.botTeam.bot(botId), !bot.sessionId.isEmpty {
                deliver(text: shared.text, files: files, to: bot.sessionId)
                app.botTeam.openRequest = BotOpenRequest(route: .bot(botId))
                return
            }
            app.showToast(String(localized: "找不到这个 Bot 了，内容放进了新对话"), tone: .warning)
        }
        if case .room(let roomId) = shared.target {
            let deadline = ContinuousClock.now + .seconds(10)
            while app.botTeam.room(roomId) == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let room = app.botTeam.room(roomId), !room.sessionId.isEmpty {
                deliver(text: shared.text, files: files, to: room.sessionId)
                app.botTeam.openRequest = BotOpenRequest(route: .room(roomId))
                return
            }
            app.showToast(String(localized: "找不到这个群聊了，内容放进了新对话"), tone: .warning)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while app.workspaces.isEmpty || creating, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        launchedUnderBot = false
        botOpen = false
        newConversation(in: workspace, draft: shared.text, files: files, focus: true)
    }

    /// Text and files waiting for a session's composer, which takes them when it shows.
    private func deliver(text: String?, files: SharedFiles?, to id: String) {
        if let text { app.pendingDrafts[id] = text }
        if let files { app.pendingFiles[id] = files }
        app.pendingFocus.insert(id)
    }

    /// Open a blank conversation in `workspace` (the engine reuses a blank one there).
    private func newConversation(in workspace: Workspace?, agentPreset: String? = nil, draft: String? = nil, files: SharedFiles? = nil, prompt: String? = nil, focus: Bool = false) {
        guard let workspace, !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let id = try await app.createSession(in: workspace, agentPreset: agentPreset)
                if let draft { app.pendingDrafts[id] = draft }
                if let files { app.pendingFiles[id] = files }
                if let prompt { app.pendingPrompts[id] = prompt }
                if focus { app.pendingFocus.insert(id) }
                selection = id
                // The engine may hand back the blank conversation already selected: shown all the same.
                if usesTabs { showInTabs(id) }
            }
            catch {
                if let files { try? FileManager.default.removeItem(at: files.folder) }
                app.showToast(String(localized: "新建会话失败：\(error.localizedDescription)"), tone: .warning, duration: 6)
            }
        }
    }
}

/// On the sidebar column: the system's sidebar button, kept or removed (`systemSidebarButton`).
private struct SidebarToggle: ViewModifier {
    let system: Bool

    func body(content: Content) -> some View {
        if system { content } else { content.toolbar(removing: .sidebarToggle) }
    }
}

/// iPhone Duo held partly open like a book, the sidebar on the near page: the column beside
/// it starts on the far page, so nothing in it is read across the fold. A column the fold
/// cuts down the middle (the sidebar is away) stays whole: half a display would be left empty.
private struct PastTheFold: ViewModifier {
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, inset)
            .background(Palette.background)
            .onGeometryChangeCompat(for: CGFloat.self) { proxy in
                guard let fold = proxy.fold, fold.height > fold.width, fold.midX < proxy.size.width / 2 else { return 0 }
                return max(0, fold.maxX)
            } action: { inset = $0 }
    }
}

/// A navigation stack with a close button, for a list presented on its own.
struct SheetStack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WithPerceptionTracking {

        NavigationStack { content.closeButton(dismiss) }
    
        }}
}

/// A leftward swipe over the open drawer, reported as it follows the finger. It begins only for
/// a swipe that sets off sideways, to the left, from a point `accepts`: a scroll of the session
/// list never starts it, so nothing here runs while the list scrolls. On the root view, as
/// `DrawerEdgePan` is: pages presented above keep their own gestures.
private struct DrawerClosePan: UIViewRepresentable {
    let enabled: Bool
    /// Whether a swipe that started here (in the window) may close the drawer.
    let accepts: (CGPoint) -> Bool
    let changed: (CGFloat) -> Void
    /// Where the swipe would come to rest; 0 when it was cancelled.
    let ended: (CGFloat) -> Void

    func makeUIView(context: Context) -> Catcher { Catcher() }

    func updateUIView(_ view: Catcher, context: Context) {
        view.enabled = enabled
        view.accepts = accepts
        view.changed = changed
        view.ended = ended
    }

    final class Catcher: UIView, UIGestureRecognizerDelegate {
        var enabled = false
        var accepts: (CGPoint) -> Bool = { _ in true }
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat) -> Void = { _ in }
        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned))
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.rootViewController?.view.addGestureRecognizer(recognizer)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let view = recognizer.view else { return false }
            let velocity = recognizer.velocity(in: view)
            guard velocity.x < 0, abs(velocity.x) > abs(velocity.y) else { return false }
            let now = recognizer.location(in: view), moved = recognizer.translation(in: view)
            return accepts(CGPoint(x: now.x - moved.x, y: now.y - moved.y))
        }

        /// The list under the finger keeps its own pan; everything else gives way once this one begins.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .began, .changed: changed(translation)
            case .ended: ended(translation + recognizer.velocity(in: recognizer.view).x * 0.2)
            default: ended(0)
            }
        }
    }
}

/// A swipe from the screen's left edge, reported as it follows the finger. On the root view:
/// sheets above it keep their own edges.
private struct DrawerEdgePan: UIViewRepresentable {
    let enabled: Bool
    let changed: (CGFloat) -> Void
    /// Where the swipe would come to rest; 0 when it was cancelled.
    let ended: (CGFloat) -> Void

    func makeUIView(context: Context) -> Catcher { Catcher() }

    func updateUIView(_ view: Catcher, context: Context) {
        view.enabled = enabled
        view.changed = changed
        view.ended = ended
    }

    final class Catcher: UIView, UIGestureRecognizerDelegate {
        var enabled = true
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat) -> Void = { _ in }
        private lazy var recognizer: UIScreenEdgePanGestureRecognizer = {
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned))
            recognizer.edges = .left
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.rootViewController?.view.addGestureRecognizer(recognizer)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { enabled }

        @objc private func panned(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .began, .changed: changed(translation)
            case .ended: ended(translation + recognizer.velocity(in: recognizer.view).x * 0.2)
            default: ended(0)
            }
        }
    }
}
