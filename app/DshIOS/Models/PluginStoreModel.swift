import Foundation
import Perception

/// The store's own state, around the market reader 发现 under 设置 → 插件 also uses.
///
/// The market is DSH's experimental bundle, off in the shipped profile, and it stays off until the
/// user turns on an index source: there is no market the app opens on by itself.
@MainActor
@Perceptible
final class PluginStoreModel {
    enum Readiness { case checking, preparing, ready, off, unavailable }

    let market = PluginMarketModel()
    private(set) var readiness = Readiness.checking
    @PerceptionIgnored private var preparing: Task<Void, Never>?

    /// A task of its own: the page's is cancelled when the connection comes up, which is exactly
    /// when a first visit runs.
    func prepare(_ app: AppModel) async {
        if let preparing {
            await preparing.value
            return
        }
        let task = Task { await ready(app) }
        preparing = task
        await task.value
        preparing = nil
    }

    private func ready(_ app: AppModel) async {
        await market.restoreCached()
        let manager = app.plugins
        await manager.refresh(revision: app.revision("plugin-manager/changed"))
        // The engine is not answering yet (it starts with the app, and restarts after some plugin
        // changes): the last visit's list stays up, and the next connection asks again.
        if manager.status == .error, market.fromCache { return }
        guard manager.status != .unavailable, let bundle = manager.package(PluginManagerModel.marketBundle) else {
            readiness = .unavailable
            return
        }
        guard bundle.enabled else {
            readiness = .off
            return
        }
        // Ready once the engine names the sources: reading one downloads the whole index, which can
        // take most of a minute, and the source list and installs need not wait for it.
        let listed = await market.listIndexes(app)
        readiness = .ready
        if listed { await market.reload(app) }
    }

    /// Whether a listing can be installed from. One restored from the last visit carries that
    /// visit's installation states, so it waits for the plugin list this visit read; `status`
    /// then says what is on the device.
    func installable(_ app: AppModel) -> Bool { !market.fromCache || app.plugins.status == .ready }

    /// A listing's installation status, from the plugin list while the listing is the last visit's.
    func status(_ entry: StoreEntry, _ app: AppModel) -> String? {
        guard market.fromCache, app.plugins.status == .ready else { return entry.status }
        let kept = ["update-available", "provided"].contains(entry.status ?? "")
        if app.plugins.package(entry.name)?.installed == true { return kept ? entry.status : "installed" }
        return entry.status == "provided" ? entry.status : nil
    }

    /// The sources in use; none while the market is off, whatever its settings still hold.
    var urls: [String] {
        readiness == .ready ? (market.indexes ?? []).compactMap { $0["url"].string } : []
    }

    var busy: Bool { readiness == .preparing || market.saving }

    /// The one source in use, or none. One at a time: a market is a third party's, and the user
    /// should know whose list they are looking at. While the market is off it is turned on first.
    func use(_ url: String?, _ app: AppModel) async -> Bool {
        if url != nil, readiness != .ready {
            guard await enableMarket(app) else { return false }
        }
        guard readiness == .ready else { return true }
        return await market.saveSources(url.map { [$0] } ?? [], adding: url != nil, app)
    }

    private func enableMarket(_ app: AppModel) async -> Bool {
        let manager = app.plugins
        guard let bundle = manager.package(PluginManagerModel.marketBundle) else { return false }
        readiness = .preparing
        await manager.setEnabled(bundle, true)
        guard manager.marketEnabled else {
            readiness = .off
            return false
        }
        await market.loadIndexes(app)
        readiness = .ready
        return true
    }

    /// Its switch went off under 设置 → 插件 while the store stayed open (iPad).
    func marketTurnedOff() {
        if readiness == .ready { readiness = .off }
    }

    /// Something to list while the engine is checked: before `.ready`, only the last visit's list
    /// from disk (or what a pull to refresh read over it) fills the sources.
    var hasList: Bool { market.indexes?.isEmpty == false }

    /// The newest read of a listing: a page that holds one outlives what it says about installation.
    func latest(_ entry: StoreEntry) -> StoreEntry {
        market.entries.first { $0["name"].string == entry.name }.map(StoreEntry.init) ?? entry
    }
}
