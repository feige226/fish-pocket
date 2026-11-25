import Foundation
import Observation

/// Image generation comes from dsh-image-gen, a plugin built into the engine (pins.json). Its
/// settings are the `image-gen` namespace, read and written through the shared settings mirror;
/// its API keys are credentials; what settings cannot do (testing a connection, listing a
/// provider's models, signing in to a subscription) goes through its HTTP routes, the ones its
/// own settings card in the web version calls. The native pages follow that card field by field.
enum ImageGenProvider: String, CaseIterable, Identifiable {
    case google
    case openai
    case openaiCompat = "openai-compat"
    case seedream
    case dashscope
    case xai
    case zhipu
    case comfyui
    case chatgptSub = "chatgpt-sub"
    case grokSub = "grok-sub"
    case googleSub = "google-sub"

    var id: String { rawValue }

    enum Kind { case cloud, comfyui, subscription }

    var kind: Kind {
        switch self {
        case .comfyui: .comfyui
        case .chatgptSub, .grokSub, .googleSub: .subscription
        default: .cloud
        }
    }

    /// Its name where it stands alone: the default provider, a page's title, a picture's caption.
    var title: String {
        switch self {
        case .google: "Google Gemini"
        case .openai: "OpenAI"
        case .openaiCompat: String(localized: "OpenAI 兼容（中转站）")
        case .seedream: String(localized: "即梦 Seedream")
        case .dashscope: String(localized: "通义 DashScope")
        case .xai: "Grok Imagine"
        case .zhipu: String(localized: "智谱 GLM")
        case .comfyui: String(localized: "本地 ComfyUI")
        case .chatgptSub: String(localized: "ChatGPT 订阅")
        case .grokSub: String(localized: "Grok 订阅")
        case .googleSub: String(localized: "Google 订阅")
        }
    }

    /// Its name in the settings list, whose section already says what kind it is.
    var listTitle: String {
        switch self {
        case .comfyui: "ComfyUI"
        case .chatgptSub: "ChatGPT"
        case .grokSub: "Grok"
        case .googleSub: "Google"
        default: title
        }
    }

    static let subscriptions: [ImageGenProvider] = [.chatgptSub, .grokSub, .googleSub]
    static let keyed: [ImageGenProvider] = [.google, .openai, .openaiCompat, .seedream, .dashscope, .xai, .zhipu]

    /// The credential its API key is kept under (the plugin's `CLOUD_CREDENTIAL_REFS`).
    var credentialRef: String? {
        switch self {
        case .google: "GEMINI_API_KEY"
        case .openai: "OPENAI_API_KEY"
        case .openaiCompat: ImageGenChannel.defaultKeyRef
        case .seedream: "ARK_API_KEY"
        case .dashscope: "DASHSCOPE_API_KEY"
        case .xai: "XAI_API_KEY"
        case .zhipu: "ZHIPUAI_API_KEY"
        default: nil
        }
    }

    /// Where the provider issues keys (the plugin's `API_KEY_CONSOLE_URLS`).
    var consoleURL: URL? {
        switch self {
        case .google: URL(string: "https://aistudio.google.com/apikey")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .seedream: URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey")
        case .dashscope: URL(string: "https://bailian.console.aliyun.com/")
        case .xai: URL(string: "https://console.x.ai/team/default/api-keys")
        case .zhipu: URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys")
        default: nil
        }
    }

    /// The settings fields its model and its address are stored in.
    var modelField: String? {
        switch self {
        case .google: "googleModel"
        case .openai: "openaiModel"
        case .openaiCompat: "openaiCompatModel"
        case .seedream: "seedreamModel"
        case .dashscope: "dashscopeModel"
        case .xai: "xaiModel"
        case .zhipu: "zhipuModel"
        default: nil
        }
    }

