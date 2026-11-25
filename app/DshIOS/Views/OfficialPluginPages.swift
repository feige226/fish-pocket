import SwiftUI

/// The staged form every official plugin page shares (`SettingsFormModel`, F-50):
/// edits stay local until 保存, which writes one `settings/mutate` fenced by the
/// revision read when the first edit was staged. A field shows the user's own value;
/// an inherited one is its placeholder, so grey means default.
@MainActor
@Observable
final class StagedForm {
    enum Kind { case number((Double) -> Bool), text }

    struct Spec {
        let key: String
        let kind: Kind
        /// The refusal shown for a value `kind` rejects.
        var invalid: String?
    }

    private struct Draft { var text: String; var clear: Bool }

    let ns: String
    private let specs: [Spec]
    private var drafts: [String: Draft] = [:]
    private var baseline: Int?
    private(set) var saving = false
    private(set) var failed = false
    /// The first field of a refused write, for the page to scroll to.
    private(set) var failedField: String?

    init(ns: String, specs: [Spec]) {
        self.ns = ns
        self.specs = specs
    }

    var dirty: Bool { !drafts.isEmpty }

    private func format(_ value: JSON?) -> String {
        guard let value, !value.isNull else { return "" }
        return value.compactText
    }

    func text(_ key: String, _ mirror: SettingsMirror) -> String {
        drafts[key]?.text ?? format(mirror.namespace(ns)?["value"][key])
    }

    /// The user layer's value, empty when the field inherits.
    private func stored(_ key: String, _ mirror: SettingsMirror) -> String {
        mirror.namespace(ns)?["user"].has([key]) == true ? format(mirror.namespace(ns)?["value"][key]) : ""
    }

    /// What the field shows: only what the user set.
    func display(_ key: String, _ mirror: SettingsMirror) -> String {
        if let draft = drafts[key] { return draft.clear ? "" : draft.text }
        return stored(key, mirror)
    }

    /// The value in force when the field is empty.
    func placeholder(_ key: String, _ mirror: SettingsMirror) -> String {
        let namespace = mirror.namespace(ns)
        let inherited = namespace?["base"][key].nonNull
            ?? (namespace?["user"].has([key]) == true ? nil : namespace?["value"][key].nonNull)
            ?? mirror.graph(ns)?.node(at: [key])?.defaultValue
        return inherited.map { format($0) } ?? String(localized: "默认")
    }

    func overridden(_ key: String, _ mirror: SettingsMirror) -> Bool {
        if let draft = drafts[key], draft.clear { return false }
        return mirror.namespace(ns)?["user"].has([key]) ?? false
    }

    private func stage(_ key: String, _ draft: Draft?, _ mirror: SettingsMirror) {
        if drafts.isEmpty { baseline = mirror.namespace(ns)?["revision"].int }
        drafts[key] = draft
        failed = false
        failedField = nil
    }

    /// Typing back what is stored leaves nothing to save.
    func edit(_ key: String, _ text: String, _ mirror: SettingsMirror) {
        stage(key, text == stored(key, mirror) ? nil : Draft(text: text, clear: false), mirror)
    }

    /// 恢复默认: shows the inherited value, unsets on save.
    func reset(_ key: String, _ mirror: SettingsMirror) {
        let set = mirror.namespace(ns)?["user"].has([key]) == true
        stage(key, set ? Draft(text: format(mirror.namespace(ns)?["base"][key]), clear: true) : nil, mirror)
    }

    func discard() {
        drafts = [:]
        failed = false
        failedField = nil
    }

