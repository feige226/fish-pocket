import SwiftUI

/// The steps on the launch screen that get a stuck engine up again (engine/runtime/recovery.mjs).
/// What keeps an engine down for good is on disk — a plugin, or a setting DSH cannot read — and
/// it outlives a reinstall, while the pages that would change it are behind the interface that is
/// missing. So the steps work on plugins and settings as a whole, without knowing which one is at
/// fault: switch off the third-party plugins, put back the settings of the last launch that came
/// up, or move every setting aside. Each asks first, and each keeps what it replaces. Sessions,
/// Bots, apps and files are never touched.
struct EngineRepair: View {
    @ObservedObject var engine: NodeEngine

    /// The step asked for here and not yet seen through.
    @State private var pending: String?
    @State private var confirming: Step?
    @State private var editing = false
    /// The steps tried on this screen: the next one leads.
    @State private var tried: Set<Step> = []
    /// Ticks the wait for an engine that hangs again after a step.
    @State private var now = Date()

    enum Step: String, Identifiable {
        case safeMode, restore, reset
        var id: String { rawValue }
    }

    private var state: RecoveryState? { engine.recovery }
    /// What putting the last good settings back would change; nil when there is nothing to put back.
    private var checkpoint: RecoveryState.Checkpoint? {
        guard let checkpoint = state?.checkpoint, !checkpoint.changes.isEmpty else { return nil }
        return checkpoint
    }

    /// A step is under way until `main.mjs` has done it and the engine it restarted has
    /// either failed again or had as long as a launch gets before this screen comes up.
    private var busy: Bool {
        guard let pending else { return false }
        guard let done = state?.action, done.id == pending else { return true }
        if !done.ok || state?.state == .failed { return false }
        return now.timeIntervalSince(done.at) < 20
    }