    var urlField: String? {
        switch self {
        case .google: "googleEndpoint"
        case .openai: "openaiBaseURL"
        case .openaiCompat: "openaiCompatBaseURL"
        case .seedream: "seedreamBaseURL"
        case .dashscope: "dashscopeEndpoint"
        case .xai: "xaiBaseURL"
        case .zhipu: "zhipuBaseURL"
        case .comfyui: "comfyuiBaseURL"
        default: nil
        }
    }

    /// What goes in the address field.
    func endpointHint(googleNative: Bool) -> String {
        switch self {
        case .google: googleNative
            ? String(localized: "填写 API 基础地址（如 https://example.com/v1beta），也兼容 Interactions 或 generateContent 的完整地址。")
            : String(localized: "Google 官方地址或反代端点（完整路径）。")
        case .openai: String(localized: "官方 api.openai.com 的 /v1 地址；中转站请用「OpenAI 兼容（中转站）」。")
        case .openaiCompat: String(localized: "中转站或自建服务的 OpenAI 兼容 /v1 地址（必填），例如 https://your-relay.example.com/v1。")
        case .seedream: String(localized: "火山方舟兼容的 /api/v3 地址。")
        case .dashscope: String(localized: "阿里云百炼 DashScope 官方接口地址。")
        case .xai: String(localized: "xAI 官方 api.x.ai 的 /v1 地址。")
        case .zhipu: String(localized: "智谱开放平台 open.bigmodel.cn 的 /api/paas/v4 地址。")
        case .comfyui: String(localized: "正在运行、并且这台设备能访问到的 ComfyUI 地址。")
        default: ""
        }
    }
}

/// One OpenAI-compatible channel. The first (`default`) is kept in the namespace's flat
/// `openaiCompat…` fields, the others in `openaiCompatChannels` (the plugin's
/// `resolveOpenAICompatChannels`).
struct ImageGenChannel: Identifiable, Equatable {
    static let defaultID = "default"
    static let defaultKeyRef = "DSH_IMAGE_GEN_OPENAI_COMPAT_KEY"
    static let defaultQualities = ["auto", "low", "medium", "high"]

    var id: String
    var label: String
    var keyRef: String
    var baseURL = ""
    var model = ""
    var models: [String] = []
    var editModel = ""
    var quality = ""
    var qualityOptions: [String] = []
    var extraBody: JSON = .object([:])
    var editSizeMode = "auto"
    var editFormat = "multipart"
    var editExtra: JSON = .object([:])
    var sizes: JSON = .object([:])

    var isDefault: Bool { id == Self.defaultID }

    /// The name a channel goes by where an image says what made it: the Fish Pocket one by its
    /// own name, the user's by the label they gave it, else the provider's.
    @MainActor
    static func title(of id: String, in value: JSON) -> String {
        if id == FishPocketImageGen.channelID { return FishPocketImageGen.title }
        return all(value).first { $0.id == id }?.label ?? ImageGenProvider.openaiCompat.title
    }

    /// `DSH_IMAGE_GEN_OPENAI_COMPAT_KEY_<ID>` for an added channel.
    static func keyRef(for id: String) -> String {
        id == defaultID ? defaultKeyRef : "\(defaultKeyRef)_\(id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression).uppercased())"
    }