    /// What `text` parses to: `.none` is invalid, `.some(nil)` clears, else the value.
    private func parse(_ spec: Spec, _ text: String) -> JSON?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        switch spec.kind {
        case .text:
            return .some(.string(trimmed))
        case .number(let accepts):
            guard let value = Double(trimmed), value.isFinite, accepts(value) else { return .none }
            return .some(.number(value))
        }
    }

    func problem(_ key: String) -> String? {
        guard let draft = drafts[key], let spec = specs.first(where: { $0.key == key }), case .none = parse(spec, draft.text) else { return nil }
        return spec.invalid ?? String(localized: "请填数字；留空表示使用默认值。")
    }

    var invalid: Bool { drafts.keys.contains { problem($0) != nil } }

    private func ops(_ mirror: SettingsMirror) -> [SettingsOp] {
        let namespace = mirror.namespace(ns)
        var ops: [SettingsOp] = []
        for spec in specs {
            guard let draft = drafts[spec.key] else { continue }
            let stored = namespace?["user"].has([spec.key]) ?? false
            if draft.clear {
                if stored { ops.append(.unset([spec.key])) }
                continue
            }
            if draft.text == format(namespace?["value"][spec.key]) { continue }
            switch parse(spec, draft.text) {
            case .some(.some(let value)): ops.append(.set([spec.key], value))
            case .some(.none): if stored { ops.append(.unset([spec.key])) }
            case .none: break
            }
        }
        return ops
    }

    /// Write the staged fields; false keeps the drafts for correction.
    func save(_ mirror: SettingsMirror) async -> Bool {
        guard dirty, !invalid, !saving else { return !invalid }
        saving = true
        failed = false
        failedField = nil
        defer { saving = false }
        let edits = ops(mirror)
        guard !edits.isEmpty else { drafts = [:]; return true }
        do {
            try await mirror.mutate(ns, edits, expectedRevision: baseline)
            drafts = [:]
            return true
        } catch {
            failed = true
            failedField = specs.first { drafts[$0.key] != nil }?.key
            return false
        }
    }
}

/// A field of a staged form: a settings row with the value trailing, or, for an address too
/// long for that, stacked. Swipe or long-press resets it; clearing it does the same (F-50).
private struct StagedField: View {
    @Environment(AppModel.self) private var app
    let form: StagedForm
    let key: String
    let title: LocalizedStringKey
    var unit: LocalizedStringKey?
    var keyboard: UIKeyboardType = .numberPad

    var body: some View {
        let mirror = app.settings
        VStack(alignment: .leading, spacing: 4) {
            if keyboard == .URL {
                Text(title).font(.caption).foregroundStyle(Palette.secondary)
                field(mirror)
            } else {
                LabeledContent {
                    HStack(spacing: 6) {
                        // Wide enough for the numbers these hold; left unbounded it takes half the row and cuts a long title short.
                        field(mirror).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                        if let unit { Text(unit).foregroundStyle(Palette.secondary) }
                    }
                } label: {
                    Text(title).foregroundStyle(Palette.ink)
                }
            }
            if let problem = form.problem(key) {
                Text(problem).font(.caption).foregroundStyle(Palette.removed)
            } else if form.failedField == key {
                Text("引擎没有接受这个值，请修改后再保存。").font(.caption).foregroundStyle(Palette.removed)
            }
        }
        .id(key)
        .resettable(form.overridden(key, mirror)) { form.reset(key, mirror) }
    }

    private func field(_ mirror: SettingsMirror) -> some View {
        TextField(form.placeholder(key, mirror), text: Binding(get: { form.display(key, mirror) }, set: { form.edit(key, $0, mirror) }))
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.callout)
    }
}

/// The frame of an official page: unavailable / read-only states, 保存 in the toolbar (it pops
/// the page), and a refused save scrolling to what went wrong.
private struct OfficialForm<Content: View>: View {
    @Environment(AppModel.self) private var app
    let title: LocalizedStringKey
    let available: Bool
    let dirty: Bool
    let invalid: Bool
    let saving: Bool
    let failed: Bool
    /// The row a failure belongs to; nil shows the page's own message.
    var failedField: String?
    let discard: () -> Void
    let save: () async -> Bool
    @ViewBuilder let content: Content
    @State private var saved = false

