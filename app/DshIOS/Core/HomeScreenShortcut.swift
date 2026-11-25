import SwiftUI
import UIKit

/// Puts an icon on the home screen through Safari. Offered nowhere for now: 添加到主屏幕 gives the
/// widget and the shortcut only, which go straight into the app. The icons people already added
/// keep working (`DshLink` takes both schemes, the website's page stays).
///
/// iOS lets no app place an icon there itself, but Safari's 添加到主屏幕 does for a web page: the website's page (AppLinks.addToHomeScreen) takes the
/// name and icon from what follows its `#`, and when opened from the home screen goes on to one of
/// the app's links: `fishpocket://app/<id>` for an app of 我的应用 (`id=`), `fishpocket://web` for the 网页版
/// (`to=web`). The fragment never reaches the server. The icon is drawn here: Safari's canvas does
/// not draw emoji.
@MainActor
enum HomeScreenShortcut {
    static func add(name: String, items: [URLQueryItem], icon: some View) {
        var fragment = URLComponents()
        fragment.queryItems = items + [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "scheme", value: DshLink.scheme),
        ] + [png(icon).map { URLQueryItem(name: "img", value: $0) }].compactMap { $0 }
        // The page reads it with URLSearchParams, where a bare + is a space.
        let encoded = (fragment.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        guard var components = URLComponents(url: AppLinks.addToHomeScreen, resolvingAgainstBaseURL: false) else { return }
        components.percentEncodedFragment = encoded
        guard let url = components.url else { return }
        Haptics.tap()
        UIApplication.shared.open(url)
    }

    /// The 网页版: tapping the icon opens the app straight on it.
    static func addWeb() {
        add(name: String(localized: "网页版"), items: [URLQueryItem(name: "to", value: "web")], icon: WebIcon())
    }

    /// The icon, 180 points square and edge to edge (iOS rounds the corners), as base64url PNG.
    private static func png(_ icon: some View) -> String? {
        let renderer = ImageRenderer(content: icon.frame(width: 180, height: 180).clipped())
        renderer.scale = 1
        guard let data = renderer.uiImage?.pngData() else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// 添加到主屏幕: the ways onto the home screen, side by side: a widget and a Shortcuts icon
/// (`DshShortcuts`), both straight into the app. No app may add either itself, so they are told,
/// not done. Safari's icon (`HomeScreenShortcut`), which loads the website's page each time, is not
/// offered any more.
struct AddToHomeScreenSheet: View {
    enum Target: Identifiable {
        case miniApp(MiniApp)
        case web

        var id: String {
            switch self {
            case .miniApp(let app): "app:" + app.id
            case .web: "web"
            }
        }
    }

    let target: Target
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                way("小组件", systemImage: "rectangle.3.group", text: widgetText)
                way(
                    "快捷指令",
                    systemImage: "square.2.layers.3d",
                    text: shortcutText,
                    button: "新建快捷指令"
                ) {
                    // Straight into a new shortcut's editor.
                    if let url = URL(string: "shortcuts://create-shortcut") { openURL(url) }
                }
            }
            .navigationTitle("添加到主屏幕")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        .settingsStyle()
    }

    private var shortcutText: String {
        switch target {
        case .miniApp: String(localized: "点开直接进入，不经过网页。新建一个快捷指令，添加 Fish Pocket 的「打开 Mini App」动作并选上这个 Mini App，再点顶部的名称，选「添加到主屏幕」。")
        case .web: String(localized: "点开直接进入，不经过网页。新建一个快捷指令，添加 Fish Pocket 的「打开网页版」动作，再点顶部的名称，选「添加到主屏幕」。")
        }
    }

    private var widgetText: String {
        switch target {
        case .miniApp: String(localized: "点开直接进入，不经过网页。长按主屏幕空白处，添加小组件，搜索 Fish Pocket，选「Mini Apps」。小号的放一个，加好后长按它，选「编辑小组件」挑这个 Mini App。")
        case .web: String(localized: "点开直接进入，不经过网页。长按主屏幕空白处，添加小组件，搜索 Fish Pocket，选「网页版」。")
        }
    }

    private func way(_ title: LocalizedStringKey, systemImage: String, text: String, button: LocalizedStringKey? = nil, action: @escaping () -> Void = {}) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                if let button {
                    Button(button, action: action)
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The app's icon as the user picked it, with a globe: the same app, opened on its 网页版. The
/// badge sits clear of the corners the home screen rounds off.
private struct WebIcon: View {
    var body: some View {
        Image(AppIconChoice.current.preview)
            .resizable()
            .scaledToFill()
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "globe")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(Color(red: 0.04, green: 0.52, blue: 1)))
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                    .padding(14)
            }
    }
}
