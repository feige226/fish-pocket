import AppIntents
import Foundation

/// A Bot as Shortcuts and Siri see it. The list is the one the share extension offers
/// (`ShareTargets`, written by `ShareTargetsWriter`): the Bot page's order, hidden Bots left out,
/// each with its avatar as the app draws it. Reading it needs no engine.
struct BotEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource(stringLiteral: "Bot"))
    static var defaultQuery = BotQuery()

    let id: String
    let name: String
    let role: String

    init(_ bot: ShareTargets.Bot) {
        id = bot.id
        name = bot.name
        role = bot.role
    }

    var displayRepresentation: DisplayRepresentation {
        // The Bot's own name and role, not phrases to translate.
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: role.isEmpty ? nil : LocalizedStringResource(stringLiteral: role),
            // The picture itself: Shortcuts and Siri run in processes that cannot read the App Group's files.
            image: ShareTargets.avatarURL(of: id).flatMap { try? Data(contentsOf: $0) }.map { .init(data: $0) }
        )
    }
}

struct BotQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BotEntity] {
        let bots = ShareTargets.read().bots
        return identifiers.compactMap { id in bots.first { $0.id == id }.map(BotEntity.init) }
    }

    func entities(matching string: String) async throws -> [BotEntity] {
        ShareTargets.read().bots.filter { $0.name.localizedCaseInsensitiveContains(string) }.map(BotEntity.init)
    }

    func suggestedEntities() async throws -> [BotEntity] {
        ShareTargets.read().bots.map(BotEntity.init)
    }
}

/// Opens one Bot's chat.
struct OpenBotIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 Bot"
    static var description = IntentDescription("打开和一个 Bot 的聊天。")
    static var openAppWhenRun = true

    @Parameter(title: LocalizedStringResource(stringLiteral: "Bot"))
    var bot: BotEntity

    static var parameterSummary: some ParameterSummary {
        Summary("打开\(\.$bot)")
    }

    init() {}

    init(bot: BotEntity) {
        self.bot = bot
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        DshIntentBridge.open?(.bot(bot.id))
        return .result()
    }
}

/// Opens the page with the balance: Fish Pocket's credits, or the DeepSeek account's wallets.
struct ShowBalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "查看余额"
    static var description = IntentDescription("打开 Fish Pocket 的余额页面。")
    static var openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DshIntentBridge.open?(.balance)
        return .result()
    }
}
