import Foundation

/// When to ask for a rating or a share, after Orca's star nag: only right after a turn
/// went well, a few turns in, and rarely; each ask starts the same wait, three days and the
/// turns again. An App Store install is asked for a rating alone, once a version (Apple decides
/// whether the sheet shows, and says nothing either way); the card is left to 设置 there.
/// Other installs get the card instead (rate on the App Store first, share, and a quiet line to the
/// repository, which leaves the card up): an ignored one waits twice the turns, the third is the
/// last, and rating or sharing settles it, as nothing here can tell who has rated.
@MainActor
enum SupportPrompt {
    enum Ask { case review, support }

    private static let turnsKey = "dsh.support.turns"
    private static let asksKey = "dsh.support.asks"
    private static let notBeforeKey = "dsh.support.notBefore"
    private static let settledKey = "dsh.support.settled"
    private static let reviewedKey = "dsh.support.reviewedVersion"

    private static let firstAsk = 5
    private static let lastAsk = 3
    private static let cooldown: TimeInterval = 3 * 24 * 60 * 60

    /// Counts a turn that finished well; true when an ask is due.
    static func noteCompletedTurn() -> Bool {
        guard reviewOpen || supportOpen else { return false }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: turnsKey) + 1, forKey: turnsKey)
        return due != nil
    }

    /// The ask to make now: each is spent here, whatever becomes of it.
    static func take() -> Ask? {
        guard let ask = due else { return nil }
        let defaults = UserDefaults.standard
        switch ask {
        case .review: defaults.set(version, forKey: reviewedKey)
        case .support: defaults.set(defaults.integer(forKey: asksKey) + 1, forKey: asksKey)
        }
        defaults.set(0, forKey: turnsKey)
        defaults.set(Date.now.addingTimeInterval(cooldown).timeIntervalSince1970, forKey: notBeforeKey)
        return ask
    }

    /// They went to the App Store or the share page: never show the card again.
    static func settle() { UserDefaults.standard.set(true, forKey: settledKey) }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var reviewOpen: Bool {
        AppDistribution.channel == .appStore && UserDefaults.standard.string(forKey: reviewedKey) != version
    }

    private static var supportOpen: Bool {
        let defaults = UserDefaults.standard
        return AppDistribution.channel != .appStore
            && !defaults.bool(forKey: settledKey) && defaults.integer(forKey: asksKey) < lastAsk
    }

    private static var due: Ask? {
        let defaults = UserDefaults.standard
        guard Date.now.timeIntervalSince1970 >= defaults.double(forKey: notBeforeKey) else { return nil }
        let turns = defaults.integer(forKey: turnsKey)
        if reviewOpen && turns >= firstAsk { return .review }
        if supportOpen && turns >= firstAsk << defaults.integer(forKey: asksKey) { return .support }
        return nil
    }
}

/// The app's links, and the message that passes them on.
enum AppLinks {
    static let repository = URL(string: "https://github.com/\(UpdateChecker.repository)")!
    /// The website, which sends each reader on to the App Store or the public beta.
    static let site = URL(string: "https://fish.deepseek1024.com")!
    /// The app's App Store page, with no storefront so each reader lands in their own. The share
    /// poster's QR code is a picture of this link: scripts/make-share-qr.swift redraws it.
    static let appStore = URL(string: "https://apps.apple.com/app/id6830703602")!
    /// The same page with the App Store's review sheet already open.
    static let appStoreReview = URL(string: "https://apps.apple.com/app/id6830703602?action=write-review")!
    /// The WeChat group's QR code at the foot of the 探索 tab. It expires every 7 days; the website swaps
    /// the picture at this same path, so the app always shows the current one without an update.
    static let wechatGroupCode = site.appending(path: "wechat-group.png")
    /// The community's Discord server, next to the WeChat group.
    static let discord = URL(string: "https://discord.gg/VSzN4jUwWm")!
    /// 本机能力 → 操控其他 App: installing iCTRL (SideStore, iLoader, Developer Mode) and its FAQ.
    /// The page lives on the website so it can follow those tools' releases without an app update.
    /// Chinese at /phone-control/, the site's other languages under their prefix; English for the rest.
    static var phoneControlGuide: URL {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let prefix = language.hasPrefix("zh") ? "" : ["ja", "ko"].first { language.hasPrefix($0) } ?? "en"
        return site.appending(path: prefix.isEmpty ? "phone-control/" : "\(prefix)/phone-control/")
    }
    /// 我的应用 › 添加到主屏幕: the page Safari puts an app on the home screen from (`MiniAppHomeScreen`).
    /// Installed apps all open this path, so it stays where it is on the website.
    static var addToHomeScreen: URL {
        #if DEBUG
        // UI checks against a local copy of the website: `-dshSiteURL http://localhost:8099`.
        if let local = UserDefaults.standard.string(forKey: "dshSiteURL").flatMap(URL.init(string:)) {
            return local.appending(path: "add-to-home/")
        }
        #endif
        return site.appending(path: "add-to-home/")
    }

    /// What 「链接」 on the share page sends.
    static var shareText: String {
        String(localized: "Fish Pocket：在 iPhone 和 iPad 上本机运行 DeepSeek Harness，支持第三方插件市场，不连电脑，不连服务器。\n\(site.absoluteString)")
    }
}