    /// Every channel of the namespace value, the default one first.
    static func all(_ value: JSON) -> [ImageGenChannel] {
        var first = ImageGenChannel(id: defaultID, label: value["openaiCompatLabel"].string?.trimmed.nonEmpty ?? String(localized: "OpenAI 兼容"), keyRef: defaultKeyRef)
        first.baseURL = value["openaiCompatBaseURL"].string ?? ""
        first.model = value["openaiCompatModel"].string ?? ""
        first.models = value["openaiCompatModels"].array.compactMap(\.string)
        first.editModel = value["openaiCompatEditModel"].string ?? ""
        first.quality = value["openaiCompatQuality"].string ?? ""
        first.qualityOptions = value["openaiCompatQualityOptions"].array.compactMap(\.string)
        first.extraBody = value["openaiCompatExtraBody"].nonNull ?? .object([:])
        first.editSizeMode = value["openaiCompatEditSizeMode"].string ?? "auto"
        first.editFormat = value["openaiCompatEditFormat"].string ?? "multipart"
        first.editExtra = value["openaiCompatEditExtra"].nonNull ?? .object([:])
        first.sizes = value["openaiCompatSizes"].nonNull ?? .object([:])
        var channels = [first]
        var seen: Set<String> = [defaultID]
        for (index, entry) in value["openaiCompatChannels"].array.enumerated() {
            let id = entry["id"].string?.trimmed ?? ""
            guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil, !seen.contains(id) else { continue }
            seen.insert(id)
            let stored = entry["keyRef"].string?.trimmed ?? ""
            var channel = ImageGenChannel(
                id: id,
                label: entry["label"].string?.trimmed.nonEmpty ?? String(localized: "OpenAI 兼容 \(index + 2)"),
                keyRef: stored.range(of: "^DSH_IMAGE_GEN_OPENAI_COMPAT_KEY_[A-Z0-9_]+$", options: .regularExpression) != nil ? stored : keyRef(for: id)
            )
            channel.baseURL = entry["baseURL"].string ?? ""
            channel.model = entry["model"].string ?? ""
            channel.models = entry["models"].array.compactMap(\.string)
            channel.editModel = entry["editModel"].string ?? ""
            channel.quality = entry["quality"].string ?? ""
            channel.qualityOptions = entry["qualityOptions"].array.compactMap(\.string)
            channel.extraBody = entry["extraBody"].nonNull ?? .object([:])
            channel.editSizeMode = entry["editSizeMode"].string == "selected" ? "selected" : "auto"
            channel.editFormat = entry["editFormat"].string ?? "multipart"
            channel.editExtra = entry["editExtra"].nonNull ?? .object([:])
            channel.sizes = entry["sizes"].nonNull ?? .object([:])
            channels.append(channel)
        }
        return channels
    }

    /// An added channel as `openaiCompatChannels` stores it.
    var stored: JSON {
        [
            "id": .string(id), "label": .string(label), "keyRef": .string(keyRef),
            "baseURL": .string(baseURL), "model": .string(model), "models": .array(models.map { .string($0) }),
            "editModel": .string(editModel), "quality": .string(quality),
            "qualityOptions": .array(qualityOptions.map { .string($0) }), "extraBody": extraBody,
            "editSizeMode": .string(editSizeMode), "editFormat": .string(editFormat),
            "editExtra": editExtra, "sizes": sizes,
        ]
    }

    /// The default model first, then the rest without repeats (`resolveOpenAICompatModels`).
    static func modelList(_ model: String, _ models: [String]) -> [String] {
        var list: [String] = []
        for entry in models.map(\.trimmed) where !entry.isEmpty && !list.contains(entry) { list.append(entry) }
        let first = model.trimmed
        if !first.isEmpty, !list.contains(first) { list.insert(first, at: 0) }
        return list
    }

    /// The edit request the plugin picks by itself for an official API, whatever the setting
    /// says (`compatEditFormat` with `officialContract`, as its settings card calls them: the
    /// edit model, else the default one).
    static func officialEditFormat(baseURL: String, model: String) -> String? {
        guard let url = URLComponents(string: baseURL.trimmed), url.scheme == "https", url.port == nil, url.query == nil, url.fragment == nil,
              let host = url.host else { return nil }
        let path = url.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if path == "/v1", host == "api.siliconflow.cn" || host == "api.siliconflow.com" { return "siliconflowJson" }
        if path == "/v1", host == "api-inference.modelscope.cn" { return "modelscopeAsync" }
        if host == "token.sensenova.cn", path == "/v1", model == "sensenova-u1.5-lite" { return "jsonImageUrlArray" }
        let qwenHost = host.range(of: "^[a-z0-9-]+\\.(?:cn-beijing|ap-southeast-1|us-east-1|eu-central-1|ap-northeast-1|cn-hongkong)\\.maas\\.aliyuncs\\.com$", options: .regularExpression) != nil
        if qwenHost, path == "/compatible-mode/v1", model.range(of: "^qwen-image-(?:3\\.0(?:-pro)?|2\\.1-(?:pro|turbo))$", options: .regularExpression) != nil { return "qwenJson" }
        return nil
    }
}