    private static var failure: String { "official-form-failure" }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if app.settings.loaded && !available {
                    Section { Text("该插件当前未加载，暂时无法配置。").foregroundStyle(Palette.secondary) }.groupedRow()
                } else {
                    if app.settings.loaded && !app.settings.writable {
                        Section { Text("设置当前为只读。").foregroundStyle(Palette.secondary) }.groupedRow()
                    }
                    if failed && failedField == nil {
                        Section {
                            Text("引擎没有接受这些值，已保留供你修改。").font(.footnote).foregroundStyle(Palette.removed)
                                .id(Self.failure)
                        }
                        .groupedRow()
                    }
                    content.disabled(!app.settings.writable || saving)
                }
            }
            .onChange(of: failed) { _, failed in
                guard failed else { return }
                withAnimation { proxy.scrollTo(failedField ?? Self.failure, anchor: .center) }
            }
        }
        .inkTint()
        .groupedList()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .editPage(dirty: dirty, canSave: !invalid && app.settings.writable && available, saving: saving, discard: discard) {
            Task {
                if await save() {
                    Haptics.success()
                    saved = true
                } else {
                    Haptics.error()
                }
            }
        }
        .dismisses(when: saved)
        .followSettings()
    }
}

/// PC-01…PC-04.
struct OfficialPluginPage: View {
    let page: OfficialPluginItem.Page

    var body: some View {
        switch page {
        case .subagent: SubagentSettingsPage()
        case .webSearch: WebSearchSettingsPage()
        case .agentLoop: AgentLoopSettingsPage()
        case .shell: ShellSettingsPage()
        }
    }
}

private func integerAtLeast(_ minimum: Double) -> (Double) -> Bool {
    { $0.rounded() == $0 && $0 >= minimum }
}

/// PC-03.
private struct AgentLoopSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var form = StagedForm(ns: "agent-loop", specs: [.init(key: "maxParallelToolCalls", kind: .number { _ in true })])

    var body: some View {
        OfficialForm(title: "Agent 循环", available: app.settings.serves("agent-loop"), dirty: form.dirty, invalid: form.invalid, saving: form.saving, failed: form.failed, failedField: form.failedField, discard: form.discard, save: { await form.save(app.settings) }) {
            Section {
                StagedField(form: form, key: "maxParallelToolCalls", title: "并行工具调用数")
            } footer: {
                Text("同一步内最多同时运行多少个可并行的调用。")
            }
            .groupedRow()
        }
    }
}

/// PC-04: `pwsh-sandbox` where the Host serves it, else `bash-sandbox`.
private struct ShellSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var bash = Self.form("bash-sandbox")
    @State private var pwsh = Self.form("pwsh-sandbox")

    private static func form(_ ns: String) -> StagedForm {
        StagedForm(ns: ns, specs: [.init(key: "timeoutMs", kind: .number { _ in true }), .init(key: "maxOutputBytes", kind: .number { _ in true })])
    }

    private var form: StagedForm { app.settings.serves("pwsh-sandbox") ? pwsh : bash }

    var body: some View {
        OfficialForm(title: "终端", available: app.settings.serves(form.ns), dirty: form.dirty, invalid: form.invalid, saving: form.saving, failed: form.failed, failedField: form.failedField, discard: form.discard, save: { await form.save(app.settings) }) {
            Section {
                StagedField(form: form, key: "timeoutMs", title: "命令超时", unit: "毫秒")
                StagedField(form: form, key: "maxOutputBytes", title: "输出上限", unit: "字节")
            } footer: {
                Text("命令超时即终止；超出上限的输出转存到临时文件。")
            }
            .groupedRow()
        }
    }
}

