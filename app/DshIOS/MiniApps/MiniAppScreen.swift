import Perception
import SwiftUI
import WebKit

/// Opens an app of 我的应用 full screen over whatever is in front: a chat, a sheet, or the
/// startup screen when a widget launched the app (an app needs no engine).
@MainActor
enum MiniAppPresenter {
    private static weak var current: UIViewController?

    static func open(_ id: String) {
        guard let app = MiniAppStore.shared.app(id) else {
            Haptics.warning()
            return
        }
        MiniAppStore.shared.noteOpened(id)
        func present(tries: Int = 10) {
            // A cold launch from a widget: the window may not be up yet.
            guard let top = topController() else {
                if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { present(tries: tries - 1) } }
                return
            }
            let controller = UIHostingController(rootView: MiniAppScreen(app: app, close: { close() }))
            controller.modalPresentationStyle = .fullScreen
            current = controller
            top.present(controller, animated: true)
        }
        if let current, current.presentingViewController != nil {
            current.dismiss(animated: false) { present() }
        } else {
            present()
        }
    }

    static func close(then next: (() -> Void)? = nil) {
        guard let current, current.presentingViewController != nil else { next?(); return }
        current.dismiss(animated: true, completion: next)
    }

    /// Close the app and start a new conversation with `draft` in the composer.
    static func askAgent(_ draft: String) {
        close { LinkInbox.shared.request = LinkRequest(link: .new(draft: draft)) }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    static func editDraft(_ app: MiniApp) -> String {
        // The path is followed by a space: a `/` token at the end of the draft opens the command menu.
        String(localized: "修改 \(app.enginePath) 里的小工具「\(app.name)」：")
    }

    static func fixDraft(_ app: MiniApp, error: String) -> String {
        String(localized: "\(app.enginePath) 里的小工具「\(app.name)」运行时出错了：\n\n\(error)\n\n帮我修好。")
    }
}

struct MiniAppScreen: View {
    let app: MiniApp
    let close: () -> Void
    @State private var page = MiniAppPage()
    /// The published copy is in place (made now the first time, or after the agent changed it).
    @State private var ready = false

    var body: some View {
        NavigationStack {
            Group {
                if ready { MiniAppWebView(page: page, app: app) } else { Color(uiColor: .systemBackground) }
            }
                .task {
                    await MiniAppPublisher.shared.prepare(app, agentBusy: MiniAppPublisher.agentBusy)
                    ready = true
                }
                // Down to the screen's edge: the page's own background fills the home indicator's strip.
                .ignoresSafeArea(.container, edges: .bottom)
                .background(Color(uiColor: .systemBackground))
                // The app's icon until its page is in: the web view's own start is a blank screen.
                .overlay {
                    if !page.loaded {
                        ZStack {
                            Color(uiColor: .systemBackground)
                            MiniAppIcon(icon: app.icon, color: app.color, size: 76)
                        }
                        .ignoresSafeArea(.container, edges: .bottom)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let error = page.error { errorBanner(error) }
                }
                .navigationTitle(app.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Menu {
                            Button("重新载入", systemImage: "arrow.clockwise") { page.reload() }
                            Button("让 Agent 修改", systemImage: "wand.and.stars") { MiniAppPresenter.askAgent(MiniAppPresenter.editDraft(app)) }
                            Button("添加到主屏幕", systemImage: "plus.square.on.square") { MiniAppHomeScreen.add(app) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("更多")
                        Button(action: close) { Image(systemName: "xmark") }
                            .accessibilityLabel("关闭")
                    }
                }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行出错").font(.subheadline.weight(.semibold))
                    Text(error).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(3)
                }
                Spacer(minLength: 0)
                Button { withAnimation { page.error = nil } } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary).hitTarget()
                }
                .accessibilityLabel("关闭")
            }
            Button {
                MiniAppPresenter.askAgent(MiniAppPresenter.fixDraft(app, error: page.errors.joined(separator: "\n")))
            } label: {
                Label("让 Agent 修复", systemImage: "wand.and.stars").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.ink)
            .foregroundStyle(Palette.onInk)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// What the page reported, and a way to reload it.
@MainActor @Perceptible
final class MiniAppPage {
    /// The latest error, shown until dismissed; nil once the user closes the banner.
    var error: String?
    /// The page has loaded (the launch screen goes).
    var loaded = false
    /// Every error since the page loaded, for the agent.
    private(set) var errors: [String] = []
    @PerceptionIgnored weak var webView: WKWebView?

    func report(_ message: String) {
        guard !errors.contains(message) else { return }
        if errors.count < 10 { errors.append(message) }
        withAnimation { error = message }
    }

    func reload() {
        errors = []
        error = nil
        webView?.reload()
    }
}

/// The app's page in a web view of its own: its own storage, nothing of the user's sign-ins,
/// and no way to the engine on this phone. It may use the network.
private struct MiniAppWebView: UIViewRepresentable {
    let page: MiniAppPage
    let app: MiniApp

