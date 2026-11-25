import AppIntents

/// What Siri and the Shortcuts app offer without any setup. The phrases are
/// translated in AppShortcuts.xcstrings; each must name the app. The phrases that name a Bot or a
/// Mini App follow the lists the app last wrote: `updateAppShortcutParameters()` runs when they change.
/// 打开 Mini App and 打开网页版 are also how a Mini App or the 网页版 goes on the home screen
/// without a web page on the way (添加到主屏幕 → 快捷指令, `AddToHomeScreenSheet`).
struct DshShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewConversationIntent(),
            phrases: [
                "用 \(.applicationName) 新建对话",
                "在 \(.applicationName) 里开始新对话",
                "\(.applicationName) 新对话",
            ],
            shortTitle: "新对话",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenBotIntent(),
            phrases: [
                "用 \(.applicationName) 打开 \(\.$bot)",
                "在 \(.applicationName) 里和 \(\.$bot) 聊天",
                "打开 \(.applicationName) 的 Bot",
            ],
            shortTitle: "打开 Bot",
            systemImageName: "person.crop.circle"
        )
        AppShortcut(
            intent: OpenMiniAppIntent(),
            phrases: [
                "用 \(.applicationName) 打开 \(\.$app)",
                "打开 \(.applicationName) 的 Mini App",
            ],
            shortTitle: "打开 Mini App",
            systemImageName: "square.on.circle"
        )
        AppShortcut(
            intent: OpenWebIntent(),
            phrases: [
                "用 \(.applicationName) 打开网页版",
                "打开 \(.applicationName) 网页版",
            ],
            shortTitle: "打开网页版",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: ShowBalanceIntent(),
            phrases: [
                "查看 \(.applicationName) 余额",
                "\(.applicationName) 还剩多少余额",
            ],
            shortTitle: "查看余额",
            systemImageName: "creditcard"
        )
    }
}
