import SwiftUI
import UniformTypeIdentifiers

/// 导入 DeepSeek 会话: pick the `deepseek_data-*.zip` exported from the DeepSeek website and the
/// workspace that receives it; the conversations become sessions there, to be continued. Opened
/// from the chip above the composer of a new conversation.
struct DeepSeekImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var importer: DeepSeekImport?
    @State private var file: PickedFile?
    @State private var workspaceId: String
    @State private var picking = false
    @State private var copying = false
    @State private var showNewWorkspace = false

    struct PickedFile: Equatable {
        let url: URL
        let name: String
        let size: Int64
    }

    init(workspaceId: String?) {
        _workspaceId = State(initialValue: workspaceId ?? "")
    }

    private var phase: DeepSeekImport.Phase { importer?.phase ?? .idle }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .idle: form
                case .finished(let result): finished(result)
                case .failed(let text): failed(text)
                default: progress
                }
            }
            .navigationTitle("导入 DeepSeek 会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { close() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text(importer?.running == true ? "停止导入" : "关闭"))
                }
            }
        }
        .inkTint()
        .interactiveDismissDisabled(importer?.running == true)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { picked($0) }
        .sheet(isPresented: $showNewWorkspace) { NewWorkspaceView { workspaceId = $0 } }
        .onAppear {
            if importer == nil { importer = DeepSeekImport(app: app) }
            if !app.workspaces.contains(where: { $0.id == workspaceId }) { workspaceId = app.workspaces.first?.id ?? "" }
        }
        .onDisappear {
            importer?.cancel()
            if let file { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        }
    }

    // MARK: Choosing

    private var form: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("把 DeepSeek 官网的聊天记录带进来，变成这里的会话，可以接着聊。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink)
                    Text("先在 DeepSeek 官网的设置里导出全部对话，得到一个 deepseek_data 开头的 ZIP 文件，存到「文件」里。")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.vertical, 6)
            }

            Section {
                Button { picking = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: file == nil ? "doc.badge.plus" : "doc.zipper")
                            .font(.title3)
                            .foregroundStyle(Palette.ink)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file?.name ?? String(localized: "选择导出文件"))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let file {
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.footnote)
                                    .foregroundStyle(Palette.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if copying {
                            ProgressView()
                        } else if file != nil {
                            Text("重新选择").font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(copying)
            } header: {
                Text("导出文件")
            }

            Section {
                Picker("工作区", selection: $workspaceId) {
                    ForEach(app.workspaces) { workspace in
                        Text(workspace.displayTitle).tag(workspace.id)
                    }
                }
                Button { showNewWorkspace = true } label: { Label("添加工作区", systemImage: "folder.badge.plus") }
            } header: {
                Text("导入到")
            } footer: {
                Text("每个对话成为这个工作区里的一个会话。")
            }

            Section {
                ForEach(Self.notes, id: \.text) { note in
                    Label {
                        Text(note.text).font(.footnote).foregroundStyle(Palette.ink)
                    } icon: {
                        Image(systemName: note.icon).font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
            } header: {
                Text("导入说明")
            }

            Section {
                Button {
                    guard let file else { return }
                    Haptics.tap()
                    importer?.start(file: file.url, size: file.size, workspaceId: workspaceId)
                } label: {
                    Text("导入")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(file == nil || copying || workspaceId.isEmpty)
            }
        }
    }

    /// What the official plugin keeps, drops and limits (its README), in the reader's terms.
    private static var notes: [(icon: String, text: String)] {
        [
            ("checkmark.circle", String(localized: "保留你当时停留的那条对话分支，以及原标题、时间、思考过程、联网搜索和图片。")),
            ("exclamationmark.bubble", String(localized: "被撤回、失败或模板回答的回复显示为错误行，不会发给模型；提问全部被撤回的对话会跳过。")),
            ("doc", String(localized: "图片以外的附件只保留文件名和大小，打不开，模型也读不到内容。")),
            ("square.stack.3d.up", String(localized: "一次最多导入最近的 1000 个对话，压缩包最大 512 MB。同一个文件导入两次会得到两份。")),
            ("gauge.with.dots.needle.33percent", String(localized: "接着聊时，整段历史都会发给模型，按正常用量消耗额度或 API 费用；很长的对话第一次回复会比较慢。")),
        ]
    }

    private func picked(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        copying = true
        Task {
            let copy = await Task.detached(priority: .userInitiated) { Self.copy(url) }.value
            copying = false
            guard let copy else {
                app.showToast(String(localized: "读不到这个文件"), tone: .warning)
                return
            }
            if let old = file { try? FileManager.default.removeItem(at: old.url.deletingLastPathComponent()) }
            file = copy
        }
    }

    /// A copy of our own: the picked file may still be in iCloud, and its access ends with the scope.
    nonisolated private static func copy(_ url: URL) -> PickedFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-import-\(UUID().uuidString)", isDirectory: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var failure: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &failure) { source in
                do { try FileManager.default.copyItem(at: source, to: copy) } catch { copyError = error }
            }
            if let error = failure ?? copyError { throw error }
            let size = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? 0
            return PickedFile(url: copy, name: url.lastPathComponent, size: size)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    // MARK: Importing

    /// One bar and one line that change in place: the bar fills once a fraction is known, the
    /// line rolls its digits instead of fading one sentence over another.
    private var progress: some View {
        let (fraction, line): (Double?, String) = switch phase {
        case .uploading(let fraction): (fraction, String(localized: "正在上传 \(Int(fraction * 100))%"))
        case .importing(let done, let total) where total > 0: (Double(done) / Double(total), String(localized: "正在导入 \(done)/\(total)"))
        case .enabling: (nil, String(localized: "正在开启导入功能…"))
        default: (nil, String(localized: "正在读取导出文件…"))
        }
        return VStack(spacing: 18) {
            Spacer()
            ZStack {
                if let fraction {
                    ProgressView(value: fraction)
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 260, minHeight: 24)
            Text(line)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: line)
            Spacer()
            Text("关掉这一页会停止导入，已经导入的会话会保留")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .font(.subheadline)
        .foregroundStyle(Palette.ink)
        .monospacedDigit()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private func finished(_ result: DeepSeekImport.Result) -> some View {
        let workspace = app.workspaces.first { $0.id == result.workspaceId }?.displayTitle ?? ""
        return VStack(spacing: 14) {
            Spacer()
            Image(systemName: result.sessionIds.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(result.sessionIds.isEmpty ? Palette.waiting : .green)
            Text(result.sessionIds.isEmpty ? String(localized: "没有导入任何会话") : String(localized: "已导入 \(result.sessionIds.count) 个会话"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)
            VStack(spacing: 4) {
                if !result.sessionIds.isEmpty { Text("在工作区「\(workspace)」里") }
                if result.omittedByLimit > 0 { Text("\(result.omittedByLimit) 个较早的对话超出上限，没有导入") }
                if !result.skipped.isEmpty { Text("\(result.skipped.count) 个对话无法导入") }
            }
            .font(.subheadline)
            .foregroundStyle(Palette.secondary)
            .multilineTextAlignment(.center)
            let titles = result.skipped.compactMap { $0 }.filter { !$0.isEmpty }
            if !titles.isEmpty {
                Text(titles.prefix(5).joined(separator: "、") + (titles.count > 5 ? "…" : ""))
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Spacer()
            VStack(spacing: 10) {
                if let first = result.sessionIds.first {
                    Button {
                        dismiss()
                        app.open(session: first)
                    } label: {
                        Text("打开最近的会话").font(.body.weight(.semibold)).foregroundStyle(Palette.onInk)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Palette.ink, in: Capsule())
                    }
                }
                Button { dismiss() } label: {
                    Text("完成").frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private func failed(_ text: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.waiting)
            Text("导入没有完成")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button { importer?.reset() } label: {
                Text("返回").font(.body.weight(.semibold)).foregroundStyle(Palette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.ink, in: Capsule())
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private func close() {
        importer?.cancel()
        dismiss()
    }
}