/// PC-01: limits, and which models the Agent may pick for subagents. One 保存 writes
/// both namespaces, each fenced by its own revision.
private struct SubagentSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var limits = StagedForm(ns: "subagent", specs: [
        .init(key: "maxDepth", kind: .number(integerAtLeast(0)), invalid: String(localized: "请输入不小于 0 的整数。")),
        .init(key: "maxActiveSubagents", kind: .number(integerAtLeast(1)), invalid: String(localized: "请输入不小于 1 的整数。")),
    ])
    @State private var draftEnabled: Bool?
    @State private var draftRoutes: [String: JSON]?
    @State private var draftRevision: Int?
    @State private var catalog: JSON?
    @State private var catalogFailed = false
    @State private var saving = false
    @State private var failed = false
    @State private var conflicted = false

    private static let ns = "subagent-model-selection-settings"
    private var selection: JSON? { app.settings.namespace(Self.ns) }
    private var storedEnabled: Bool { selection?["value"]["enabled"].bool ?? false }
    private var storedRoutes: [String: JSON] {
        Dictionary((selection?["value"]["allowedModels"].array ?? []).map { (Self.key($0), $0) }, uniquingKeysWith: { $1 })
    }
    private var enabled: Bool { draftEnabled ?? storedEnabled }
    private var routes: [String: JSON] { draftRoutes ?? storedRoutes }
    private var modelsDirty: Bool { (draftEnabled != nil && draftEnabled != storedEnabled) || (draftRoutes != nil && Set(draftRoutes!.keys) != Set(storedRoutes.keys)) }
    private var needsModel: Bool { enabled && routes.isEmpty }

    private static var modelSelectionRow: String { "subagent-model-selection" }

    private static func key(_ route: JSON) -> String { "\(route["provider"].string ?? "")\u{0}\(route["model"].string ?? "")" }

    var body: some View {
        OfficialForm(title: "子智能体", available: app.settings.serves("subagent"), dirty: limits.dirty || modelsDirty, invalid: limits.invalid || needsModel, saving: saving || limits.saving, failed: failed || limits.failed || conflicted, failedField: limits.failedField ?? (conflicted ? Self.modelSelectionRow : nil), discard: discard, save: save) {
            Section {
                StagedField(form: limits, key: "maxDepth", title: "最大递归深度")
                StagedField(form: limits, key: "maxActiveSubagents", title: "并行数量上限")
            } header: {
                Text("运行限制")
            } footer: {
                Text("深度 0 禁用子智能体，1 只允许主 Agent 创建。达到数量上限时不再启动新的子智能体，主 Agent 不计入。")
            }
            .groupedRow()
            if selection != nil {
                Section {
                    Toggle("允许 Agent 为子智能体选择模型", isOn: Binding(get: { enabled }, set: { on in
                        beginDraft()
                        draftEnabled = on
                        conflicted = false
                        failed = false
                    }))
                    .id(Self.modelSelectionRow)
                    if conflicted { Text("设置已在其他位置更新。请放弃修改后重试。").font(.caption).foregroundStyle(Palette.removed) }
                } header: {
                    Text("模型选择")
                } footer: {
                    Text(needsModel ? "至少选择一个模型才能保存。"
                         : enabled ? "Agent 可从下方模型中为子智能体选择。仅影响新会话。"
                         : "子智能体使用默认模型或继承父 Agent 的模型。")
                }
                .groupedRow()
                if enabled { modelSections }
            }
        }
        .task { await loadCatalog() }
    }

    @ViewBuilder
    private var modelSections: some View {
        if catalogFailed {
            Section {
                Text("无法加载模型。").font(.footnote).foregroundStyle(Palette.removed)
                Button("重试") { Task { await loadCatalog() } }
            }
            .groupedRow()
        } else if let catalog {
            let groups = catalog["groups"].array.filter { !$0["models"].array.isEmpty }
            if !catalog["failures"].array.isEmpty {
                Section { Text("部分模型提供商暂时无法加载；已保存的选择仍可移除。").font(.footnote).foregroundStyle(Palette.waiting) }.groupedRow()
            }
            if groups.isEmpty {
                Section { Text("当前没有可选的模型。").font(.footnote).foregroundStyle(Palette.secondary) }.groupedRow()
            }
            ForEach(groups, id: \.self) { group in
                Section(group["name"].string ?? group["id"].string ?? "") {
                    ForEach(group["models"].array, id: \.self) { model in
                        modelToggle(provider: group["id"].string ?? "", model: model["id"].string ?? "", title: model["name"].string ?? model["id"].string ?? "")
                    }
                }
                .groupedRow()
            }
            let offered = Set(groups.flatMap { group in group["models"].array.map { Self.key(["provider": group["id"], "model": $0["id"]]) } })
            let unavailable = routes.filter { !offered.contains($0.key) }.sorted { $0.key < $1.key }
            if !unavailable.isEmpty {
                Section("已保存但当前不可用") {
                    ForEach(unavailable, id: \.key) { _, route in
                        modelToggle(provider: route["provider"].string ?? "", model: route["model"].string ?? "", title: "\(route["provider"].string ?? "") / \(route["model"].string ?? "")")
                    }
                }
                .groupedRow()
            }
        } else {
            Section { HStack { ProgressView().controlSize(.small); Text("正在加载模型…").font(.footnote).foregroundStyle(Palette.secondary) } }.groupedRow()
        }
    }

    private func modelToggle(provider: String, model: String, title: String) -> some View {
        let route: JSON = ["provider": .string(provider), "model": .string(model)]
        let key = Self.key(route)
        return Toggle(title, isOn: Binding(get: { routes[key] != nil }, set: { on in
            beginDraft()
            draftRoutes?[key] = on ? route : nil
            conflicted = false
            failed = false
        }))
    }

    private func beginDraft() {
        guard draftRoutes == nil else { return }
        draftRoutes = storedRoutes
        draftEnabled = storedEnabled
        draftRevision = selection?["revision"].int
    }

    private func loadCatalog() async {
        catalogFailed = false
        do {
            catalog = try await app.client.call("session/modelCatalog")
        } catch {
            catalogFailed = true
        }
    }

    private func discard() {
        limits.discard()
        draftEnabled = nil
        draftRoutes = nil
        conflicted = false
        failed = false
    }

    private func save() async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        failed = false
        conflicted = false
        if limits.dirty, !(await limits.save(app.settings)) { return false }
        guard modelsDirty else { draftEnabled = nil; draftRoutes = nil; return true }
        if let draftRevision, selection?["revision"].int != draftRevision {
            conflicted = true
            return false
        }
        let desired = routes.keys.sorted().compactMap { routes[$0] }.map { route -> JSON in ["provider": route["provider"], "model": route["model"]] }
        do {
            try await app.settings.mutate(Self.ns, [.set(["enabled"], .bool(enabled)), .set(["allowedModels"], .array(desired))], expectedRevision: draftRevision)
            draftEnabled = nil
            draftRoutes = nil
            return true
        } catch {
            if isConflict(error) { conflicted = true } else { failed = true }
            return false
        }
    }
}

