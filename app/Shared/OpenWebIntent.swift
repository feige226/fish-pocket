import AppIntents

/// Opens the 网页版. Added to the home screen from Shortcuts, it goes straight into the app, with
/// no web page on the way (`HomeScreenShortcut` is the other way, through Safari).
struct OpenWebIntent: AppIntent {
    static var title: LocalizedStringResource = "打开网页版"
    static var description = IntentDescription("打开 Fish Pocket 的网页版。在快捷指令里把它添加到主屏幕，点一下就进入。")
    static var openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DshIntentBridge.open?(.web)
        return .result()
    }
}
