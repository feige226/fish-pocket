import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The bytes behind a remote file: kept by the account's server, or read off the computer
/// through its connector, as the server's own web app reads them.
enum RemoteFileFetch {
    static func data(_ attachment: RemoteAttachment, client: RemoteClient, deviceId: String?, cwd: String?, online: Bool = true) async throws -> Data {
        switch attachment.source {
        case .local(let data): data
        case .server(let link): try await client.data(at: link)
        case .device(let root, let path): try await device(path: path, root: root ?? cwd, client: client, deviceId: deviceId, online: online)
        }
    }

    /// A file on the computer: the connector stages it, and the server hands it over once.
    static func device(path: String, root: String?, client: RemoteClient, deviceId: String?, online: Bool = true) async throws -> Data {
        guard let deviceId, !deviceId.isEmpty else {
            throw RemoteError(kind: .invalid, message: String(localized: "不知道这个文件在哪台电脑上"))
        }
        guard online else { throw RemoteError(kind: .offline, message: String(localized: "电脑离线，暂时打不开电脑上的文件")) }
        let root = root.flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let value = try await client.post("/connectors/\(RemoteClient.encode(deviceId))/fs/read", ["path": .string(path)], query: ["root": root])
        guard value["ok"].bool != false, let link = value["result"]["downloadUrl"].string else {
            throw RemoteError(kind: .rejected, message: value["error"]["message"].string ?? String(localized: "电脑没有返回这个文件"))
        }
        return try await client.data(at: link)
    }

    /// A copy on the phone for Quick Look, named so it picks the right viewer.
    static func temporaryCopy(_ data: Data, name: String, mediaType: String?) throws -> URL {
        var file = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        if file.isEmpty || file == "." || file == ".." { file = "file" }
        if (file as NSString).pathExtension.isEmpty, let mediaType, let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension {
            file += ".\(ext)"
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-files/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: file)
        try data.write(to: url)
        return url
    }
}

/// A file in a remote conversation: fetched on a tap and shown in Quick Look, whose toolbar
/// shares and saves it. The copy on the phone goes when the preview closes.
struct RemoteFileButton<Label: View>: View {
    let name: String
    var mediaType: String?
    let fetch: () async throws -> Data
    /// Drawn with whether the file is on its way.
    @ViewBuilder let label: (_ loading: Bool) -> Label
    @State private var loading = false
    @State private var preview: URL?
    @State private var failure: String?

    var body: some View {
        Button { open() } label: {
            label(loading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .accessibilityHint(Text("打开预览"))
        .quickLookPreview($preview)
        .onChange(of: preview) { old, new in
            if new == nil, let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        }
        .alert("打不开这个文件", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func open() {
        Haptics.tap()
        loading = true
        Task {
            defer { loading = false }
            do {
                let data = try await fetch()
                preview = try RemoteFileFetch.temporaryCopy(data, name: name, mediaType: mediaType)
            } catch {
                let error = RemoteError(error)
                if error.kind != .cancelled { failure = error.message }
            }
        }
    }
}

/// A file card with its fetch in progress said at its end.
struct RemoteFileCard: View {
    let name: String
    var bytes: Int?
    let loading: Bool

    var body: some View {
        FileCard(name: name, bytes: bytes)
            .overlay(alignment: .trailing) {
                if loading { ProgressView().controlSize(.small).padding(.trailing, 12) }
            }
    }
}
