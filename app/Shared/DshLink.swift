import Foundation

/// The app's `fishpocket://` links: the Live Activity and the widgets open them, `RootView` reads them.
/// `dsh://` links, from before the app had a scheme of its own, still open the same pages.
///
/// - `fishpocket://session/<id>`: open that session.
/// - `fishpocket://new`: a new conversation, focused; `workspace`, `preset` and `draft` are
///   optional query items. A draft is placed in the composer, never sent.
/// - `fishpocket://share/<id>`: what the share extension left in `ShareInbox`, into the composer it chose.
/// - `fishpocket://app/<id>`: an app of 我的应用, opened full screen; it needs no engine.
/// - `fishpocket://web`: the 网页版, opened full screen; its home-screen icon (`HomeScreenShortcut`) opens it.
/// - `fishpocket://bot/<id>`: that Bot's chat (Shortcuts).
/// - `fishpocket://balance`: the page with the balance of the account in use (Shortcuts).
/// - `fishpocket://call`: the voice call on now, full screen (its Live Activity opens it).
enum DshLink: Hashable {
    case session(String)
    case new(workspace: String? = nil, preset: String? = nil, draft: String? = nil)
    case share(String)
    case app(String)
    case web
    case bot(String)
    case balance
    case call

    /// `DshURLScheme` in Info.plist (`DSH_URL_SCHEME` in project.yml): `fishpocket`, or a test
    /// build's own. Every link the app makes uses it.
    static let scheme = Bundle.main.object(forInfoDictionaryKey: "DshURLScheme") as? String ?? "fishpocket"

    /// `DshLegacyURLScheme` (`DSH_LEGACY_URL_SCHEME`): `dsh`, read but never made, so old home-screen
    /// icons, Shortcuts and links in old chats keep working. Empty in a test build; only the app has it.
    static let legacyScheme = (Bundle.main.object(forInfoDictionaryKey: "DshLegacyURLScheme") as? String)
        .flatMap { $0.isEmpty ? nil : $0 }

    /// The schemes the app answers to.
    static let schemes = [scheme] + [legacyScheme].compactMap { $0 }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme), let host = url.host() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch host {
        case "session":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return nil }
            self = .session(id)
        case "new":
            self = .new(workspace: item("workspace"), preset: item("preset"), draft: item("draft"))
        case "share":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return nil }
            self = .share(id)
        case "app":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return nil }
            self = .app(id)
        case "web":
            self = .web
        case "bot":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return nil }
            self = .bot(id)
        case "balance":
            self = .balance
        case "call":
            self = .call
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .session(let id):
            components.host = "session"
            components.path = "/" + id
        case .new(let workspace, let preset, let draft):
            components.host = "new"
            let items = [("workspace", workspace), ("preset", preset), ("draft", draft)]
                .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            if !items.isEmpty { components.queryItems = items }
        case .share(let id):
            components.host = "share"
            components.path = "/" + id
        case .app(let id):
            components.host = "app"
            components.path = "/" + id
        case .web:
            components.host = "web"
        case .bot(let id):
            components.host = "bot"
            components.path = "/" + id
        case .balance:
            components.host = "balance"
        case .call:
            components.host = "call"
        }
        return components.url!
    }
}