/// One ComfyUI workflow: an API Format JSON with `{{prompt}}` in it.
struct ImageGenWorkflow: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var json: String
    var presetPrompt = ""

    static func all(_ value: JSON) -> [ImageGenWorkflow] {
        let list = value["comfyuiWorkflows"].array.compactMap { entry -> ImageGenWorkflow? in
            guard let name = entry["name"].string, let json = entry["json"].string else { return nil }
            return ImageGenWorkflow(name: name, json: json, presetPrompt: entry["presetPrompt"].string ?? "")
        }
        // A single workflow saved before the list existed.
        if list.isEmpty, let json = value["comfyuiWorkflowJson"].string, !json.trimmed.isEmpty {
            return [ImageGenWorkflow(name: value["comfyuiWorkflowName"].string?.trimmed.nonEmpty ?? "workflow", json: json)]
        }
        return list
    }

    static let maxBytes = 5 * 1024 * 1024

    /// The plugin's check before saving (`validateComfyUIWorkflowJson`): at most 5 MB, a
    /// non-empty JSON object, and `{{prompt}}` (or the older `%prompt%`) in some node's inputs.
    static func problem(_ json: String) -> String? {
        if json.utf8.count > maxBytes { return String(localized: "工作流文件不能超过 5 MB。") }
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            return String(localized: "工作流不是有效的 ComfyUI API Format JSON。")
        }
        func mentionsPrompt(_ value: Any) -> Bool {
            if let text = value as? String { return text.contains("{{prompt}}") || text.contains("%prompt%") }
            if let list = value as? [Any] { return list.contains(where: mentionsPrompt) }
            if let map = value as? [String: Any] { return map.values.contains(where: mentionsPrompt) }
            return false
        }
        let prompted = object.values.contains { node in ((node as? [String: Any])?["inputs"]).map(mentionsPrompt) ?? false }
        return prompted ? nil : String(localized: "工作流的文本输入里没有 {{prompt}}，请在提示词输入里写上它再导出。")
    }
}

/// A subscription account's state as the plugin's status route reports it.
struct ImageGenAccount: Equatable {
    enum State { case signedIn, signedOut, unknown }
    var state: State = .unknown
    var email: String?
}

/// The result of 测试连接 or 拉取模型.
enum ImageGenProbe: Equatable {
    case ok
    case models([String])
    case failed(String)
}

/// The plugin's routes, and the subscription sign-ins in flight.
@MainActor
@Observable
final class ImageGenModel {
    static let namespace = "image-gen"
    static let routes = "plugins/dsh-image-gen"

    @ObservationIgnored private let client: EngineClient
    private(set) var accounts: [ImageGenProvider: ImageGenAccount] = [:]
    /// Sign-ins whose browser page is open: polled until they land, for the plugin's 10-minute window.
    private(set) var pendingSignIns: [ImageGenProvider: Date] = [:]
    /// `GET studio`: every provider's current profile (model, models, signed in), read on demand.
    private(set) var studio: JSON?

    init(client: EngineClient) {
        self.client = client
    }

    // MARK: Routes

    private func route(_ path: String, method: String = "POST", body: JSON? = nil) async throws -> (JSON, Int) {
        var request = client.request(client.origin.appendingPathComponent("\(Self.routes)/\(path)"))
        request.httpMethod = method
        request.timeoutInterval = 120
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await client.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ((try? JSON.parse(data)) ?? .null, status)
    }

