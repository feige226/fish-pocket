import Foundation
import Observation

/// Importing a DeepSeek website export (`deepseek_data-*.zip`) as sessions of a workspace, through
/// the official optional bundle `@deepseek-ai/dsh-deepseek-chat-import`. Only its Host half is used:
/// the archive goes to its upload route, which answers NDJSON progress lines and one outcome line.
/// Its browser half (the button and dialog of the web version) is not.
@MainActor
@Observable
final class DeepSeekImport {
    static let bundle = "@deepseek-ai/dsh-deepseek-chat-import"
    private static let route = "api/deepseek-chat-import/archive"

    struct Result: Equatable {
        var workspaceId: String
        var sessionIds: [String]
        var conversationCount: Int
        var omittedByLimit: Int
        /// Titles of the chosen conversations that could not be imported (nil when the file was unreadable).
        var skipped: [String?]
    }

    enum Phase: Equatable {
        case idle
        /// The bundle is off: switching it on, then waiting for its route.
        case enabling
        case uploading(Double)
        /// Uploaded; the Host reads the archive before the first session is written.
        case reading
        case importing(done: Int, total: Int)
        case finished(Result)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    var running: Bool {
        switch phase {
        case .enabling, .uploading, .reading, .importing: true
        default: false
        }
    }

    func start(file: URL, size: Int64, workspaceId: String) {
        task?.cancel()
        phase = .enabling
        task = Task { await run(file: file, size: size, workspaceId: workspaceId) }
    }

    /// Closing the sheet: the Host stops when the request goes; sessions written so far stay.
    func cancel() {
        task?.cancel()
        task = nil
        if running { phase = .idle }
    }

    func reset() { phase = .idle }

    private func run(file: URL, size: Int64, workspaceId: String) async {
        do {
            let limit = try await prepare()
            if size > limit { throw Failure(text: Self.reasonText("too-large", limit: limit)) }
            phase = .uploading(0)
            let result = try await upload(file: file, size: size, workspaceId: workspaceId)
            // Cold writes announce nothing; the list is read again however the import ended.
            await app.refreshSessions()
            Haptics.success()
            phase = .finished(result)
        } catch is CancellationError {
            await app.refreshSessions()
        } catch let error as URLError where error.code == .cancelled {
            await app.refreshSessions()
        } catch {
            await app.refreshSessions()
            guard !Task.isCancelled else { return }
            Haptics.error()
            phase = .failed((error as? Failure)?.text ?? String(localized: "导入失败：\(error.localizedDescription)"))
        }
    }

    // MARK: The bundle

    /// The largest archive the Host accepts, switching the bundle on first when it is off.
    private func prepare() async throws -> Int64 {
        if let limit = try? await limits() { return limit }
        let plugins = app.plugins
        await plugins.load()
        guard let package = plugins.package(Self.bundle) else {
            throw Failure(text: String(localized: "这个版本的引擎里没有 DeepSeek 会话导入插件"))
        }
        if !package.enabled {
            await plugins.setEnabled(package, true)
            guard plugins.package(Self.bundle)?.enabled == true else {
                throw Failure(text: String(localized: "没能开启 DeepSeek 会话导入插件"))
            }
        }
        // The switch reloads the plugin; its route is there once `limits` answers.
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let limit = try? await limits() { return limit }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(text: String(localized: "DeepSeek 会话导入插件没有启动，请到插件页查看"))
    }

    private func limits() async throws -> Int64 {
        let value = try await app.client.call("deepseekChatImport/limits")
        guard let bytes = value["maxUploadBytes"].double else { throw Failure(text: "") }
        return Int64(bytes)
    }

    // MARK: Upload

    private func upload(file: URL, size: Int64, workspaceId: String) async throws -> Result {
        let client = app.client
        var components = URLComponents(url: client.origin.appendingPathComponent(Self.route), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "workspaceId", value: workspaceId)]
        var request = client.request(components.url!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        request.setValue(String(size), forHTTPHeaderField: "content-length")
        request.httpBodyStream = InputStream(url: file)
        // Idle time: the Host writes nothing while it reads a large archive.
        request.timeoutInterval = 600

        let progress = UploadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .uploading = self.phase else { return }
                self.phase = fraction >= 1 ? .reading : .uploading(fraction)
            }
        }
        let (bytes, response) = try await client.session.bytes(for: request, delegate: progress)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw Failure(text: String(localized: "上传失败：\(text.isEmpty ? "HTTP \(status)" : text)"))
        }
        if case .uploading = phase { phase = .reading }
        for try await line in bytes.lines {
            guard let json = try? JSON.parse(Data(line.utf8)) else { continue }
            switch json["type"].string {
            case "progress":
                phase = .importing(done: json["done"].int ?? 0, total: json["total"].int ?? 0)
            case "outcome":
                let outcome = json["outcome"]
                if outcome["ok"].bool == true {
                    let value = outcome["value"]
                    return Result(
                        workspaceId: value["workspaceId"].string ?? workspaceId,
                        sessionIds: value["sessionIds"].array.compactMap(\.string),
                        conversationCount: value["conversationCount"].int ?? 0,
                        omittedByLimit: value["omittedByLimit"].int ?? 0,
                        skipped: value["skipped"].array.map { $0["title"].string }
                    )
                }
                let error = outcome["error"]
                let reason = error["reason"].string ?? ""
                // The Host's own sentence names the limit it applied.
                throw Failure(text: reason == "too-large"
                    ? String(localized: "文件过大：\(error["message"].string ?? "")")
                    : Self.reasonText(reason, message: error["message"].string))
            default:
                continue
            }
        }
        try Task.checkCancellation()
        throw Failure(text: String(localized: "导入中断了，已写入的会话会保留在列表里"))
    }

    struct Failure: Error { let text: String }

    private static func reasonText(_ reason: String, limit: Int64 = 0, message: String? = nil) -> String {
        switch reason {
        case "missing-manifest": String(localized: "这不是 DeepSeek 导出的文件：缺少 manifest.json")
        case "missing-index": String(localized: "这不是 DeepSeek 导出的文件：缺少会话索引，或它无法读取")
        case "unsupported-version": String(localized: "不支持这个导出格式版本")
        case "unreadable-archive": String(localized: "这个文件不是能读取的 ZIP 压缩包")
        case "no-conversations": String(localized: "导出文件里没有可以导入的会话")
        case "too-large": String(localized: "文件过大，最多 \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))")
        case "workspace-not-found": String(localized: "所选工作区已经不存在，请重新选择")
        case "busy": String(localized: "已经有一个导入在进行，请稍后再试")
        default: String(localized: "导入失败：\(message ?? reason)")
        }
    }
}

/// Upload progress of one request, reported as a fraction of the declared length.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
