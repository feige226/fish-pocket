import Foundation
import Perception

/// Reporting a market plugin, and the takedown list that follows from reviewed reports. Both live on
/// the Fish Pocket service; without it (forks, local builds) there is no report entry and nothing is
/// taken down.
@MainActor
@Perceptible
final class PluginReports {
    static let shared = PluginReports()

    enum Category: String, CaseIterable, Identifiable {
        case illegal, malicious, privacy, impersonation, broken, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .illegal: String(localized: "违法和不良信息")
            case .malicious: String(localized: "恶意代码与权限滥用")
            case .privacy: String(localized: "隐私与数据采集")
            case .impersonation: String(localized: "冒充与侵权")
            case .broken: String(localized: "失效与崩溃")
            case .other: String(localized: "其他")
            }
        }

        var detail: String {
            switch self {
            case .illegal: String(localized: "名称、介绍或内容含违法、色情、暴力等信息")
            case .malicious: String(localized: "偷偷做与介绍不符的事，或越权访问")
            case .privacy: String(localized: "未经同意收集或上传数据")
            case .impersonation: String(localized: "冒用他人名义或侵犯版权")
            case .broken: String(localized: "装不上、用不了或导致崩溃")
            case .other: String(localized: "以上都不是")
            }
        }
    }

    enum Takedown: String { case reviewing, removed }

    /// A report this device sent, as the service last described it.
    struct Receipt: Codable, Identifiable, Equatable {
        let id: String
        var status: String
        var note: String?
        let createdAt: Double
        var updatedAt: Double
        let plugin: String
        let version: String?
        let category: String

        var statusTitle: String {
            switch status {
            case "reviewing": String(localized: "审核中")
            case "removed": String(localized: "已下架")
            case "dismissed": String(localized: "已处理，未发现问题")
            default: String(localized: "已收到，等待处理")
            }
        }

        var categoryTitle: String { Category(rawValue: category)?.title ?? category }
        var closed: Bool { status == "removed" || status == "dismissed" }

        init?(_ json: JSON) {
            guard let id = json["id"].string, let status = json["status"].string else { return nil }
            self.id = id
            self.status = status
            note = json["note"].string
            createdAt = json["createdAt"].double ?? Date().timeIntervalSince1970 * 1000
            updatedAt = json["updatedAt"].double ?? createdAt
            plugin = json["plugin"]["name"].string ?? ""
            version = json["plugin"]["version"].string
            category = json["category"].string ?? "other"
        }
    }

    private static let receiptsKey = "dsh.pluginReports.receipts"
    private static let takedownsKey = "dsh.pluginReports.takedowns"

    private(set) var takedowns: [String: Takedown] = [:]
    private(set) var receipts: [Receipt] = []
    @PerceptionIgnored private var takedownsReadAt: Date?
    @PerceptionIgnored private var reading: Task<Void, Never>?

    var available: Bool { FishPocketAPI.available }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.receiptsKey),
           let saved = try? JSONDecoder().decode([Receipt].self, from: data) {
            receipts = saved
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.takedownsKey) as? [String: String] {
            takedowns = saved.compactMapValues(Takedown.init(rawValue:))
        }
    }

    func takedown(_ name: String) -> Takedown? { takedowns[name] }
    func removed(_ name: String) -> Bool { takedowns[name] == .removed }

    /// The takedown list, at most every five minutes (the service caches it as long). The last list
    /// stays in force offline, so a plugin taken down doesn't come back without a connection.
    func loadTakedowns(force: Bool = false) {
        guard available, reading == nil else { return }
        if !force, let takedownsReadAt, Date().timeIntervalSince(takedownsReadAt) < 300 { return }
        reading = Task {
            defer { reading = nil }
            guard let base = FishPocketAPI.baseURL,
                  let reply = try? await FishPocketHTTP(base: base).send("GET", "v1/plugin-takedowns") else { return }
            takedownsReadAt = Date()
            let list = reply["plugins"].object.compactMapValues { $0["status"].string.flatMap(Takedown.init(rawValue:)) }
            guard list != takedowns else { return }
            takedowns = list
            UserDefaults.standard.set(list.mapValues(\.rawValue), forKey: Self.takedownsKey)
        }
    }

    /// Send a report; the receipt is kept on this device for 我的举报.
    func submit(
        _ app: AppModel, plugin: String, version: String?, source: String?, market: String?,
        category: Category, description: String, log: String?
    ) async throws -> Receipt {
        var pluginFields: [String: JSON] = ["name": .string(plugin)]
        if let version { pluginFields["version"] = .string(version) }
        if let source { pluginFields["source"] = .string(source) }
        if let market { pluginFields["market"] = .string(market) }
        var body: [String: JSON] = [
            "plugin": .object(pluginFields),
            "category": .string(category.rawValue),
            "description": .string(description),
            "appVersion": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
        ]
        if let log, !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["log"] = .string(log) }
        let reply = try await app.fishPocket.sendAsUser("POST", "v1/reports", body: .object(body))
        guard let receipt = Receipt(reply) else {
            throw FishPocketError(status: 0, code: "invalid_reply", message: String(localized: "提交失败，请稍后再试。"))
        }
        receipts.insert(receipt, at: 0)
        save()
        return receipt
    }

    /// Ask again about every report still open. One that the service no longer knows stays as it was.
    func refreshReceipts() async {
        guard let base = FishPocketAPI.baseURL else { return }
        let http = FishPocketHTTP(base: base)
        for receipt in receipts where !receipt.closed {
            guard let reply = try? await http.send("GET", "v1/reports/\(receipt.id)"), let fresh = Receipt(reply),
                  let index = receipts.firstIndex(where: { $0.id == receipt.id }) else { continue }
            if receipts[index] != fresh { receipts[index] = fresh }
        }
        save()
    }

    func forget(_ ids: [String]) {
        receipts.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(receipts) { UserDefaults.standard.set(data, forKey: Self.receiptsKey) }
    }
}
