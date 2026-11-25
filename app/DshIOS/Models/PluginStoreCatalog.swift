import Foundation

/// What the store itself decides; everything about a plugin comes from its market index.
///
/// Fish Pocket provides no market and, like DSH, opens on none. 索引源 lists two third-party indexes
/// as examples, so the user need not type an address, but neither is read until the user turns it on
/// and confirms that it is a third party's, not ours.
enum PluginStoreCatalog {
    static let examples: [ExampleIndex] = [
        ExampleIndex(
            url: "https://cdn.jsdelivr.net/gh/realguan/dsh-plugin-market@dist/dsh-index.json",
            name: "dsh-market",
            summary: String(localized: "社区维护的 DSH 插件目录，发布在 GitHub 上，通过 jsDelivr 访问。")
        ),
        ExampleIndex(
            url: "https://api.dshfind.com/market/dsh-index.json",
            name: "dshfind",
            summary: String(localized: "社区维护的 DSH 插件目录，由 dshfind.com 提供。")
        ),
    ]

    static func example(_ url: String?) -> ExampleIndex? { examples.first { $0.url == url } }
}

/// A third-party index the app offers to add for the user. It is theirs once added, like any other.
struct ExampleIndex: Identifiable {
    let url: String
    let name: String
    let summary: String

    var id: String { url }
    var host: String { URLComponents(string: url)?.host ?? url }
}

/// A market listing as the store shows it. Index fields follow the format's rules; the rest of
/// what a row needs is derived here, so every page reads an entry the same way.
struct StoreEntry {
    let json: JSON

    var name: String { json["name"].string ?? "" }
    /// The package name without its scope.
    var shortName: String { name.components(separatedBy: "/").last ?? name }
    var scope: String? { name.hasPrefix("@") ? name.components(separatedBy: "/").first : nil }

    /// `title`, unless the index filled it with a repository path: a package name reads better.
    var displayName: String {
        guard let title = localized(json["title"]), !title.isEmpty,
              !(title.contains("/") && !title.contains(" ")) else { return name }
        return title
    }

    var summary: String? { localized(json["description"]).flatMap { $0.isEmpty ? nil : $0 } }
    var icon: String? { json["icon"].string }

    var version: JSON? { json["versions"].array.first { $0["version"].string == json["defaultVersion"].string } ?? json["versions"].array.first }
    var versionNumber: String { version?["version"].string ?? "" }
    var status: String? { json["installation"]["status"].string }
    var author: String? { json["author"].string }
    var labels: [String] { json["metadata"]["labels"].array.compactMap(\.string) }

    /// The default version's publish date.
    var date: String? {
        version?["publishTimestamp"].double.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }
    }

    /// The running DSH accepts this version, or the user exempted it.
    var installable: Bool {
        guard let compatibility = version?["compatibility"] else { return false }
        return compatibility["compatible"].bool == true || compatibility["exempted"].bool == true
    }

    /// The category's title, from what this market declares.
    func category(in metadata: JSON) -> String? {
        guard let id = json["metadata"]["category"].string else { return nil }
        return localized(metadata["categories"][id]["title"]) ?? id
    }
}

extension StoreEntry: Identifiable {
    var id: String { name }
}
