import ActivityKit
import AppIntents
import Foundation

/// A voice call on the lock screen and in the Dynamic Island, while the app is out of sight or
/// the call is minimized: who is on the line, what the call is doing, how long it has lasted,
/// and buttons to mute and to hang up.
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case connecting, listening, thinking, speaking, waiting }

        var phase: Phase
        var muted: Bool
        var startedAt: Date
    }

    /// The conversation's title or the Bot's name.
    var title: String
    /// The face of the one on the line, drawn by the app into the App Group (`CallAvatarFile`):
    /// the widget extension cannot draw a Bot's figure or read the app's own pictures.
    var avatar: String?
}

/// Where the call's face is kept for its Live Activity: `Call/<name>` in the App Group container,
/// written by the app as the call starts, read by the widget extension.
enum CallAvatarFile {
    static var folder: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DshAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appending(path: "Call")
    }

    static func url(_ name: String) -> URL? { folder?.appending(path: name) }
}

/// 静音 on the call's Live Activity. A `LiveActivityIntent` runs in the app's process, where the
/// call is.
struct ToggleCallMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "通话静音"
    static var isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await CallActivityBridge.toggleMute()
        return .result()
    }
}

/// 挂断 on the call's Live Activity.
struct HangUpCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "结束通话"
    static var isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await CallActivityBridge.hangUp()
        return .result()
    }
}

/// Set by the app while a call is on; nil in the extension (the intents never run there).
enum CallActivityBridge {
    @MainActor static var onToggleMute: (() -> Void)?
    @MainActor static var onHangUp: (() -> Void)?

    @MainActor static func toggleMute() { onToggleMute?() }
    @MainActor static func hangUp() { onHangUp?() }
}