    private var steps: [Step] {
        var steps: [Step] = [.safeMode]
        if checkpoint != nil { steps.append(.restore) }
        if state?.files.isEmpty == false { steps.append(.reset) }
        return steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("引擎起不来，多半是插件或设置出了问题。可以按顺序试下面几步，会话、Bot、Mini Apps 和文件都不会动。")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                // The log above takes what room is left; these lines are not what gives.
                .fixedSize(horizontal: false, vertical: true)

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在重启引擎…")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.ink)
            } else if let done = state?.action {
                Text(Self.outcome(done))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let next = steps.first { !tried.contains($0) }
            ForEach(steps) { step in
                Button(title(step)) { confirming = step }
                    .buttonStyle(.capsule(step == next ? .primary : .secondary, height: 44))
                if step == .restore, let checkpoint {
                    Text("上次能启动是在 \(checkpoint.at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 12) {
                if state?.files.isEmpty == false {
                    Button("编辑设置文件") { editing = true }
                        .buttonStyle(.capsule(.outline, height: 40))
                }
                if state?.state == .failed {
                    Button("重新启动") { run(.restart) }
                        .buttonStyle(.capsule(.outline, height: 40))
                }
            }
        }
        .disabled(busy)
        .alert(confirming.map(confirmTitle) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { step in
            Button(confirmButton(step), role: step == .reset ? .destructive : nil) { start(step) }
            Button("取消", role: .cancel) {}
        } message: { step in
            Text(confirmMessage(step))
        }
        .sheet(isPresented: $editing) {
            SettingsFilesEditor(files: state?.files ?? []) { path, text in
                editing = false
                run(.edit(path: path, text: text))
            }
        }
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func start(_ step: Step) {
        tried.insert(step)
        switch step {
        case .safeMode: run(.safeMode)
        case .restore: run(.restore)
        case .reset: run(.reset)
        }
    }

    private func run(_ action: RecoveryAction) {
        pending = engine.requestRecovery(action)
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .safeMode: String(localized: "停用第三方插件并重启")
        case .restore: String(localized: "换回上次能启动时的设置")
        case .reset: String(localized: "重置全部设置")
        }
    }

    private func confirmTitle(_ step: Step) -> String {
        switch step {
        case .safeMode: String(localized: "停用所有第三方插件？")
        case .restore: String(localized: "换回上次能启动时的设置？")
        case .reset: String(localized: "重置全部设置？")
        }
    }

    private func confirmButton(_ step: Step) -> String {
        switch step {
        case .safeMode: String(localized: "停用并重启")
        case .restore: String(localized: "换回并重启")
        case .reset: String(localized: "重置并重启")
        }
    }

    private func confirmMessage(_ step: Step) -> String {
        switch step {
        case .safeMode:
            return String(localized: "插件不会被卸载。进去后可以在插件页逐个重新打开，找出是哪个卡住了引擎。")
        case .restore:
            let when = checkpoint?.at.formatted(date: .abbreviated, time: .shortened) ?? ""
            let files = (checkpoint?.changes ?? []).map(\.path).joined(separator: "\n")
            return String(localized: "设置会换回 \(when) 引擎能启动时的样子，改动这些文件：\n\(files)\n\n现在的文件会先移进备份，不会删除。这之后改过的设置，比如新填的 Key，要重新配置。")
        case .reset:
            return String(localized: "模型、Key、插件开关、权限等设置都会恢复为默认，要重新配置。现在的设置文件会先移进备份，不会删除。")
        }
    }

    /// What a step did, while the engine is still down.
    static func outcome(_ done: RecoveryState.Action) -> String {
        guard done.ok else { return String(localized: "这一步没能完成，原因在上面的日志里。") }
        switch done.action {
        case "safe-mode":
            let count = done.disabled?.count ?? 0
            return count == 0
                ? String(localized: "没有可停用的第三方插件，引擎还是没起来。")
                : String(localized: "已停用 \(count) 个第三方插件，引擎还是没起来。")
        case "restore": return String(localized: "已换回上次能启动时的设置，引擎还是没起来。")
        case "reset": return String(localized: "设置已全部重置，引擎还是没起来。请复制报告发给我们。")
        case "edit": return String(localized: "已保存 \(done.files?.first ?? "")，引擎还是没起来。")
        default: return String(localized: "已重新启动，引擎还是没起来。")
        }
    }

    /// What a step did, told once the engine is up (MainView).
    static func report(_ done: RecoveryState.Action) -> String {
        let backup = done.backup ?? ""
        switch done.action {
        case "safe-mode":
            // Nothing switched off did nothing to get it up: not worth a line.
            let names = done.disabled ?? []
            return names.isEmpty
                ? ""
                : String(localized: "停用了 \(names.count) 个第三方插件：\(names.joined(separator: "、"))。它们仍然装着，可以在插件页逐个重新打开，找出是哪个卡住了引擎。")
        case "restore":
            let when = done.checkpoint?.formatted(date: .abbreviated, time: .shortened) ?? ""
            return String(localized: "设置换回了 \(when) 能启动时的样子。换下来的文件在 \(backup)，之后填过的 Key 等设置要重新配置，也可以从那里找回。")
        case "reset":
            return String(localized: "设置已重置为默认，原来的设置文件在 \(backup)。模型、Key、插件开关等要重新配置。")
        case "edit":
            return String(localized: "已保存 \(done.files?.first ?? "")，修改前的版本在 \(backup)。")
        default:
            return ""
        }
    }
}

/// The settings files, to put right by hand what the steps above cannot. Saving backs the old
/// one up first.
private struct SettingsFilesEditor: View {
    let files: [String]
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(files, id: \.self) { file in
                        NavigationLink(file) { SettingsFileEditor(file: file, save: save) }
                            .font(.subheadline.monospaced())
                    }
                } footer: {
                    Text("引擎的设置文件，在 ~/.dsh 下。保存前会先备份，改错了也找得回来。")
                }
            }
            .navigationTitle("设置文件")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
    }
}

private struct SettingsFileEditor: View {
    let file: String
    let save: (String, String) -> Void

    @State private var original: String?
    @State private var text = ""
    @State private var confirming = false
    @State private var unreadable = false

    var body: some View {
        Group {
            if unreadable {
                ContentUnavailableView("不能在这里编辑", systemImage: "doc.questionmark", description: Text("这个文件不是文本。"))
            } else {
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
            }
        }
        .navigationTitle(file)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { confirming = true }
                    .disabled(original == nil || text == original)
            }
        }
        .alert("保存并重启引擎？", isPresented: $confirming) {
            Button("保存并重启") { save(file, text) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("修改前的 \(file) 会先备份，不会丢。")
        }
        .onAppear {
            guard original == nil, !unreadable else { return }
            let url = EnginePaths.dshHome.appendingPathComponent(file)
            if let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) {
                original = string
                text = string
            } else {
                unreadable = true
            }
        }
    }
}