    func makeCoordinator() -> Coordinator { Coordinator(page: page, appId: app.id) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if #available(iOS 17.0, *) {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: app.dataStoreId)
        } else {
            configuration.websiteDataStore = .default()
        }
        configuration.setURLSchemeHandler(MiniAppServer(app: app), forURLScheme: MiniAppServer.scheme)
        configuration.userContentController.add(context.coordinator.messages, name: MiniAppServer.messageName)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        #if DEBUG
        view.isInspectable = true
        #endif
        page.webView = view
        let url = URL(string: "\(MiniAppServer.scheme)://\(app.id)/")!
        Task {
            if let rules = await LocalNetworkRules.list { configuration.userContentController.add(rules) }
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: MiniAppServer.messageName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let messages: Messages
        let appId: String

        init(page: MiniAppPage, appId: String) {
            messages = Messages(page: page)
            self.appId = appId
        }

        /// The content controller keeps its handlers: this one holds the page weakly.
        final class Messages: NSObject, WKScriptMessageHandler {
            weak var page: MiniAppPage?
            init(page: MiniAppPage) { self.page = page }

            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let text = message.body as? String else { return }
                MainActor.assumeIsolated { page?.report(text) }
            }
        }

        /// The app's own pages stay here; a web page opens over it in Safari, and other links
        /// (mail, phone) go to the system. Frames may load anything.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == MiniAppServer.scheme {
                return decisionHandler(url.host() == appId ? .allow : .cancel)
            }
            if action.targetFrame?.isMainFrame == false || url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            if url.scheme == "http" || url.scheme == "https" { InAppSafari.open(url) } else { UIApplication.shared.open(url) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, url.scheme == "http" || url.scheme == "https" { InAppSafari.open(url) }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A moment for the modules the page imports to run and draw.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let page = self?.messages.page, !page.loaded else { return }
                withAnimation(.easeOut(duration: 0.2)) { page.loaded = true }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { messages.page?.loaded = true }
            let ns = error as NSError
            guard ns.code != NSURLErrorCancelled else { return }
            MainActor.assumeIsolated { messages.page?.report(error.localizedDescription) }
        }

        // No camera or microphone in this version.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default) { _ in completionHandler() })
            present(alert, from: webView) ?? completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default) { _ in completionHandler(true) })
            present(alert, from: webView) ?? completionHandler(false)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text ?? "") })
            present(alert, from: webView) ?? completionHandler(nil)
        }

        /// Nil when there is nothing to present from.
        private func present(_ alert: UIAlertController, from view: UIView) -> Void? {
            var responder: UIResponder? = view
            while let next = responder?.next, !(next is UIViewController) { responder = next }
            guard var controller = responder?.next as? UIViewController else { return nil }
            while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
            controller.present(alert, animated: true)
            return ()
        }
    }
}

/// Blocks requests to this phone itself (localhost, 127.x, ::1): servers the engine and its
/// plugins run there are not an app's business.
@MainActor
private enum LocalNetworkRules {
    private static var compiled: Task<WKContentRuleList?, Never>?

    static var list: WKContentRuleList? {
        get async {
            if compiled == nil {
                compiled = Task {
                    let filters = [#"^[a-z]+://localhost[:/]"#, #"^[a-z]+://127\.[0-9.]+[:/]"#, #"^[a-z]+://\[::1\][:/]"#, #"^[a-z]+://0\.0\.0\.0[:/]"#]
                    let rules = filters.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
                    guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
                    return try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "fishapp-local-network", encodedContentRuleList: String(decoding: data, as: UTF8.self))
                }
            }
            return await compiled?.value
        }
    }
}

/// Puts an app on the home screen through Safari. iOS lets no app place an icon there itself, but
/// Safari's 添加到主屏幕 does for a web page: the website's page (AppLinks.addToHomeScreen) takes the
/// app's name and icon from what follows its `#`, and when opened from the home screen goes on to
/// `dsh://app/<id>`. The fragment never reaches the server. The icon is drawn here, as the 应用 tab
/// draws it: Safari's canvas does not draw emoji.
@MainActor
enum MiniAppHomeScreen {
    static func add(_ app: MiniApp) {
        var fragment = URLComponents()
        fragment.queryItems = [
            URLQueryItem(name: "id", value: app.id),
            URLQueryItem(name: "name", value: app.name),
            URLQueryItem(name: "color", value: String(app.color.drop { $0 == "#" })),
            URLQueryItem(name: "scheme", value: DshLink.scheme),
        ] + [iconPNG(app).map { URLQueryItem(name: "img", value: $0) }].compactMap { $0 }
        // The page reads it with URLSearchParams, where a bare + is a space.
        let encoded = (fragment.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        guard var components = URLComponents(url: AppLinks.addToHomeScreen, resolvingAgainstBaseURL: false) else { return }
        components.percentEncodedFragment = encoded
        guard let url = components.url else { return }
        Haptics.tap()
        UIApplication.shared.open(url)
    }

    /// The home screen's icon, 180 points square and edge to edge (iOS rounds the corners), as
    /// base64url PNG.
    private static func iconPNG(_ app: MiniApp) -> String? {
        let icon = ZStack {
            Rectangle().fill(Color(miniApp: app.color).gradient)
            Text(verbatim: app.icon).font(.system(size: 90))
        }
        .frame(width: 180, height: 180)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let data = renderer.uiImage?.pngData() else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