/// PC-02: which provider searches the web and which one reads pages, each followed by the settings
/// the selected provider has here. The menus list what the Host registers (`web/listProviders`),
/// plugins' providers included, so a deployment whose default is a plugin's provider shows and
/// selects right, and a newly installed one needs no change here.
private struct WebSearchSettingsPage: View {
    /// The two things the web service does; each selects its own provider.
    private enum Capability: String {
        case search, fetch

        /// `web.searchProvider` / `web.fetchProvider`.
        var provider: String { rawValue + "Provider" }
        /// `web-deepseek-api.searchBilling` / `fetchBilling`.
        var billing: String { rawValue + "Billing" }
        /// The DeepSeek API's own endpoint and key reference for this capability.
        var endpoint: [String] { [rawValue + "BaseURL", rawValue + "ApiKeyEnv"] }
        /// The official providers, which a menu lists first, in the web page's order.
        var official: [String] { self == .search ? ["deepseek-search-api", "deepseek-official"] : ["http", "deepseek-fetch-api"] }
    }

    /// What a section shows under its menu for the selected provider: the DeepSeek API's settings,
    /// legacy Messages search's, a pointer to the plugin that owns the provider, or nothing.
    private enum Panel { case api, legacy, plugin, plain }

    /// One entry of a provider menu.
    private struct Choice: Identifiable {
        let id: String
        var title: String?
        var description: JSON = .null
        /// Selected, but the Host does not register it.
        var missing = false
    }

