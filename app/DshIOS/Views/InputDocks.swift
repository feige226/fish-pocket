import SwiftUI

/// One line above the composer for what the session has going: 「任务 2/5 · 编译中」,
/// a message on its way, a full context and a deferred approval. Everything behind it
/// opens in a sheet. With the keyboard up the timeline has little room left: only a
/// waiting approval keeps its place. Queued messages show in the conversation (`QueuedMessages`).
struct ComposerStatusBar: View {
    let model: SessionModel
    var keyboardUp = false
    /// 「等你允许」 / 「等你回答」: an interaction swiped away, still unanswered.
    var waiting: String?
    var reveal: () -> Void = {}
    /// An interaction wants the screen: the sheet gives way to it.
    var interactionArrived = false
    /// On from opening the sheet until it is gone; the conversation's own sheets wait for it.
    @Binding var sheetUp: Bool
    @Environment(AppModel.self) private var app
    @State private var showSheet = false
    /// The keyboard was up when the sheet opened: it comes back after.
    @State private var refocus = false

    private var composer: ComposerModel { model.composer }

    var body: some View {
        let summary = summary
        let tail = tail
        let hasStatus = !summary.characters.isEmpty || !tail.isEmpty
        VStack(spacing: 0) {
            if waiting != nil || hasStatus {
                bar(summary: summary, tail: tail, hasStatus: hasStatus)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: hasStatus)
        .animation(.snappy, value: waiting)
        // Whether the goal continues on its own: re-read on goal changes, run edges and `goal/activation-changed`.
        .task(id: "\(composer.goal?.id ?? "")-\(composer.goal?.revision ?? 0)-\(model.running)-\(app.revision("goal/activation-changed"))") {
            await composer.refreshGoalActivation()
        }
        .sheet(isPresented: $showSheet, onDismiss: {
            sheetUp = false
            if refocus { composer.requestFocus() }
        }) {
            ComposerStatusSheet(model: model, waiting: waiting, reveal: reveal)
        }
        .onChange(of: interactionArrived) { _, arrived in
            if arrived { showSheet = false }
        }
    }

    private func bar(summary: AttributedString, tail: String, hasStatus: Bool) -> some View {
        HStack(spacing: 0) {
            if let waiting {
                Button(action: reveal) {
                    HStack(spacing: 6) {
                        StatusDot(state: .waiting)
                        Text(waiting).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
                        if !hasStatus {
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(Palette.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Palette.waiting.opacity(0.18))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
            }
            if hasStatus {
                Button(action: open) {
                    HStack(spacing: 0) {
                        if !summary.characters.isEmpty {
                            Text(summary).lineLimit(1)
                        }
                        if !tail.isEmpty {
                            Text(summary.characters.isEmpty ? tail : " · " + tail).lineLimit(1).layoutPriority(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .padding(.leading, 14)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看任务和目标")
                if showsCompact {
                    Button("压缩") { Haptics.tap(); composer.compact() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(canCompact ? Palette.ink : Palette.faint)
                        .disabled(!canCompact)
                        .hitTarget()
                }
                Button(action: open) {
                    Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(Palette.secondary)
                        .frame(minWidth: 36, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.grouped)
        .clipShape(Capsule())
    }

    private func open() {
        refocus = keyboardUp
        sheetUp = true
        showSheet = true
    }

    /// The manual compaction needs an idle agent (the engine refuses it otherwise).
    private var canCompact: Bool { !model.running && !composer.compacting }

    private var showsCompact: Bool { !keyboardUp && composer.contextNearlyFull }

    /// What may give way when the line runs short: plan mode, the tasks, the goal, sends in flight.
    private var summary: AttributedString {
        var parts: [AttributedString] = []
        func add(_ text: String, color: Color? = nil) {
            var part = AttributedString(text)
            if let color { part.foregroundColor = color }
            parts.append(part)
        }
        if !keyboardUp {
            if composer.planActive { add(String(localized: "计划模式")) }
            // A finished list has nothing left to report once the run is over; the sheet still has it.
            let todos = composer.todos
            let progress = TodoProgress(todos)
            let tasksLive = !todos.isEmpty && (model.running || progress.done < progress.total)
            if tasksLive {
                add(progress.text)
                if let current = todos.first(where: { $0.status == "in_progress" }) { add(current.content) }
            }
            if let goal = composer.visibleGoal {
                if goal.phase == "blocked" {
                    add(String(localized: "目标受阻"), color: Palette.removed)
                } else if composer.goalPaused(goal) {
                    add(String(localized: "目标已暂停"))
                } else if !tasksLive {
                    add(String(localized: "目标"))
                    add(goal.objective)
                }
            }
        }
        // Queued and steering messages show at the foot of the conversation (`QueuedMessages`).
        if composer.visiblePending.contains(where: { $0.placement == .transcript }) {
            add(String(localized: "发送中…"))
        }
        var joined = AttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { joined += AttributedString(" · ") }
            joined += part
        }
        return joined
    }

    /// What stays whole however long the rest is.
    private var tail: String {
        [
            !keyboardUp && composer.contextNearlyFull ? String(localized: "上下文快满了") : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

extension View {
    /// Follows the software keyboard (a hardware keyboard's short accessory bar doesn't count).
    func trackKeyboard(_ up: Binding<Bool>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            up.wrappedValue = ((note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0) > 120
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            up.wrappedValue = false
        }
    }
}

/// 「2/5」: finished over all.
private struct TodoProgress {
    let done: Int
    let total: Int

    init(_ todos: [TodoItem]) {
        done = todos.filter { $0.status == "completed" }.count
        total = todos.count
    }

    var text: String { String(localized: "任务 \(done)/\(total)") }
}

/// What the status bar stands for, one section each: the agent's tasks (C-120) and the
/// goal (C-121), under whatever needs a decision now. Every
/// section comes and goes on its own, so the sheet closes itself once the last one
/// leaves rather than standing there empty.
struct ComposerStatusSheet: View {
    let model: SessionModel
    var waiting: String?
    var reveal: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private var composer: ComposerModel { model.composer }

    var body: some View {
        NavigationStack {
            List {
                attention
                let todos = composer.todos
                if !todos.isEmpty {
                    Section(TodoProgress(todos).text) {
                        ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in TodoRow(item: todo) }
                    }
                    .groupedRow()
                }
                GoalSection(composer: composer)
            }
            .groupedList()
            .navigationTitle("状态")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
            // The last section leaving (the tasks cleared, the goal done) leaves nothing to
            // show: close rather than stand there empty.
            .onChange(of: hasContent) { _, has in
                if !has { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .sheetNotices()
    }

    /// Whether any section still has something in it. The status bar hides on the same
    /// terms, so an empty sheet has no bar left to have opened it either.
    private var hasContent: Bool {
        waiting != nil
            || composer.contextNearlyFull
            || composer.planActive
            || !composer.todos.isEmpty
            || composer.visibleGoal != nil
            || composer.visiblePending.contains { $0.placement == .transcript }
    }

    @ViewBuilder
    private var attention: some View {
        let occupancy = composer.contextNearlyFull ? composer.contextOccupancy : nil
        if waiting != nil || occupancy != nil || composer.planActive {
            Section {
                if let waiting {
                    Button(action: reveal) {
                        HStack(spacing: 8) {
                            StatusDot(state: .waiting)
                            Text(waiting).foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let occupancy {
                    HStack {
                        Text("上下文已用 \(occupancy.percent)%")
                        Spacer(minLength: 8)
                        Button("压缩") { Haptics.tap(); composer.compact() }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(model.running || composer.compacting ? Palette.faint : Palette.ink)
                            .disabled(model.running || composer.compacting)
                            .hitTarget()
                    }
                }
                if composer.planActive {
                    Toggle("计划模式", isOn: Binding(get: { composer.planActive }, set: { on in Haptics.select(); composer.setPlan(on) }))
                        .disabled(composer.planSwitching)
                }
            }
            .groupedRow()
        }
    }
}

// MARK: Goal (C-121)

/// The goal: phase, objective and its actions. Hidden when there is none, it is
/// complete, or it was just cleared (until the projection catches up).
private struct GoalSection: View {
    let composer: ComposerModel
    @State private var busy = false
    @State private var actionError: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingClear = false

    var body: some View {
        if let goal = composer.visibleGoal {
            let armed = composer.armed(goal)
            Section("目标") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(composer.goalPhaseName(goal)).font(.caption.weight(.medium)).foregroundStyle(goal.phase == "blocked" ? Palette.removed : Palette.secondary)
                            Text(goal.objective).font(.subheadline).foregroundStyle(Palette.ink).lineLimit(4)
                            if goal.phase == "blocked", let reason = goal.blockedReason {
                                Text(reason).font(.caption).foregroundStyle(Palette.removed).lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                        if busy { ProgressView().controlSize(.small).hitTarget() }
                        else { actions(goal, armed: armed) }
                    }
                    if let actionError {
                        Text(actionError).font(.caption).foregroundStyle(Palette.removed)
                    }
                }
            }
            .groupedRow()
            .task(id: "\(goal.id)-\(goal.revision)-\(goal.phase)") { actionError = nil }
            .sheet(isPresented: $editing) { editSheet }
            .confirmationDialog("清除目标？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清除目标", role: .destructive) { run(.clear) }
            }
        }
    }

    private func actions(_ goal: GoalInfo, armed: Bool?) -> some View {
        Menu {
            if goal.phase == "active" && armed == true {
                Button { run(.pause) } label: { Label("暂停目标", systemImage: "pause") }
            }
            if goal.phase == "paused" || (goal.phase == "active" && armed == false) {
                Button { run(.resume) } label: { Label("恢复目标", systemImage: "play") }
            }
            Button { draft = goal.objective; editing = true } label: { Label("编辑目标", systemImage: "pencil") }
            Button(role: .destructive) { confirmingClear = true } label: { Label("清除目标", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary)
                .hitTarget()
        }
        .accessibilityLabel("目标操作")
    }

    /// Goal actions run one at a time.
    private func run(_ action: ComposerModel.GoalAction) {
        guard !busy else { return }
        busy = true
        actionError = nil
        Task {
            let error = await composer.goalAction(action)
            busy = false
            actionError = error
            if error == nil {
                Haptics.select()
                if case .edit = action { editing = false }
            }
        }
    }

    private var editSheet: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.body)
                .padding(.horizontal, 12)
                .scrollContentBackground(.hidden)
                .background(Palette.background)
                .overlay(alignment: .bottom) {
                    if let actionError { Text(actionError).font(.footnote).foregroundStyle(Palette.removed).padding() }
                }
                .navigationTitle("编辑目标")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            let objective = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            run(.edit(objective))
                        }
                        .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Queue (C-95)

/// Messages steered into the running turn and those waiting for the next one, at the foot
/// of the conversation, then this client's on their way. Each is a faded bubble of the user's
/// with 「取消」 under it: out of the inbox, its text back in the input. A steered one says it
/// waits for the step to end; a queued one (sent with 「排队发送」) can still be steered from
/// its long-press menu. One operation at a time.
struct QueuedMessages: View {
    let model: SessionModel
    @State private var busy: String?

    private var composer: ComposerModel { model.composer }

    var body: some View {
        let rows = composer.queueRows
        let steering = composer.steerRows
        let sending = composer.visiblePending.filter { $0.placement != .transcript }
        if !rows.isEmpty || !steering.isEmpty || !sending.isEmpty {
            VStack(alignment: .trailing, spacing: 14) {
                ForEach(steering) { row in
                    message(row) {
                        // Stopped before the step ended: the Host hands it over with the next message.
                        HStack(spacing: 6) {
                            if model.running {
                                ProgressView().controlSize(.mini)
                                Text("插话中，这一步做完就送到")
                            } else {
                                Text("下次发消息时一起送到")
                            }
                        }
                        .foregroundStyle(Palette.secondary)
                    }
                }
                ForEach(rows) { row in
                    message(row) { EmptyView() }
                        .contextMenu {
                            if model.running {
                                // DSH's steer: the running turn takes it at its next step, nothing is stopped.
                                Button { steer(row) } label: { Label("立即发送", systemImage: "paperplane") }
                            }
                            Button { withdraw(row) } label: { Label("取消", systemImage: "arrow.uturn.backward") }
                        }
                }
                ForEach(sending) { echo in
                    bubble(echo.text.isEmpty ? echo.attachments.joined(separator: "、") : MessageQuotes.preview(echo.text),
                           attachments: echo.text.isEmpty ? 0 : echo.attachments.count) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(echo.placement == .steering ? "插话发送中…" : "发送中…")
                        }
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                        .frame(minHeight: 28)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(.snappy, value: rows.map(\.id) + steering.map(\.id))
        }
    }

    /// A message in the inbox: its bubble, what it waits for, and 「取消」.
    private func message(_ row: QueueRow, @ViewBuilder status: () -> some View) -> some View {
        bubble(row.preview.isEmpty ? row.attachments.joined(separator: "、") : row.preview,
               attachments: row.preview.isEmpty ? 0 : row.attachments.count) {
            HStack(spacing: 14) {
                status()
                if busy == row.id {
                    ProgressView().controlSize(.mini).frame(minWidth: 44)
                } else {
                    Button("取消") { withdraw(row) }
                        .buttonStyle(.plain)
                        .foregroundStyle(busy != nil ? Palette.faint : Palette.ink)
                        .disabled(busy != nil)
                        .hitTarget()
                        .accessibilityHint("撤回这条消息，文字放回输入框")
                }
            }
            .font(.footnote)
            .frame(minHeight: 28)
        }
    }

    /// A faded bubble of the user's, what happens to it below.
    private func bubble(_ text: String, attachments: Int, @ViewBuilder footer: () -> some View) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if attachments > 0 {
                    Label("\(attachments)", systemImage: "paperclip").labelStyle(.titleAndIcon).font(.caption)
                }
                Text(text).lineLimit(4).multilineTextAlignment(.leading)
            }
            .font(.body)
            .lineSpacing(3)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .userBubble()
            .opacity(0.6)
            footer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
        .transition(.opacity)
    }

    private func withdraw(_ row: QueueRow) {
        run(row) { await composer.withdrawQueued(row) }
    }

    private func steer(_ row: QueueRow) {
        run(row) { await composer.steerQueued(row.id) }
    }

    private func run(_ row: QueueRow, _ work: @escaping () async -> Void) {
        guard busy == nil else { return }
        Haptics.tap()
        busy = row.id
        Task {
            await work()
            if busy == row.id { busy = nil }
        }
    }
}
