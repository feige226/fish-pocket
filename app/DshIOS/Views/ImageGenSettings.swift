import SafariServices
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → 生图: dsh-image-gen's settings, every field its own settings card in the web version
/// has. The first page is a short list: the default provider, then the providers by how they
/// are reached (subscription sign-in, API key, local ComfyUI), marked only once set up. Each
/// provider's page shows the key, address and model, the rest one level down under 更多选项;
/// OpenAI-compatible channels are kept on that provider's page. What is rarely changed (the
/// timeout, saving to the workspace, the web composer's capsule, the cache) is under 更多设置.
/// The canvas, gallery and Studio are the plugin's own pages in the web version.
struct ImageGenSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var keys: [String: JSON] = [:]
    @State private var failure: String?

    private var mirror: SettingsMirror { app.settings }
    private var value: JSON { mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null }
    private var writable: Bool { mirror.writable }
    private var provider: ImageGenProvider { ImageGenProvider(rawValue: value["provider"].string ?? "") ?? .google }
    /// The user's own channels; the Fish Pocket one is the app's and has a row of its own.
    private var channels: [ImageGenChannel] { ImageGenChannel.all(value).filter { $0.id != FishPocketImageGen.channelID } }

    /// What 默认使用 offers: every provider, and the Fish Pocket account where the build has it.
    private enum Choice: Hashable {
        case fishPocket
        case provider(ImageGenProvider)
    }

    private var choice: Choice { FishPocketImageGen.isChosen(value) ? .fishPocket : .provider(provider) }

    var body: some View {
        List {
            if !mirror.serves(ImageGenModel.namespace) {
                Section {
                    if mirror.loaded {
                        Text("生图插件还没有启动。它随 App 内置，引擎启动后就会出现；如果一直没有，可以在「插件」里看它是否被关闭了。")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            } else {
                content
            }
        }
        .groupedList()
        .navigationTitle("生图")
        .navigationBarTitleDisplayMode(.inline)
        .followSettings()
        .task(id: mirror.stamp) {
            await loadKeys()
            // Also once the plugin has come up, when the page opened before it did.
            await app.imageGen.refreshAccounts()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !writable {
            Section { Text("设置由配置文件提供，是只读的。").foregroundStyle(.secondary) }
        }

        Section {
            Picker("默认使用", selection: Binding(get: { choice }, set: { pick($0) })) {
                if FishPocketImageGen.available { Text("Fish Pocket 账号（Seedream）").tag(Choice.fishPocket) }
                ForEach(ImageGenProvider.allCases) { Text($0.title).tag(Choice.provider($0)) }
            }
            .pickerStyle(.navigationLink)
            .disabled(!writable)
        } footer: {
            Text("智能体画图时用它，对话里也能临时换别家。")
        }
        .groupedRow()

        if FishPocketImageGen.available {
            Section {
                NavigationLink { ImageGenFishPocketPage() } label: {
                    LabeledContent("Fish Pocket 账号") {
                        if choice == .fishPocket { Text("正在使用") }
                    }
                }
            } header: {
                Text("用积分 · 不用 API Key")
            }
            .groupedRow()
        }

        Section {
            ForEach(ImageGenProvider.subscriptions) { item in
                NavigationLink { ImageGenSubscriptionPage(provider: item) } label: {
                    LabeledContent(item.listTitle) { Text(account(item)) }
                }
            }
        } header: {
            Text("订阅账号 · 不用 API Key")
        }
        .groupedRow()

        Section {
            ForEach(ImageGenProvider.keyed) { item in
                NavigationLink {
                    ImageGenProviderPage(provider: item, channel: item == .openaiCompat ? channels.first : nil)
                } label: {
                    LabeledContent(item.listTitle) { if configured(item) { ConfiguredMark() } }
                }
            }
        } header: {
            Text("API Key")
        }
        .groupedRow()

        Section {
            NavigationLink { ImageGenComfyPage() } label: {
                LabeledContent(ImageGenProvider.comfyui.listTitle) {
                    if !ImageGenWorkflow.all(value).isEmpty { ConfiguredMark() }
                }
            }
        } header: {
            Text("本地")
        }
        .groupedRow()

        Section {
            NavigationLink("更多设置") { ImageGenMoreSettingsPage() }
            Button { app.webRequest = UUID() } label: {
                HStack {
                    Text("在网页版打开画布和图库").foregroundStyle(Palette.ink)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .groupedRow()

        if let failure {
            Section { Text(failure).foregroundStyle(.red) }
        }
    }

    /// A subscription's account when signed in; otherwise the way in.
    private func account(_ item: ImageGenProvider) -> String {
        let account = app.imageGen.accounts[item] ?? ImageGenAccount()
        switch account.state {
        case .signedIn: return account.email ?? String(localized: "已登录")
        case .signedOut: return String(localized: "登录")
        case .unknown: return ""
        }
    }

    /// A key saved for it (for OpenAI compatible, for any of its channels).
    private func configured(_ item: ImageGenProvider) -> Bool {
        let refs = item == .openaiCompat ? channels.map(\.keyRef) : [item.credentialRef ?? ""]
        return refs.contains { keys[$0]?["configured"].bool == true }
    }

    private func loadKeys() async {
        let refs = ImageGenProvider.allCases.compactMap(\.credentialRef) + channels.map(\.keyRef)
        if let described = try? await mirror.describeCredentials(refs) { keys = described }
    }

    private func save(_ field: String, _ next: JSON) {
        Task {
            do {
                failure = nil
                try await mirror.set(ImageGenModel.namespace, [field], next)
            } catch {
                failure = describeFailure(error)
            }
        }
    }

    /// 默认使用 changed. Leaving the Fish Pocket channel for OpenAI compatible goes back to the
    /// user's own default channel.
    private func pick(_ next: Choice) {
        Task {
            do {
                failure = nil
                switch next {
                case .fishPocket:
                    try await FishPocketImageGen.choose(in: mirror)
                case .provider(let item):
                    var ops: [SettingsOp] = [.set(["provider"], .string(item.rawValue))]
                    if item == .openaiCompat, FishPocketImageGen.isChosen(value) {
                        ops.append(.set(["openaiCompatActiveChannel"], .string(ImageGenChannel.defaultID)))
                    }
                    try await mirror.mutate(ImageGenModel.namespace, ops, expectedRevision: mirror.namespace(ImageGenModel.namespace)?["revision"].int)
                }
            } catch {
                failure = describeFailure(error)
            }
        }
    }
}

/// 生图 → Fish Pocket 账号: images paid in credits, through the Fish Pocket service, with no key
/// of the user's own. What it is, the account it is paid from, and the switch to use it.
struct ImageGenFishPocketPage: View {
    @Environment(AppModel.self) private var app
    @State private var failure: String?
    @State private var working = false

    private var mirror: SettingsMirror { app.settings }
    private var value: JSON { mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null }

    var body: some View {
        List {
            Section {
                Text("用 Fish Pocket 账号的积分生图，不用自己开通火山方舟。模型是即梦 Seedream 5.5，按生成的张数计费：图越大、参考图越多，扣得越多；没生成出来的不扣。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            Section {
                let account = app.fishPocket
                NavigationLink { FishPocketPage() } label: {
                    if account.signedIn {
                        LabeledContent {
                            if let balance = account.balance { Text("\(balance) 积分").monospacedDigit() }
                        } label: {
                            Text(account.user?.label ?? String(localized: "已登录"))
                        }
                    } else {
                        Text("登录 Fish Pocket 账号")
                    }
                }
            } header: {
                Text("Fish Pocket 账号")
            } footer: {
                Text("提示词和参考图经 Fish Pocket 的服务器转给火山方舟，服务器不保存。生成的图都带「AI生成」水印，用 Fish Pocket 账号时不能关闭。")
            }
            .groupedRow()

            Section {
                if FishPocketImageGen.isChosen(value) {
                    Label("正在使用", systemImage: "checkmark.circle.fill").foregroundStyle(.green).frame(maxWidth: .infinity)
                } else {
                    Button {
                        use()
                    } label: {
                        HStack(spacing: 8) {
                            if working { ProgressView().tint(Palette.onInk) }
                            Text("设为默认")
                        }
                    }
                    .buttonStyle(.capsule(height: 50))
                    .disabled(working || !mirror.writable || !app.fishPocket.signedIn)
                }
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                } else if !app.fishPocket.signedIn {
                    Text("登录后才能用。").frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .groupedList()
        .navigationTitle("Fish Pocket 账号")
        .navigationBarTitleDisplayMode(.inline)
        .followSettings()
        .task { await app.fishPocket.refresh() }
    }

    private func use() {
        working = true
        failure = nil
        Task {
            do {
                try await FishPocketImageGen.choose(in: mirror)
                Haptics.success()
            } catch {
                failure = describeFailure(error)
            }
            working = false
        }
    }
}

/// The mark of a provider that is set up.
private struct ConfiguredMark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.green)
            .accessibilityLabel("已配置")
    }
}

/// A text field on the right of a settings row.
private struct TrailingField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(keyboard)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

// MARK: - More settings

/// What applies to every provider and is rarely changed: the cloud timeout, saving to the
/// workspace, the web composer's provider capsule, and the file-level options the plugin's
/// card leaves to its configuration file (the folder paths and the host-admission switch stay
/// out: the folders are the engine's own, and the switch would turn away these very pages).
struct ImageGenMoreSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var timeout = ""
    @State private var folder = ""
    @State private var ttl = ""
    @State private var limit = ""
    @State private var failure: String?

    private var mirror: SettingsMirror { app.settings }
    private var value: JSON { mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null }

    var body: some View {
        List {
            Section {
                LabeledContent("云端生成超时（秒）") {
                    TrailingField(placeholder: "150", text: $timeout, keyboard: .numberPad).onSubmit(commitTimeout)
                }
            } footer: {
                Text("用 API Key 的服务商共用，5–3600 秒，默认 150 秒。")
            }
            .groupedRow()

            Section {
                toggle("保存到工作区", "saveToWorkspace", fallback: true)
                if value["saveToWorkspace"].bool ?? true {
                    LabeledContent("文件夹") {
                        TrailingField(placeholder: "dsh-image-gen", text: $folder).onSubmit(commitFolder)
                    }
                }
            } footer: {
                Text("每张图另存一份到当前会话工作区的这个文件夹，留空存在工作区根目录。")
            }
            .groupedRow()

            Section {
                toggle("网页版输入栏显示生图切换胶囊", "showProviderPill", fallback: false)
            }
            .groupedRow()

            Section {
                toggle("严格下载生成结果", "strictImageDownloads", fallback: false)
                toggle("保留原图", "vaultEnabled", fallback: true)
                toggle("自动清理请求缓存", "requestCachePrune", fallback: true)
                if value["requestCachePrune"].bool ?? true {
                    LabeledContent("保留天数") {
                        TrailingField(placeholder: "14", text: $ttl, keyboard: .numberPad).onSubmit(commitTTL)
                    }
                    LabeledContent("上限（MB）") {
                        TrailingField(placeholder: "256", text: $limit, keyboard: .numberPad).onSubmit(commitLimit)
                    }
                }
            } header: {
                Text("高级")
            } footer: {
                Text("严格下载：服务商返回图片链接时，只从公网地址下载并核对是图片。保留原图：另存服务商给的原始文件（完整 GIF、原始分辨率）。请求缓存：发给服务商的参考图缩放后的副本，超过天数或上限时删掉旧的，上限填 0 表示不限。")
            }
            .groupedRow()

            if let failure { Section { Text(failure).foregroundStyle(.red) } }

            Section {} footer: {
                Text("生图由内置的 dsh-image-gen 插件（Apache-2.0）提供。它的灵感库收录了 yang0 的手绘风格手册（github.com/yang0/handraw-style，MIT）、JimLiu/baoyu-skills 的封面构图（MIT）和 freestylefly/awesome-gpt-image-2 的案例集（MIT）。")
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.immediately)
        .disabled(!mirror.writable)
        .navigationTitle("更多设置")
        .navigationBarTitleDisplayMode(.inline)
        .followSettings()
        .task(id: mirror.stamp) {
            timeout = String((value["cloudTimeoutMs"].int ?? 150_000) / 1000)
            folder = value["workspaceFolder"].string ?? "dsh-image-gen"
            ttl = String(value["requestCacheTtlDays"].int ?? 14)
            limit = String((value["requestCacheMaxBytes"].int ?? 256 * 1024 * 1024) / (1024 * 1024))
        }
        .onDisappear { commitTimeout(); commitFolder(); commitTTL(); commitLimit() }
    }

    private func toggle(_ title: LocalizedStringKey, _ field: String, fallback: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { value[field].bool ?? fallback }, set: { save(field, .bool($0)) })).inkTint()
    }

    private func commitTimeout() {
        let current = value["cloudTimeoutMs"].int ?? 150_000
        guard let seconds = Int(timeout.trimmed), (5...3600).contains(seconds) else { timeout = String(current / 1000); return }
        if seconds * 1000 != current { save("cloudTimeoutMs", .number(Double(seconds * 1000))) }
    }

    private func commitFolder() {
        let next = folder.trimmed
        if next != (value["workspaceFolder"].string ?? "dsh-image-gen") { save("workspaceFolder", .string(next)) }
    }

    private func commitTTL() {
        let current = value["requestCacheTtlDays"].int ?? 14
        guard let days = Int(ttl.trimmed), (1...365).contains(days) else { ttl = String(current); return }
        if days != current { save("requestCacheTtlDays", .number(Double(days))) }
    }

    private func commitLimit() {
        let current = value["requestCacheMaxBytes"].int ?? 256 * 1024 * 1024
        guard let megabytes = Int(limit.trimmed), megabytes >= 0 else { limit = String(current / (1024 * 1024)); return }
        if megabytes * 1024 * 1024 != current { save("requestCacheMaxBytes", .number(Double(megabytes * 1024 * 1024))) }
    }

    private func save(_ field: String, _ next: JSON) {
        Task {
            do {
                failure = nil
                try await mirror.set(ImageGenModel.namespace, [field], next)
            } catch {
                failure = describeFailure(error)
            }
        }
    }
}

extension ImageGenChannel {
    /// A channel to fill in, saved only with the page's 保存 (the plugin's `addCompatChannel`).
    static func fresh(after channels: [ImageGenChannel]) -> ImageGenChannel {
        let id = "channel-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))-\(String(UInt32.random(in: 0..<UInt32.max), radix: 36).prefix(5))"
        var channel = ImageGenChannel(id: id, label: String(localized: "OpenAI 兼容 \(channels.count + 1)"), keyRef: keyRef(for: id))
        channel.qualityOptions = defaultQualities
        return channel
    }
}

// MARK: - A cloud provider

/// What one API-key provider's pages edit, saved together with 保存 as the plugin's provider
/// row saves its form: the key, address and model on the provider's page, the rest on its
/// 更多选项 page. Testing and fetching models read the saved settings, so they ask for unsaved
/// changes to be saved first, as the plugin does.
@MainActor
@Observable
final class ImageGenDraft {
    struct Note: Equatable {
        let text: String
        let error: Bool
    }

    let provider: ImageGenProvider
    /// The OpenAI-compatible channel; nil for every other provider.
    let channel: ImageGenChannel?
    let isNew: Bool

    var label = ""
    var key = ""
    var keyInfo: JSON?
    var baseURL = ""
    var googleNative = false
    var model = ""
    var models: [String] = []
    var editModel = ""
    var editFormat = "multipart"
    var outputFormat = "jpeg"
    var watermark = true
    var background = "opaque"
    var sizeTable = ""
    var quality = ""
    var qualityOptions = ""
    var generateExtra = ""
    var editSizeMode = "auto"
    var editExtra = ""

    var fetched: [String] = []
    var fetchNote: Note?
    var note: Note?
    var saving = false
    var testing = false
    var fetching = false

    init(provider: ImageGenProvider, channel: ImageGenChannel?, isNew: Bool) {
        self.provider = provider
        self.channel = channel
        self.isNew = isNew
    }

    var compat: Bool { provider == .openaiCompat }
    /// An OpenAI-compatible channel other than the first, which the provider's own fields hold.
    var addedChannel: Bool { channel?.isDefault == false }
    var keyRef: String { channel?.keyRef ?? provider.credentialRef ?? "" }
    var keyConfigured: Bool { keyInfo?["configured"].bool == true }
    var keyReadOnly: Bool { keyInfo?["writable"].bool == false }
    var busy: Bool { saving || testing || fetching }
    /// The edit request an official API gets whatever is chosen here.
    var automaticFormat: String? { compat ? ImageGenChannel.officialEditFormat(baseURL: baseURL, model: editModel.trimmed.nonEmpty ?? model) : nil }
    var effectiveFormat: String { automaticFormat ?? editFormat }
    /// Routes take an added channel's id; the first channel is the provider's own row.
    var channelID: String? { addedChannel ? channel?.id : nil }

    static func defaultValue(_ field: String?, in mirror: SettingsMirror) -> String? {
        guard let field, let graph = mirror.graph(ImageGenModel.namespace) else { return nil }
        return graph.fields(graph.root).first { $0.key == field }?.node.defaultValue?.string
    }

    func fill(from mirror: SettingsMirror) {
        let value = mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null
        if let channel {
            label = channel.label
            baseURL = channel.baseURL
            model = channel.model
            models = ImageGenChannel.modelList(channel.model, channel.models)
            editModel = channel.editModel
            editFormat = ["jsonImageUrlArray", "formReferenceImages", "siliconflowJson", "modelscopeAsync"].contains(channel.editFormat) ? channel.editFormat : "multipart"
            sizeTable = Self.text(channel.sizes)
            quality = channel.quality
            qualityOptions = (channel.qualityOptions.isEmpty ? ImageGenChannel.defaultQualities : channel.qualityOptions).joined(separator: ", ")
            generateExtra = Self.text(channel.extraBody)
            editSizeMode = channel.editSizeMode
            editExtra = Self.text(channel.editExtra)
        } else {
            baseURL = provider.urlField.flatMap { value[$0].string?.nonEmpty } ?? Self.defaultValue(provider.urlField, in: mirror) ?? ""
            model = provider.modelField.flatMap { value[$0].string?.nonEmpty } ?? Self.defaultValue(provider.modelField, in: mirror) ?? ""
            googleNative = value["googleNative"].bool ?? false
            sizeTable = Self.text(value["openaiSizes"])
            outputFormat = value["seedreamOutputFormat"].string == "png" ? "png" : "jpeg"
            watermark = value["seedreamWatermark"].bool != false
            background = value["seedreamBackground"].string == "transparent" ? "transparent" : "opaque"
        }
    }

    func loadKey(from mirror: SettingsMirror) async {
        guard !keyRef.isEmpty else { return }
        keyInfo = try? await mirror.describeCredentials([keyRef])[keyRef]
    }

    /// The plugin's `providerActionBlockMessage`: testing reads the saved settings.
    func unsavedReason(in mirror: SettingsMirror) -> String? {
        let value = mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null
        if !key.trimmed.isEmpty { return String(localized: "请先保存 API Key，再拉取模型或测试连接。") }
        if baseURL.trimmed.isEmpty { return String(localized: "请填写接口地址并保存，再拉取模型或测试连接。") }
        let saved: String
        if let channel {
            saved = isNew ? "" : ImageGenChannel.all(value).first { $0.id == channel.id }?.baseURL ?? ""
        } else {
            saved = provider.urlField.flatMap { value[$0].string?.nonEmpty } ?? Self.defaultValue(provider.urlField, in: mirror) ?? ""
        }
        if baseURL.trimmed != saved.trimmed { return String(localized: "接口地址还没有保存，请先点「保存」，再拉取模型或测试连接。") }
        if provider == .google, googleNative != (value["googleNative"].bool ?? false) { return String(localized: "请求协议还没有保存，请先点「保存」，再拉取模型或测试连接。") }
        return nil
    }

    func test(_ model: ImageGenModel, mirror: SettingsMirror) async {
        if let reason = unsavedReason(in: mirror) { note = Note(text: reason, error: false); return }
        testing = true
        note = nil
        switch await model.test(provider, channel: channelID) {
        case .ok: note = Note(text: String(localized: "连接成功"), error: false); Haptics.success()
        case .failed(let reason): note = Note(text: reason, error: true); Haptics.error()
        case .models: break
        }
        testing = false
    }

    func fetchModels(_ model: ImageGenModel, mirror: SettingsMirror) async {
        if let reason = unsavedReason(in: mirror) { fetchNote = Note(text: reason, error: false); return }
        fetching = true
        fetchNote = nil
        switch await model.models(provider, channel: channelID) {
        case .models(let list):
            fetched = list
            fetchNote = list.isEmpty
                ? Note(text: String(localized: "没有筛出能生图的模型，可以直接输入模型名。"), error: true)
                : Note(text: String(localized: "找到 \(list.count) 个生图模型，点一下就能选用。"), error: false)
        case .failed(let reason): fetchNote = Note(text: reason, error: true)
        case .ok: break
        }
        fetching = false
    }

    func pick(_ id: String) {
        if compat {
            models = ImageGenChannel.modelList(model, models + [id])
            if model.trimmed.isEmpty { model = id }
        } else {
            model = id
        }
    }

    /// Write every field at once (`settings/mutate`), then the key. True when saved.
    @discardableResult
    func save(to mirror: SettingsMirror) async -> Bool {
        saving = true
        note = nil
        defer { saving = false }
        let value = mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null
        do {
            var ops: [SettingsOp] = []
            let editExtraValue = try Self.object(editExtra)
            let generateExtraValue = try Self.object(generateExtra)
            let sizes = try Self.sizeTable(sizeTable)
            let qualityList = qualityOptions.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if provider == .openai {
                for tiers in sizes.object.values { for size in tiers.object.values { if let problem = Self.officialSizeProblem(model: model, size: size.string ?? "") { throw Problem(problem) } } }
            }
            if let channel, !channel.isDefault {
                let name = label.trimmed
                if name.isEmpty { throw Problem(String(localized: "请填写渠道名称。")) }
                var updated = channel
                updated.label = name
                updated.baseURL = baseURL.trimmed
                updated.model = model.trimmed
                updated.models = ImageGenChannel.modelList(model, models)
                updated.editModel = editModel.trimmed
                updated.quality = quality.trimmed
                updated.qualityOptions = qualityList
                updated.extraBody = generateExtraValue
                updated.editSizeMode = editSizeMode
                updated.editFormat = editFormat
                updated.editExtra = editExtraValue
                updated.sizes = sizes
                var added = Array(ImageGenChannel.all(value).dropFirst())
                if let index = added.firstIndex(where: { $0.id == channel.id }) { added[index] = updated } else { added.append(updated) }
                ops.append(.set(["openaiCompatChannels"], .array(added.map(\.stored))))
            } else {
                if let field = provider.modelField { ops.append(.set([field], .string(compat ? model.trimmed : model))) }
                if let field = provider.urlField { ops.append(.set([field], .string(baseURL))) }
                switch provider {
                case .google: ops.append(.set(["googleNative"], .bool(googleNative)))
                case .openai: ops.append(.set(["openaiSizes"], sizes))
                case .openaiCompat:
                    ops += [
                        .set(["openaiCompatLabel"], .string(label.trimmed)),
                        .set(["openaiCompatModels"], .array(ImageGenChannel.modelList(model, models).map { .string($0) })),
                        .set(["openaiCompatEditModel"], .string(editModel.trimmed)),
                        .set(["openaiCompatEditFormat"], .string(editFormat)),
                        .set(["openaiCompatEditExtra"], editExtraValue),
                        .set(["openaiCompatSizes"], sizes),
                        .set(["openaiCompatQuality"], .string(quality.trimmed)),
                        .set(["openaiCompatQualityOptions"], .array(qualityList.map { .string($0) })),
                        .set(["openaiCompatExtraBody"], generateExtraValue),
                        .set(["openaiCompatEditSizeMode"], .string(editSizeMode)),
                    ]
                case .seedream:
                    ops += [
                        .set(["seedreamOutputFormat"], .string(outputFormat)),
                        .set(["seedreamWatermark"], .bool(watermark)),
                        .set(["seedreamBackground"], .string(background)),
                    ]
                default: break
                }
            }
            try await mirror.mutate(ImageGenModel.namespace, ops, expectedRevision: mirror.namespace(ImageGenModel.namespace)?["revision"].int)
            let typed = key.trimmed
            if !typed.isEmpty {
                try await mirror.setCredential(keyRef, typed)
                key = ""
                await loadKey(from: mirror)
            }
            fetchNote = nil
            note = Note(text: String(localized: "已保存"), error: false)
            Haptics.success()
            return true
        } catch let problem as Problem {
            note = Note(text: problem.message, error: true)
        } catch {
            note = Note(text: describeFailure(error), error: true)
        }
        Haptics.error()
        return false
    }

    func clearKey(in mirror: SettingsMirror) async {
        do {
            try await mirror.unsetCredential(keyRef)
            await loadKey(from: mirror)
            note = Note(text: String(localized: "已清除 Key"), error: false)
        } catch {
            note = Note(text: describeFailure(error), error: true)
        }
    }

    func remove(in mirror: SettingsMirror) async -> Bool {
        guard let channel else { return false }
        let value = mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null
        do {
            let rest = ImageGenChannel.all(value).dropFirst().filter { $0.id != channel.id }
            var ops: [SettingsOp] = [.set(["openaiCompatChannels"], .array(rest.map(\.stored)))]
            if value["openaiCompatActiveChannel"].string == channel.id { ops.append(.set(["openaiCompatActiveChannel"], "default")) }
            try await mirror.mutate(ImageGenModel.namespace, ops, expectedRevision: mirror.namespace(ImageGenModel.namespace)?["revision"].int)
            return true
        } catch {
            note = Note(text: describeFailure(error), error: true)
            return false
        }
    }

    struct Problem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A JSON object as one line, or blank for an empty one (the plugin's `editExtraTextOf`).
    static func text(_ value: JSON) -> String {
        value.object.isEmpty ? "" : value.compactText
    }

    /// `parseExtraFields`: blank is `{}`, anything else must be a JSON object.
    static func object(_ text: String) throws -> JSON {
        let source = text.trimmed
        if source.isEmpty { return .object([:]) }
        guard let value = try? JSON.parse(Data(source.utf8)), case .object = value else {
            throw Problem(String(localized: "附加 JSON 字段必须是合法的 JSON 对象。"))
        }
        return value
    }

    /// `parseSizeTable`: ratio → tier (`2K`, `1.5K`, `1024`) → a non-empty size.
    static func sizeTable(_ text: String) throws -> JSON {
        let invalid = Problem(String(localized: "分辨率表要写成「比例 → 档位（如 2K）→ 尺寸」的 JSON 对象。"))
        guard let table = try? object(text) else { throw invalid }
        var result: [String: JSON] = [:]
        for (ratio, tiers) in table.object {
            let parts = ratio.split(separator: ":").compactMap { Double($0) }
            guard ratio.range(of: #"^\d+(?:\.\d+)?:\d+(?:\.\d+)?$"#, options: .regularExpression) != nil, parts.count == 2, parts.allSatisfy({ $0 > 0 }),
                  case .object(let entries) = tiers, !entries.isEmpty else { throw invalid }
            var row: [String: JSON] = [:]
            for (tier, size) in entries {
                guard tier.range(of: #"^(\d+(?:\.\d+)?)(K?)$"#, options: .regularExpression) != nil, (Double(tier.replacingOccurrences(of: "K", with: "")) ?? 0) > 0,
                      let text = size.string?.trimmed, !text.isEmpty else { throw invalid }
                row[tier] = .string(text)
            }
            result[ratio] = .object(row)
        }
        return .object(result)
    }

    /// `validateOfficialSize` for the official OpenAI API.
    static func officialSizeProblem(model: String, size: String) -> String? {
        if size == "auto" { return nil }
        guard model.range(of: #"^gpt-image-2(?:$|[-.])"#, options: .regularExpression) != nil else {
            return ["1024x1024", "1536x1024", "1024x1536"].contains(size) ? nil : String(localized: "模型 \(model) 不支持尺寸 \(size)，请用 1024x1024、1536x1024 或 1024x1536。")
        }
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, size.range(of: #"^\d+x\d+$"#, options: .regularExpression) != nil else {
            return String(localized: "OpenAI 尺寸 \(size) 无效：边长要是 16 的倍数且不超过 3840，比例在 1:3 到 3:1 之间，像素数在 655360 到 8294400 之间。")
        }
        let (width, height) = (parts[0], parts[1])
        let pixels = width * height
        if width % 16 != 0 || height % 16 != 0 || max(width, height) > 3840 || pixels < 655_360 || pixels > 8_294_400 || max(width, height) > 3 * min(width, height) {
            return String(localized: "OpenAI 尺寸 \(size) 无效：边长要是 16 的倍数且不超过 3840，比例在 1:3 到 3:1 之间，像素数在 655360 到 8294400 之间。")
        }
        return nil
    }
}

/// One API-key provider, or one OpenAI-compatible channel: key, address and model, a test,
/// the channels (on OpenAI compatible), and the rest under 更多选项.
struct ImageGenProviderPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ImageGenDraft
    @State private var keys: [String: JSON] = [:]
    @State private var loaded = false
    @State private var confirmingRemoval = false

    init(provider: ImageGenProvider, channel: ImageGenChannel?, isNew: Bool = false) {
        _draft = State(initialValue: ImageGenDraft(provider: provider, channel: channel, isNew: isNew))
    }

    private var mirror: SettingsMirror { app.settings }
    private var value: JSON { mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null }
    /// The provider's own page of OpenAI compatible, which lists the other channels.
    private var channelsHere: Bool { draft.compat && !draft.addedChannel }

    var body: some View {
        List {
            Section {
                if draft.addedChannel {
                    LabeledContent("名称") { TrailingField(placeholder: String(localized: "渠道名称"), text: $draft.label) }
                }
                LabeledContent("API Key") {
                    if draft.keyReadOnly {
                        Text("由 \(draft.keyInfo?["source"].string ?? "") 提供").foregroundStyle(.secondary)
                    } else {
                        SecureField(draft.keyConfigured ? String(localized: "已配置") : String(localized: "未填写"), text: $draft.key)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                LabeledContent("接口地址") {
                    TrailingField(placeholder: draft.compat ? "https://…/v1" : "https://", text: $draft.baseURL, keyboard: .URL)
                }
                LabeledContent("模型") {
                    HStack(spacing: 10) {
                        TrailingField(placeholder: String(localized: "未填写"), text: $draft.model)
                        Button {
                            Task { await draft.fetchModels(app.imageGen, mirror: mirror) }
                        } label: {
                            if draft.fetching { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .buttonStyle(.borderless)
                        .disabled(draft.busy)
                        .accessibilityLabel("拉取模型")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let fetchNote = draft.fetchNote {
                        Text(fetchNote.text).foregroundStyle(fetchNote.error ? .red : .secondary)
                    }
                    Text("Key 只保存在这台设备上，页面不会读回明文。")
                    HStack(spacing: 16) {
                        if let url = draft.provider.consoleURL { Link("去官方获取 Key", destination: url) }
                        if !draft.compat, let fallback = ImageGenDraft.defaultValue(draft.provider.urlField, in: mirror), draft.baseURL != fallback {
                            Button("恢复默认接口地址") { draft.baseURL = fallback }
                        }
                    }
                }
            }
            .groupedRow()

            if !draft.fetched.isEmpty {
                Section {
                    ForEach(draft.fetched, id: \.self) { id in
                        Button { draft.pick(id) } label: {
                            HStack {
                                Text(id).font(.subheadline.monospaced()).foregroundStyle(Palette.ink).lineLimit(1)
                                Spacer()
                                if draft.model == id { Image(systemName: "checkmark").foregroundStyle(Palette.ink) }
                            }
                        }
                    }
                } header: {
                    Text("拉取到的模型")
                }
                .groupedRow()
            }

            Section {
                Button {
                    Task { await draft.test(app.imageGen, mirror: mirror) }
                } label: {
                    HStack(spacing: 8) {
                        if draft.testing { ProgressView().tint(Palette.onInk) }
                        Text("测试连接")
                    }
                }
                .buttonStyle(.capsule(height: 50))
                .disabled(draft.busy)
            } footer: {
                if let note = draft.note {
                    Text(note.text).foregroundStyle(note.error ? .red : .secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if channelsHere {
                Section {
                    ForEach(ImageGenChannel.all(value).dropFirst().filter { $0.id != FishPocketImageGen.channelID }) { channel in
                        NavigationLink { ImageGenProviderPage(provider: .openaiCompat, channel: channel) } label: {
                            LabeledContent(channel.label) { if keys[channel.keyRef]?["configured"].bool == true { ConfiguredMark() } }
                        }
                    }
                    NavigationLink {
                        ImageGenProviderPage(provider: .openaiCompat, channel: ImageGenChannel.fresh(after: ImageGenChannel.all(value)), isNew: true)
                    } label: {
                        Label("添加渠道", systemImage: "plus")
                    }
                    .disabled(!mirror.writable)
                } header: {
                    Text("其他渠道")
                } footer: {
                    Text("每个渠道单独配置地址、Key 和模型，对话里可以指定用哪个渠道。")
                }
                .groupedRow()
            }

            Section {
                if !optionsSummary.isEmpty {
                    NavigationLink { ImageGenProviderOptionsPage(draft: draft) } label: {
                        LabeledContent("更多选项") { Text(optionsSummary).lineLimit(1) }
                    }
                }
                if draft.keyConfigured, !draft.keyReadOnly {
                    Button("清除 API Key", role: .destructive) { Task { await draft.clearKey(in: mirror) } }.disabled(draft.busy)
                }
                if draft.addedChannel, !draft.isNew {
                    Button("删除渠道", role: .destructive) { confirmingRemoval = true }.disabled(draft.busy || !mirror.writable)
                }
            }
            .groupedRow()
        }
        .groupedList()
        .scrollDismissesKeyboard(.interactively)
        .disabled(!mirror.writable && !draft.testing)
        .navigationTitle(draft.addedChannel ? (draft.label.trimmed.nonEmpty ?? draft.provider.title) : draft.provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { saveButton }
        .confirmationDialog("删除「\(draft.channel?.label ?? "")」？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("删除渠道", role: .destructive) {
                Task { if await draft.remove(in: mirror) { dismiss() } }
            }
        } message: {
            Text("这个渠道的配置会被删除。")
        }
        .followSettings()
        .task {
            guard !loaded else { return }
            loaded = true
            draft.fill(from: mirror)
            await draft.loadKey(from: mirror)
        }
        .task(id: mirror.stamp) {
            guard channelsHere else { return }
            keys = (try? await mirror.describeCredentials(ImageGenChannel.all(value).map(\.keyRef))) ?? keys
        }
    }

    private var optionsSummary: String {
        switch draft.provider {
        case .google: String(localized: "请求协议")
        case .openai: String(localized: "分辨率")
        case .openaiCompat: String(localized: "图生图、分辨率、质量")
        case .seedream: String(localized: "格式、水印、背景")
        default: ""
        }
    }

    @ToolbarContentBuilder
    private var saveButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if draft.saving { ProgressView() } else {
                Button("保存") {
                    Task { if await draft.save(to: mirror), draft.isNew { dismiss() } }
                }
                .disabled(draft.busy || !mirror.writable)
            }
        }
    }
}

/// The rest of a provider's fields, from its settings card: the address's default and what
/// it expects, Gemini's protocol, Seedream's output, OpenAI's size table, and an
/// OpenAI-compatible channel's name, models, edit request, quality and extra fields.
struct ImageGenProviderOptionsPage: View {
    @Bindable var draft: ImageGenDraft
    @Environment(AppModel.self) private var app

    private var mirror: SettingsMirror { app.settings }

    var body: some View {
        List {
            if draft.compat, !draft.addedChannel {
                Section {
                    LabeledContent("渠道名称") { TrailingField(placeholder: String(localized: "OpenAI 兼容"), text: $draft.label) }
                }
                .groupedRow()
            }

            if draft.provider == .google {
                Section {
                    Picker("请求协议", selection: $draft.googleNative) {
                        Text("Interactions（默认）").tag(false)
                        Text("原生 generateContent").tag(true)
                    }
                    .pickerValueTint()
                } footer: {
                    Text(draft.provider.endpointHint(googleNative: draft.googleNative))
                }
                .groupedRow()
            }

            if draft.provider == .seedream { seedream }
            if draft.compat { compat }
            if draft.provider == .openai || draft.compat {
                Section {
                    jsonEditor($draft.sizeTable, placeholder: #"{"16:9":{"2K":"2048x1152"}}"#, title: nil)
                } header: {
                    Text("自定义分辨率表（JSON）")
                } footer: {
                    Text("格式是「比例 → 档位 → 像素尺寸」，留空用默认尺寸。")
                }
                .groupedRow()
            }
            if let note = draft.note {
                Section { Text(note.text).foregroundStyle(note.error ? .red : .secondary) }
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.interactively)
        .disabled(!mirror.writable)
        .navigationTitle("更多选项")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if draft.saving { ProgressView() } else {
                    Button("保存") { Task { await draft.save(to: mirror) } }.disabled(draft.busy || !mirror.writable)
                }
            }
        }
    }

    private var seedream: some View {
        Section {
            Picker("输出格式", selection: $draft.outputFormat) {
                Text("JPEG（方舟默认，有损）").tag("jpeg")
                Text("PNG（无损，带透明通道）").tag("png")
            }
            .pickerValueTint()
            Picker("AI 生成水印", selection: $draft.watermark) {
                Text("添加（方舟默认）").tag(true)
                Text("不添加").tag(false)
            }
            .pickerValueTint()
            Picker("背景", selection: $draft.background) {
                Text("不透明（方舟默认）").tag("opaque")
                Text("透明").tag("transparent")
            }
            .pickerValueTint()
        } footer: {
            Text("JPEG 会在主体边缘留下压缩色斑，抠图时成了去不掉的彩色毛边，要后期加工就选 PNG。方舟默认在右下角加「AI 生成」标识，做素材时可以关掉。透明背景只对图生图有效，并且参考图本身要带透明通道。")
        }
        .groupedRow()
    }

    @ViewBuilder
    private var compat: some View {
        let choices = ImageGenChannel.modelList(draft.model, draft.models)
        if !choices.isEmpty {
            Section {
                ForEach(choices, id: \.self) { id in
                    let isDefault = draft.model.trimmed == id
                    Button {
                        guard !isDefault else { return }
                        let next = draft.models.contains(id) ? draft.models.filter { $0 != id } : draft.models + [id]
                        draft.models = ImageGenChannel.modelList(draft.model, next)
                    } label: {
                        HStack {
                            Image(systemName: "checkmark").opacity(isDefault || draft.models.contains(id) ? 1 : 0)
                            Text(id).font(.subheadline.monospaced()).lineLimit(1)
                            Spacer()
                            if isDefault { Text("默认").font(.caption).foregroundStyle(.secondary) }
                        }
                        .foregroundStyle(Palette.ink)
                    }
                }
            } header: {
                Text("工作台可选模型")
            } footer: {
                Text("勾选的模型可以在网页版工作台里切换。默认模型总在列表里。")
            }
            .groupedRow()
        }

        Section {
            LabeledContent("模型") { TrailingField(placeholder: String(localized: "同默认模型"), text: $draft.editModel) }
            Picker("请求形态", selection: Binding(get: { draft.automaticFormat == nil ? draft.editFormat : "__official__" }, set: { if $0 != "__official__" { draft.editFormat = $0 } })) {
                if draft.automaticFormat != nil { Text("自动：官方接口 JSON 格式").tag("__official__") }
                Text("标准 multipart（OpenAI 官方）").tag("multipart")
                Text("JSON images 数组（商汤等中转）").tag("jsonImageUrlArray")
                Text("multipart + reference_images JSON 数组（base64）").tag("formReferenceImages")
                Text("硅基流动 JSON（image 字符串）").tag("siliconflowJson")
            }
            .pickerStyle(.navigationLink)
            .disabled(draft.automaticFormat != nil)
            if ["jsonImageUrlArray", "qwenJson", "siliconflowJson", "modelscopeAsync"].contains(draft.effectiveFormat) {
                if draft.effectiveFormat == "jsonImageUrlArray" {
                    Picker("JSON 图生图尺寸", selection: $draft.editSizeMode) {
                        Text("自动（兼容商汤）").tag("auto")
                        Text("使用所选分辨率").tag("selected")
                    }
                    .pickerValueTint()
                }
                jsonEditor($draft.editExtra, placeholder: #"{"watermark": false, "prompt_extend": true}"#, title: "附加字段（JSON）")
            }
        } header: {
            Text("图生图")
        } footer: {
            switch draft.effectiveFormat {
            case "siliconflowJson": Text("硅基流动可以分别填 Qwen/Qwen-Image 和 Qwen/Qwen-Image-Edit。编辑尺寸由参考图决定，不发送尺寸和质量；Qwen-Image-Edit 支持一张图，Edit-2509 最多三张。")
            case "modelscopeAsync": Text("已识别为魔搭 ModelScope 官方地址：文生图和图生图都要等魔搭排队出图，最长约 5 分钟。")
            default: Text("商汤、通义、硅基流动等已确认的官方接口会自动用对应的 JSON 格式，其他中转按接口文档选。")
            }
        }
        .groupedRow()

        Section {
            LabeledContent("默认生成质量") { TrailingField(placeholder: "high", text: $draft.quality) }
            LabeledContent("可选生成质量") { TrailingField(placeholder: "auto, low, medium, high", text: $draft.qualityOptions) }
            jsonEditor($draft.generateExtra, placeholder: #"{"watermark":false}"#, title: "附加字段（JSON）")
        } header: {
            Text("文生图")
        } footer: {
            Text("质量留空就不发送，上游要支持所填的值；可选质量用逗号分隔。附加字段会合并到请求体末尾，可以覆盖 size 和 quality。")
        }
        .groupedRow()
    }

    private func jsonEditor(_ text: Binding<String>, placeholder: String, title: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title) }
            TextField(placeholder, text: text, axis: .vertical)
                .font(.footnote.monospaced())
                .lineLimit(2...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - ComfyUI

/// 本地 ComfyUI: its address and timeout, and the imported API workflows, one in use.
struct ImageGenComfyPage: View {
    @Environment(AppModel.self) private var app
    @State private var loaded = false
    @State private var baseURL = ""
    @State private var workflows: [ImageGenWorkflow] = []
    @State private var active = ""
    @State private var timeout = "300"
    @State private var importing = false
    @State private var note: ImageGenDraft.Note?
    @State private var saving = false
    @State private var testing = false

    private var mirror: SettingsMirror { app.settings }
    private var value: JSON { mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null }

    var body: some View {
        List {
            Section {
                LabeledContent("接口地址") { TrailingField(placeholder: "http://", text: $baseURL, keyboard: .URL) }
                LabeledContent("生成超时（秒）") { TrailingField(placeholder: "300", text: $timeout, keyboard: .numberPad) }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ImageGenProvider.comfyui.endpointHint(googleNative: false))
                    if let fallback = ImageGenDraft.defaultValue("comfyuiBaseURL", in: mirror), baseURL != fallback {
                        Button("恢复默认接口地址") { baseURL = fallback }.font(.footnote)
                    }
                }
            }
            .groupedRow()

            Section {
                ForEach($workflows) { $workflow in
                    NavigationLink {
                        ImageGenWorkflowPage(workflow: $workflow, active: $active)
                    } label: {
                        LabeledContent(workflow.name) { if workflow.name == active { ConfiguredMark() } }
                    }
                }
                .onDelete { offsets in
                    let removed = offsets.map { workflows[$0].name }
                    workflows.remove(atOffsets: offsets)
                    if removed.contains(active) { active = workflows.first?.name ?? "" }
                }
                Button { importing = true } label: { Label("导入工作流（JSON）", systemImage: "plus") }
            } header: {
                Text("工作流")
            } footer: {
                Text("从 ComfyUI 导出 API Format JSON，在提示词输入里写 {{prompt}}。打勾的是当前使用的，点进去可以改名、设预设提示词。")
            }
            .groupedRow()

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack(spacing: 8) {
                        if testing { ProgressView().tint(Palette.onInk) }
                        Text("测试连接")
                    }
                }
                .buttonStyle(.capsule(height: 50))
                .disabled(testing || saving)
            } footer: {
                if let note {
                    Text(note.text).foregroundStyle(note.error ? .red : .secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .groupedList()
        .scrollDismissesKeyboard(.interactively)
        .disabled(!mirror.writable && !testing)
        .navigationTitle(ImageGenProvider.comfyui.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("保存") { Task { await save() } }.disabled(testing || workflows.isEmpty || !mirror.writable)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importWorkflow(url)
        }
        .followSettings()
        .task {
            guard !loaded else { return }
            loaded = true
            baseURL = value["comfyuiBaseURL"].string?.nonEmpty ?? ImageGenDraft.defaultValue("comfyuiBaseURL", in: mirror) ?? ""
            workflows = ImageGenWorkflow.all(value)
            active = value["comfyuiActiveWorkflow"].string?.nonEmpty ?? workflows.first?.name ?? ""
            timeout = String(max(1, (value["comfyuiTimeoutMs"].int ?? 300_000) / 1000))
        }
    }

    private func importWorkflow(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let json = String(data: data, encoding: .utf8) else {
            note = .init(text: String(localized: "读不了这个文件。"), error: true)
            return
        }
        if let problem = ImageGenWorkflow.problem(json) { note = .init(text: problem, error: true); return }
        // `uniqueComfyUIWorkflowName`: the file's name, numbered when taken.
        let base = url.deletingPathExtension().lastPathComponent.nonEmpty ?? "workflow"
        var name = base
        var number = 2
        while workflows.contains(where: { $0.name == name }) { name = "\(base) (\(number))"; number += 1 }
        workflows.append(ImageGenWorkflow(name: name, json: json))
        if active.isEmpty { active = name }
        note = .init(text: String(localized: "已导入 \(name)，记得保存。"), error: false)
    }

    private func save() async {
        let entries = workflows.map { ImageGenWorkflow(id: $0.id, name: $0.name.trimmed, json: $0.json, presetPrompt: $0.presetPrompt.trimmed) }
        if entries.contains(where: { $0.name.isEmpty }) { note = .init(text: String(localized: "工作流名称不能为空。"), error: true); return }
        if Set(entries.map(\.name)).count != entries.count { note = .init(text: String(localized: "工作流名称不能重复。"), error: true); return }
        if let problem = entries.lazy.compactMap({ ImageGenWorkflow.problem($0.json) }).first { note = .init(text: problem, error: true); return }
        guard let seconds = Int(timeout.trimmed), (1...3600).contains(seconds) else { note = .init(text: String(localized: "超时要在 1 到 3600 秒之间。"), error: true); return }
        let current = entries.first { $0.name == active } ?? entries.first
        saving = true
        defer { saving = false }
        do {
            try await mirror.mutate(ImageGenModel.namespace, [
                .set(["comfyuiBaseURL"], .string(baseURL)),
                .set(["comfyuiWorkflows"], .array(entries.map { ["name": .string($0.name), "json": .string($0.json), "presetPrompt": .string($0.presetPrompt)] })),
                .set(["comfyuiActiveWorkflow"], .string(current?.name ?? "")),
                .set(["comfyuiWorkflowJson"], .string(current?.json ?? "")),
                .set(["comfyuiWorkflowName"], .string(current?.name ?? "")),
                .set(["comfyuiTimeoutMs"], .number(Double(seconds * 1000))),
            ], expectedRevision: mirror.namespace(ImageGenModel.namespace)?["revision"].int)
            workflows = entries
            note = .init(text: String(localized: "已保存"), error: false)
            Haptics.success()
        } catch {
            note = .init(text: describeFailure(error), error: true)
        }
    }

    private func test() async {
        testing = true
        note = nil
        switch await app.imageGen.test(.comfyui) {
        case .ok: note = .init(text: String(localized: "连接成功"), error: false)
        case .failed(let reason): note = .init(text: reason, error: true)
        case .models: break
        }
        testing = false
    }
}

/// One ComfyUI workflow: its name, whether it is the one in use, and its preset prompt. Saved
/// with the ComfyUI page's 保存.
private struct ImageGenWorkflowPage: View {
    @Binding var workflow: ImageGenWorkflow
    @Binding var active: String

    var body: some View {
        List {
            Section {
                LabeledContent("名称") {
                    TrailingField(placeholder: String(localized: "工作流名称"), text: Binding(get: { workflow.name }, set: { name in
                        if workflow.name == active { active = name }
                        workflow.name = name
                    }))
                }
                Toggle("当前使用", isOn: Binding(get: { workflow.name == active }, set: { if $0 { active = workflow.name } }))
                    .inkTint()
            }
            .groupedRow()

            Section {
                TextField("留空只用对话内容", text: $workflow.presetPrompt, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("预设提示词")
            } footer: {
                Text("每次调用会加在提示词前面。工作流里种子可以用 {{seed}}，宽高可以用 {{width}}、{{height}}（智能体给出尺寸或比例时生效，默认 1024×1024）；图生图在 LoadImage 的 image 输入写 {{image}}，几张参考图就写几个，按节点编号顺序对应。智能体调用时也能按名称指定工作流。")
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle(workflow.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Subscriptions

/// ChatGPT, Grok and Google subscriptions: generating with a signed-in account instead of a
/// key. Signing in opens the provider's page inside the app, where the engine, which waits
/// for the provider's redirect on the provider's fixed local port, keeps running; the
/// connectors' GitHub sign-in works the same way.
struct ImageGenSubscriptionPage: View {
    let provider: ImageGenProvider
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var testing = false
    @State private var note: ImageGenDraft.Note?
    @State private var page: SFSafariViewController?

    private var model: ImageGenModel { app.imageGen }
    private var account: ImageGenAccount { model.accounts[provider] ?? ImageGenAccount() }
    private var waiting: Bool { model.pendingSignIns[provider] != nil }

    var body: some View {
        List {
            Section {
                LabeledContent("账号") {
                    switch account.state {
                    case .signedIn: Text(account.email ?? String(localized: "已登录"))
                    case .signedOut: Text("未登录")
                    case .unknown: Text("状态未知")
                    }
                }
                LabeledContent("模型") { Text(model.subscriptionModel(provider) ?? "—") }
            } footer: {
                Text("用订阅账号生图，不需要 API Key，也支持带参考图改图（最多 5 张）。")
            }
            .groupedRow()

            Section {
                if account.state == .signedIn {
                    Button("退出登录") { Task { await signOut() } }
                        .buttonStyle(.capsule(.outline, height: 50))
                        .disabled(busy)
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack(spacing: 8) {
                            if busy || waiting { ProgressView().tint(Palette.onInk) }
                            Text(waiting ? "等待在网页里完成登录…" : "登录")
                        }
                    }
                    .buttonStyle(.capsule(height: 50))
                    .disabled(busy)
                }
                Button {
                    Task { await test() }
                } label: {
                    HStack(spacing: 8) {
                        if testing { ProgressView() }
                        Text("测试连接")
                    }
                }
                .buttonStyle(.capsule(.outline, height: 50))
                .disabled(testing || busy)
            } footer: {
                VStack(spacing: 6) {
                    if let note { Text(note.text).foregroundStyle(note.error ? .red : .secondary) }
                    Text("登录在 App 里打开的网页中完成，不会改动 API Key 或默认服务商。需要代理才能访问时，请先打开代理再登录。")
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
        }
        .groupedList()
        .navigationTitle(provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshAccounts()
            await model.refreshStudio()
        }
        .task(id: waiting) {
            guard waiting else { return }
            await model.followSignIns()
        }
        .onChange(of: account.state) { _, state in
            guard state == .signedIn, page != nil else { return }
            InAppSafari.close(page)
            page = nil
            note = .init(text: String(localized: "登录成功"), error: false)
            Haptics.success()
            Task { await model.refreshStudio() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAccounts() } }
        }
    }

    private func signIn() async {
        busy = true
        note = nil
        defer { busy = false }
        do {
            let url = try await model.signIn(provider)
            page = InAppSafari.open(url) { Task { await model.refreshAccounts() } }
        } catch {
            note = .init(text: describeFailure(error), error: true)
        }
    }

    private func signOut() async {
        busy = true
        defer { busy = false }
        do {
            try await model.signOut(provider)
            note = nil
        } catch {
            note = .init(text: describeFailure(error), error: true)
        }
    }

    private func test() async {
        testing = true
        note = nil
        switch await model.test(provider) {
        case .ok: note = .init(text: String(localized: "连接成功"), error: false)
        case .failed(let reason): note = .init(text: reason, error: true)
        case .models: break
        }
        testing = false
    }
}