    @Environment(AppModel.self) private var app
    @State private var selection = StagedForm(ns: "web", specs: [.init(key: "searchProvider", kind: .text), .init(key: "fetchProvider", kind: .text)])
    // The Search and Fetch APIs' own endpoints and key references are not fields of this form:
    // they belong to the configuration file and override billing, so the page only reads them.
    @State private var api = StagedForm(ns: "web-deepseek-api", specs: [
        .init(key: "count", kind: .number { $0.rounded() == $0 && (1...50).contains($0) }, invalid: String(localized: "请填 1–50 的整数；留空表示使用默认值。")),
        .init(key: "searchBilling", kind: .text),
        .init(key: "fetchBilling", kind: .text),
    ])
    @State private var messages = StagedForm(ns: "web-search-deepseek", specs: [
        .init(key: "baseURL", kind: .text),
        .init(key: "maxUses", kind: .number(integerAtLeast(1)), invalid: String(localized: "请填正整数；留空表示使用默认值。")),
    ])
    /// The last `web/listProviders` answer; nil until one arrives.
    @State private var providers: JSON?
    @State private var providersFailed = false
    @State private var providerRead = 0
    @State private var keyDraft = ""
    @State private var credential: JSON?
    @State private var saving = false

    private static let billings = ["auto", "account", "api-key"]

    private var mirror: SettingsMirror { app.settings }
    /// The reference legacy search's key is written under.
    private var ref: String {
        let named = mirror.namespace("web-search-deepseek")?["value"]["apiKeyEnv"].string
        return named.flatMap { $0.isEmpty ? nil : $0 } ?? "DEEPSEEK_API_KEY"
    }
    private var dirty: Bool { selection.dirty || api.dirty || messages.dirty || !keyDraft.isEmpty }
    private var invalid: Bool { api.invalid || messages.invalid }
    private var failed: Bool { selection.failed || api.failed || messages.failed }

    var body: some View {
        OfficialForm(title: "网页搜索与获取", available: mirror.serves("web"), dirty: dirty, invalid: invalid, saving: saving, failed: failed, discard: discard, save: save) {
            if providersFailed {
                Section {
                    Text("提供方列表没读到，下面的选项可能不全。").font(.footnote).foregroundStyle(Palette.waiting)
                    Button("重试") { Task { await loadProviders() } }
                }
                .groupedRow()
            }
            providerSection(.search)
            switch panel(.search) {
            case .api:
                Section {
                    StagedField(form: api, key: "count", title: "每次搜索结果数")
                    billingPicker(.search)
                } footer: {
                    billingNote(.search)
                }
                .groupedRow()
            case .legacy:
                legacySection
            case .plugin, .plain:
                EmptyView()
            }
            providerSection(.fetch)
            if panel(.fetch) == .api {
                Section {
                    billingPicker(.fetch)
                } footer: {
                    billingNote(.fetch)
                }
                .groupedRow()
            }
        }
        // Providers come and go with plugins, and a Host that starts serving `web` has ones not read yet.
        .task(id: "\(app.revision("web/providers-changed"))#\(mirror.serves("web"))") { await loadProviders() }
        .task(id: "\(ref)#\(app.settingsRevision)") { await readCredential() }
    }

    // MARK: Providers