    /// 测试连接 (`POST test`), for a provider or one OpenAI-compatible channel.
    func test(_ provider: ImageGenProvider, channel: String? = nil) async -> ImageGenProbe {
        var body: JSON = ["provider": .string(provider.rawValue)]
        if let channel { body = body.setting(["channel"], .string(channel)) }
        do {
            let (value, status) = try await route("test", body: body)
            guard (200..<300).contains(status) else { return .failed("HTTP \(status)") }
            return value["ok"].bool == true ? .ok : .failed(Self.reason(value))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 拉取模型: the provider's image models, read with the saved key and address.
    func models(_ provider: ImageGenProvider, channel: String? = nil) async -> ImageGenProbe {
        var body: JSON = ["provider": .string(provider.rawValue), "action": "models"]
        if let channel { body = body.setting(["channel"], .string(channel)) }
        do {
            let (value, status) = try await route("test", body: body)
            guard (200..<300).contains(status) else { return .failed("HTTP \(status)") }
            guard value["ok"].bool == true else { return .failed(Self.reason(value)) }
            return .models(value["models"].array.compactMap(\.string))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func reason(_ value: JSON) -> String {
        switch value["reason"].string {
        case "missing-key": return String(localized: "还没有填写 API Key")
        case "unauthorized": return String(localized: "Key 无效或没有权限")
        default:
            let message = value["message"].string ?? ""
            if message == "Base URL is not configured" { return String(localized: "没有读到已保存的接口地址，请保存后再试。") }
            return message.isEmpty ? String(localized: "连接失败") : String(localized: "连接失败：\(message)")
        }
    }

    /// Every subscription account's state.
    func refreshAccounts() async {
        guard let answer = try? await route("subscription-status"), (200..<300).contains(answer.1) else { return }
        let value = answer.0
        var next: [ImageGenProvider: ImageGenAccount] = [:]
        for provider in ImageGenProvider.allCases where provider.kind == .subscription {
            let row = value["statuses"][provider.rawValue]
            switch row["state"].string {
            case "logged-in": next[provider] = ImageGenAccount(state: .signedIn, email: row["email"].string)
            case "logged-out": next[provider] = ImageGenAccount(state: .signedOut)
            default: next[provider] = ImageGenAccount()
            }
        }
        accounts = next
        for (provider, started) in pendingSignIns where next[provider]?.state == .signedIn || Date().timeIntervalSince(started) > 630 {
            pendingSignIns[provider] = nil
        }
    }

    /// Start a sign-in: the plugin opens a local callback on the vendor's fixed port and
    /// answers the authorization page to open; the caller opens it in the app, so the engine
    /// keeps running to catch the redirect.
    func signIn(_ provider: ImageGenProvider) async throws -> URL {
        let (value, status) = try await route("subscription-login", body: ["provider": .string(provider.rawValue)])
        guard (200..<300).contains(status), value["ok"].bool == true, let url = value["url"].string.flatMap(URL.init(string:)) else {
            let error = value["error"].string ?? value["error"]["message"].string ?? "HTTP \(status)"
            throw EngineError(code: nil, message: error, detail: value)
        }
        pendingSignIns[provider] = Date()
        return url
    }

    func signOut(_ provider: ImageGenProvider) async throws {
        let (_, status) = try await route("subscription-login", body: ["provider": .string(provider.rawValue), "action": "logout"])
        guard (200..<300).contains(status) else { throw EngineError(code: nil, message: "HTTP \(status)", detail: .null) }
        pendingSignIns[provider] = nil
        await refreshAccounts()
    }

    /// Poll while a sign-in page is open, every two seconds, until none is.
    func followSignIns() async {
        while !pendingSignIns.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await refreshAccounts()
        }
    }

    func refreshStudio() async {
        guard let answer = try? await route("studio", method: "GET"), (200..<300).contains(answer.1) else { return }
        studio = answer.0
    }

    /// The model a subscription generates with, as the plugin reports it.
    func subscriptionModel(_ provider: ImageGenProvider) -> String? {
        studio?["providers"].array.first { $0["provider"].string == provider.rawValue }?["model"].string
    }
}

extension AppModel {
    var imageGen: ImageGenModel { sharedModel(&SharedModelKey.imageGen) { ImageGenModel(client: client) } }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
