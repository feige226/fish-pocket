import Foundation

/// 生图 paid in Fish Pocket credits: Seedream through the Fish Pocket service. The image plugin
/// has no provider of its own for it, and its Seedream provider keeps its key in `ARK_API_KEY`,
/// the user's own Ark key; so the account is one of the plugin's OpenAI-compatible channels,
/// with a key slot of its own, the app writes and keeps in step: the service's address, its one
/// model, the JSON edit format the service reads, Seedream's sizes, and this device's runtime key.
/// The user picks it as 默认使用 like any provider; nothing switches to it, or away from it, by
/// itself. Other channels are the user's and are never touched.
@MainActor
enum FishPocketImageGen {
    static let channelID = "fishpocket"
    static let keyRef = ImageGenChannel.keyRef(for: channelID)
    /// What the service sells (it answers for this model whatever is asked); shown as the model.
    static let model = "doubao-seedream-5-5-261028"

    static var available: Bool { FishPocketAPI.available }

    static var title: String { String(localized: "Fish Pocket 账号（Seedream）") }

    /// Seedream 5.5's sizes by ratio: 1K and 2K, multiples of 16, inside its pixel range.
    static let sizes: JSON = {
        let table: [(String, String, String)] = [
            ("1:1", "1024x1024", "2048x2048"), ("2:3", "832x1248", "1680x2512"), ("3:2", "1248x832", "2512x1680"),
            ("3:4", "880x1184", "1776x2368"), ("4:3", "1184x880", "2368x1776"), ("9:16", "768x1360", "1536x2736"),
            ("16:9", "1360x768", "2736x1536"), ("21:9", "1568x672", "3136x1344"),
        ]
        return .object(Dictionary(uniqueKeysWithValues: table.map { ($0.0, JSON.object(["1K": .string($0.1), "2K": .string($0.2)])) }))
    }()

    /// The channel as the app keeps it, or nil in a build without the service.
    static var channel: ImageGenChannel? {
        guard let base = FishPocketAPI.baseURL else { return nil }
        var channel = ImageGenChannel(id: channelID, label: title, keyRef: keyRef)
        channel.baseURL = base.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + "/v1"
        channel.model = model
        channel.models = [model]
        // JPEG: a fifth of the bytes of Seedream's default PNG, and stored as it comes, with the
        // implicit AI label (C2PA) Volcengine writes into it; a PNG is re-encoded on the way in.
        channel.extraBody = ["output_format": "jpeg"]
        channel.editExtra = ["output_format": "jpeg"]
        channel.editSizeMode = "selected"
        channel.editFormat = "jsonImageUrlArray"
        channel.sizes = sizes
        return channel
    }

    /// The default provider is this channel.
    static func isChosen(_ value: JSON) -> Bool {
        value["provider"].string == ImageGenProvider.openaiCompat.rawValue && value["openaiCompatActiveChannel"].string == channelID
    }

    static func exists(_ value: JSON) -> Bool {
        value["openaiCompatChannels"].array.contains { $0["id"].string == channelID }
    }

    /// Make it the default provider (the user picked it): the channel, its key, then the choice.
    static func choose(in mirror: SettingsMirror) async throws {
        try await write(in: mirror, choosing: true)
    }

    /// Bring a channel made earlier up to date (another runtime key, signed out, an app update
    /// that changed the model or the sizes). Nothing is made when the user never picked it.
    static func sync(in mirror: SettingsMirror) async {
        if !mirror.loaded { await mirror.reload() }
        guard let value = mirror.namespace(ImageGenModel.namespace)?["value"], exists(value) else { return }
        try? await write(in: mirror, choosing: false)
    }

    private static func write(in mirror: SettingsMirror, choosing: Bool) async throws {
        guard let channel, let current = mirror.namespace(ImageGenModel.namespace) else { return }
        let value = current["value"]
        var ops: [SettingsOp] = []
        var added = Array(ImageGenChannel.all(value).dropFirst())
        if let index = added.firstIndex(where: { $0.id == channelID }) {
            if added[index].stored != channel.stored { added[index] = channel; ops.append(.set(["openaiCompatChannels"], .array(added.map(\.stored)))) }
        } else {
            added.append(channel)
            ops.append(.set(["openaiCompatChannels"], .array(added.map(\.stored))))
        }
        if choosing {
            ops.append(.set(["provider"], .string(ImageGenProvider.openaiCompat.rawValue)))
            ops.append(.set(["openaiCompatActiveChannel"], .string(channelID)))
        }
        if !ops.isEmpty {
            try await mirror.mutate(ImageGenModel.namespace, ops, expectedRevision: current["revision"].int)
        }
        if let key = FishPocketAccount.storedRuntimeKey {
            try await mirror.setCredential(keyRef, key)
        } else {
            try? await mirror.unsetCredential(keyRef)
        }
    }
}