    private func providerSection(_ capability: Capability) -> some View {
        let entries = choices(capability)
        let current = entries.first { $0.id == selected(capability) }
        let shown = panel(capability)
        return Section {
            Picker("提供方", selection: Binding(get: { selected(capability) }, set: { select(capability, $0) })) {
                if automatic(capability) { Text("自动选择").tag("") }
                ForEach(entries) { entry in Text(name(entry)).tag(entry.id) }
            }
            .pickerStyle(.menu)
            .pickerValueTint()
            // A field the change would hide stays in view while its value is invalid or was refused.
            .disabled(invalid || failed)
        } header: {
            Text(capability == .search ? "网页搜索" : "网页获取")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                // What the provider says about itself: what it costs and what it cannot reach.
                if let note = current.flatMap({ localized($0.description) }), !note.isEmpty {
                    Text(note)
                } else if current?.id == Self.builtInAuto {
                    Text("先用当前对话那条模型线路自带的搜索，费用算在那条线路自己的 Key 或账号上；用不了时改为读取公开的搜索结果页，不另外收费。")
                }
                if capability == .search, shown == .api, let url = URL(string: String(localized: "https://api-docs.deepseek.com/zh-cn/guides/search")) {
                    Link("功能与计费说明", destination: url)
                }
                if shown == .plugin { Text("由插件提供，到该插件自己的设置里配置。") }
            }
        }
        .groupedRow()
    }

    /// The provider a capability stages: the draft, else the one in force; empty when nothing names one.
    private func selected(_ capability: Capability) -> String { selection.text(capability.provider, mirror) }

    /// A menu's entries: the registered official providers in the web page's order, the rest as
    /// the Host lists them, and the selected id when the Host does not register it. Before a
    /// list arrives the menu holds only the selected id.
    private func choices(_ capability: Capability) -> [Choice] {
        let chosen = selected(capability)
        guard let listed = providers?[capability.rawValue].array else {
            return chosen.isEmpty ? [] : [Choice(id: chosen)]
        }
        let first = capability.official
        let official: [JSON] = first.compactMap { id in listed.first { $0["id"].string == id } }
        let others: [JSON] = listed.filter { !first.contains($0["id"].string ?? "") }
        var entries: [Choice] = (official + others).compactMap { info in
            info["id"].string.map { Choice(id: $0, title: info["title"].string, description: info["description"]) }
        }
        if !chosen.isEmpty, !entries.contains(where: { $0.id == chosen }) { entries.append(Choice(id: chosen, missing: true)) }
        return entries
    }

    /// A provider's name in the menu: the app's own for the official ones, else the title it
    /// registered, else its id.
    private func name(_ entry: Choice) -> String {
        let name = Self.officialName(entry.id) ?? entry.title ?? entry.id
        return entry.missing ? String(localized: "\(name)（未加载）") : name
    }

    private static func officialName(_ id: String) -> String? {
        switch id {
        case "deepseek-search-api": String(localized: "DeepSeek 搜索 API")
        case "deepseek-official": String(localized: "DeepSeek（旧版）")
        case "http": String(localized: "本机直接获取")
        case "deepseek-fetch-api": String(localized: "DeepSeek 获取 API")
        case builtInAuto: String(localized: "自动")
        default: nil
        }
    }

    /// The search provider the built-in Bot plugin registers and makes the default here
    /// (`ds-bot/web-search`). It names and describes nothing about itself, and has no settings
    /// page of its own to point at, so the page speaks for it.
    private static let builtInAuto = "auto"

    /// Whether the menu offers automatic selection: the deployment composes no provider for the
    /// capability, so clearing the stored choice lets the Host pick. Also while nothing is
    /// selected, so the menu always has the entry it shows.
    private func automatic(_ capability: Capability) -> Bool {
        mirror.namespace("web")?["base"][capability.provider].string == nil || selected(capability).isEmpty
    }

    private func panel(_ capability: Capability) -> Panel {
        let id = selected(capability)
        let listed = providers?[capability.rawValue].array
        // Until a list arrives every id counts as registered, so an official provider's settings do not wait for it.
        guard !id.isEmpty, listed?.contains(where: { $0["id"].string == id }) ?? true else { return .plain }
        switch (capability, id) {
        case (.search, "deepseek-search-api"), (.fetch, "deepseek-fetch-api"):
            return mirror.serves("web-deepseek-api") ? .api : .plain
        case (.search, "deepseek-official"):
            return mirror.serves("web-search-deepseek") ? .legacy : .plain
        case (.fetch, "http"), (.search, Self.builtInAuto):
            return .plain
        default:
            return listed == nil ? .plain : .plugin
        }
    }

    /// Stage one selection. Automatic selection and a target equal to the composed value clear the
    /// override, so the deployment's choice keeps applying instead of a stored copy of it.
    private func select(_ capability: Capability, _ id: String) {
        let field = capability.provider
        if id.isEmpty || mirror.namespace("web")?["base"][field].string == id {
            selection.reset(field, mirror)
        } else {
            selection.edit(field, id, mirror)
        }
        // A key typed for legacy search is not written once the page stops showing its field.
        if panel(.search) != .legacy { keyDraft = "" }
    }

    /// Read the registered providers. Only the latest read lands; a failed one keeps the last list
    /// and has the page say its menus may be incomplete.
    private func loadProviders() async {
        providerRead += 1
        let read = providerRead
        do {
            let list = try await app.client.call("web/listProviders")
            guard read == providerRead else { return }
            providers = list
            providersFailed = false
        } catch {
            guard read == providerRead, !Task.isCancelled else { return }
            providersFailed = true
        }
    }

    // MARK: Billing

    /// The DeepSeek credential one API sends, and so who pays for it.
    private func billingPicker(_ capability: Capability) -> some View {
        Picker("计费方式", selection: Binding(get: { billing(capability) }, set: { selectBilling(capability, $0) })) {
            Text("自动").tag("auto")
            Text("DeepSeek 账号").tag("account")
            Text("DeepSeek API Key").tag("api-key")
        }
        .pickerStyle(.menu)
        .pickerValueTint()
        .disabled(!endpointOverrides(capability).isEmpty)
    }

    @ViewBuilder
    private func billingNote(_ capability: Capability) -> some View {
        let fields = endpointOverrides(capability).joined(separator: String(localized: "、"))
        if !fields.isEmpty {
            Text("已被 \(fields) 覆盖，这里选的不生效。")
        } else {
            switch billing(capability) {
            case "account": Text("要先登录 DeepSeek 账号。")
            case "api-key": Text("用「模型」里填的 DeepSeek API Key，要先填好。")
            default: Text("跟随当前对话用的 DeepSeek 账号或 API Key；对话用其他模型时，先用 API Key，没有再用已登录的账号。")
            }
        }
    }

    /// The staged billing; a section that carries none reads as `auto`.
    private func billing(_ capability: Capability) -> String {
        let text = api.text(capability.billing, mirror)
        return Self.billings.contains(text) ? text : "auto"
    }

    /// Stage one billing; the composed one, `auto` when the deployment composes none, clears the override.
    private func selectBilling(_ capability: Capability, _ target: String) {
        let field = capability.billing
        let composed = mirror.namespace("web-deepseek-api")?["base"][field].string ?? "auto"
        if composed == target { api.reset(field, mirror) } else { api.edit(field, target, mirror) }
    }

    /// The API's own endpoint fields that are set. With any of them the provider uses that endpoint
    /// and key whatever the billing, so the menu is locked and the note names them.
    private func endpointOverrides(_ capability: Capability) -> [String] {
        let section = mirror.namespace("web-deepseek-api")?["value"]
        return capability.endpoint.filter { section?[$0].string?.isEmpty == false }
    }

    // MARK: Legacy Messages search

    private var legacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key").font(.caption).foregroundStyle(Palette.secondary)
                SecureField(credential?["configured"].bool == true ? String(localized: "已配置，留空不修改") : String(localized: "输入 API Key"), text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
                    .disabled(credential?["writable"].bool == false)
            }
            StagedField(form: messages, key: "baseURL", title: "API 地址", keyboard: .URL)
            StagedField(form: messages, key: "maxUses", title: "单次请求最多搜索次数")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("DeepSeek 账号模型的对话用已登录的账号搜索，其他对话用这个 Key，默认和「模型」里的 DeepSeek API Key 是同一个。")
                Text("地址含 API 前缀，留空用默认。")
            }
        }
        .groupedRow()
    }

    private func readCredential() async {
        credential = (try? await mirror.describeCredentials([ref]))?[ref]
    }

    // MARK: Saving

    private func discard() {
        selection.discard()
        api.discard()
        messages.discard()
        keyDraft = ""
    }

    /// Provider settings before the selection, so a switch applies only once what it uses has landed.
    private func save() async -> Bool {
        saving = true
        defer { saving = false }
        for form in [api, messages] where form.dirty {
            guard await form.save(mirror) else { return false }
        }
        if selection.dirty, !(await selection.save(mirror)) { return false }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                try await mirror.setCredential(ref, key)
                keyDraft = ""
                await readCredential()
            } catch {
                app.showToast(describeFailure(error), duration: 5)
                return false
            }
        }
        return true
    }
}
