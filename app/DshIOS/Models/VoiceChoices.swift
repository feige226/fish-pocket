import Foundation
import Observation

/// Who a voice can be picked for, over the defaults in 设置 → 朗读 and 设置 → 语音通话.
enum VoiceOwner: Hashable {
    case bot(String)
    case session(String)

    var key: String {
        switch self {
        case .bot(let id): "bot:\(id)"
        case .session(let id): "session:\(id)"
        }
    }
}

/// The voices picked for single Bots and conversations, for calls and for reading aloud. Kept by
/// the app on this device only: DS Bot and DSH know nothing of them.
@MainActor
@Observable
final class VoiceChoices {
    static let shared = VoiceChoices()

    private static let callKey = "callVoiceOverrides"
    private static let readingKey = "readingVoiceOverrides"
    private var calls = UserDefaults.standard.dictionary(forKey: callKey) as? [String: String] ?? [:]
    private var readings = UserDefaults.standard.dictionary(forKey: readingKey) as? [String: String] ?? [:]

    private init() {}

    // MARK: Calls

    /// The call voice picked for `owner`; nil when it goes with the default.
    func callVoice(of owner: VoiceOwner) -> CallVoice? {
        calls[owner.key].flatMap { id in CallVoice.all.first { $0.id == id } }
    }

    func setCallVoice(_ voice: CallVoice?, for owner: VoiceOwner) {
        guard calls[owner.key] != voice?.id else { return }
        calls[owner.key] = voice?.id
        UserDefaults.standard.set(calls, forKey: Self.callKey)
    }

    /// The voice a call speaks in: a Bot's chat in the Bot's, any other in the conversation's;
    /// without one picked, the default.
    func callVoice(sessionId: String, botId: String?) -> CallVoice {
        callVoice(of: botId.map(VoiceOwner.bot) ?? .session(sessionId)) ?? CallVoice.chosen
    }

    /// The call voice for `owner`, else the default.
    func callVoice(for owner: VoiceOwner?) -> CallVoice {
        owner.flatMap(callVoice(of:)) ?? CallVoice.chosen
    }

    // MARK: Reading aloud

    /// The reading voice picked for `owner`; nil when it goes with the default.
    func readingVoice(of owner: VoiceOwner) -> DeepSeekSpeech.Voice? {
        readings[owner.key].flatMap(DeepSeekSpeech.Voice.init(rawValue:))
    }

    func setReadingVoice(_ voice: DeepSeekSpeech.Voice?, for owner: VoiceOwner) {
        guard readings[owner.key] != voice?.rawValue else { return }
        readings[owner.key] = voice?.rawValue
        UserDefaults.standard.set(readings, forKey: Self.readingKey)
    }

    /// The DeepSeek voice `owner` is read in (a Bot in its chat and its posts in a group, else
    /// the conversation), else the default. Reading with Volcengine uses the call voice instead.
    func readingVoice(for owner: VoiceOwner?) -> DeepSeekSpeech.Voice {
        owner.flatMap(readingVoice(of:)) ?? VoicePreferences.shared.readingVoice
    }

    /// What 声音 shows for `owner`: the voices picked, or 跟随默认.
    func summary(of owner: VoiceOwner) -> String {
        // Reading with Volcengine goes with the call voice: the DeepSeek one picked is not heard.
        let reading = VoicePreferences.shared.readingSource == .deepseek ? readingVoice(of: owner)?.title : nil
        let picked = [reading, callVoice(of: owner)?.name].compactMap(\.self)
        return picked.isEmpty ? String(localized: "跟随默认") : picked.joined(separator: " · ")
    }
}
