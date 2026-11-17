import SwiftUI

import Perception
/// 举报插件: what is wrong with a market plugin, sent to Fish Pocket for review; then its number, and
/// the offer to switch the plugin off while it is reviewed.
struct PluginReportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let entry: StoreEntry
    let market: String?

    @State private var category: PluginReports.Category?
    @State private var description = ""
    @State private var log = ""
    @State private var sending = false
    @State private var failure: String?
    @State private var receipt: PluginReports.Receipt?
    @State private var disabling = false
    @FocusState private var focused: Bool

    private var installed: PluginPackage? {
        app.plugins.package(entry.name).flatMap { $0.installed ? $0 : nil }
    }
    private var ready: Bool {
        category != nil && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        WithPerceptionTracking {

        NavigationStack {
            Group {
                if let receipt { sent(receipt) } else { form }
            }
            .navigationTitle(receipt == nil ? "举报插件" : "")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        .tint(Palette.ink)
        .interactiveDismissDisabled(sending)
    
        }}

    // MARK: Form

    private var form: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    StoreArt(name: entry.name, icon: entry.icon, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName).font(.callout.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text([entry.name, entry.versionNumber].filter { !$0.isEmpty }.joined(separator: "@"))
                            .font(.caption.monospaced()).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .groupedRow()

            Section("问题类型") {
                ForEach(PluginReports.Category.allCases) { option in
                    Button {
                        Haptics.select()
                        category = option
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).foregroundStyle(Palette.ink)
                                Text(option.detail).font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer(minLength: 0)
                            if category == option {
                                Image(systemName: "checkmark").font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == option ? [.isSelected, .isButton] : .isButton)
                }
            }
            .groupedRow()

            Section("问题描述") {
                TextField("说明你看到了什么、在哪里看到的", text: $description, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($focused)
            }
            .groupedRow()

            Section {
                TextField("可粘贴相关的输出或报错", text: $log, axis: .vertical)
                    .font(.footnote.monospaced())
                    .lineLimit(2...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("日志（可选）")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("举报会发给 Fish Pocket 人工审核，不会通知插件作者。确认有问题的插件会从插件市场下架。")
                    if app.fishPocket.signedIn { Text("会附上你登录的 Fish Pocket 账号，便于核实。") }
                }
            }
            .groupedRow()

            Section {
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Palette.removed)
                }
                Button {
                    Task { await send() }
                } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView().controlSize(.small).tint(Palette.onInk) }
                        Text(sending ? "正在提交…" : "提交举报")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(height: 48))
                .disabled(!ready)
                .opacity(ready || sending ? 1 : 0.4)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.interactively)
    }

    private func send() async {
        guard let category else { return }
        focused = false
        sending = true
        failure = nil
        defer { sending = false }
        do {
            let sent = try await PluginReports.shared.submit(
                app,
                plugin: entry.name,
                version: entry.versionNumber.isEmpty ? nil : entry.versionNumber,
                source: entry.version?["install"]["spec"].string ?? entry.version?["source"]["url"].string,
                market: market,
                category: category,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                log: log
            )
            Haptics.success()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { receipt = sent }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? String(localized: "提交失败，请稍后再试。")
        }
    }

    // MARK: Receipt

    private func sent(_ receipt: PluginReports.Receipt) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Palette.running)
                    .padding(.top, 24)
                Text("举报已提交").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink).padding(.top, 14)
                Text("我们会尽快审核。处理进度可以在「插件」页右上角的「我的举报」里查看。")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 12)
                VStack(spacing: 4) {
                    Text("举报编号").font(.footnote).foregroundStyle(Palette.secondary)
                    Text(receipt.id).font(.title3.monospaced().weight(.medium)).foregroundStyle(Palette.ink).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.top, 22)
                if let installed, installed.enabled { disableCard(installed) }
                Button("完成") { dismiss() }
                    .buttonStyle(.capsule(height: 48))
                    .padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .background(Palette.background)
    }

    /// The plugin is running here: offer to stop it until the report is settled.
    private func disableCard(_ package: PluginPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("要先停用这个插件吗？").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
            Text("它已装在本机并正在启用。停用后它不再运行，以后可以在「已安装」里重新启用。")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
            Button {
                disabling = true
                Task {
                    await app.plugins.setEnabled(package, false)
                    disabling = false
                }
            } label: {
                HStack(spacing: 8) {
                    if disabling { ProgressView().controlSize(.small) }
                    Text("停用插件")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.capsule(.secondary, height: 44))
            .disabled(disabling)
        }
        .padding(16)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 14)
    }
}

/// 我的举报: the reports this device sent and where each one stands.
struct PluginReportsPage: View {
    @Environment(\.dismiss) private var dismiss
    private var reports: PluginReports { PluginReports.shared }

    var body: some View {
        WithPerceptionTracking {

        NavigationStack {
            Group {
                if reports.receipts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "flag").font(.largeTitle).foregroundStyle(Palette.secondary)
                        Text("还没有举报").font(.headline)
                        Text("在插件详情页底部可以举报有问题的插件。").font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(reports.receipts) { receipt in row(receipt) }
                                .onDelete { offsets in reports.forget(offsets.map { reports.receipts[$0].id }) }
                        } footer: {
                            Text("只保存在这台设备上。左滑可移除记录，不影响审核。")
                        }
                        .groupedRow()
                    }
                    .groupedList()
                    .refreshable { await reports.refreshReceipts() }
                }
            }
            .navigationTitle("我的举报")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
            .task { await reports.refreshReceipts() }
        }
        .tint(Palette.ink)
    
        }}

    private func tone(_ status: String) -> Color {
        switch status {
        case "removed": Palette.running
        case "reviewing": Palette.waiting
        default: Palette.secondary
        }
    }

    private func row(_ receipt: PluginReports.Receipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(receipt.plugin).font(.callout.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                PluginTag(text: receipt.statusTitle, tone: tone(receipt.status))
            }
            Text("\(receipt.categoryTitle) · \(Date(timeIntervalSince1970: receipt.createdAt / 1000).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(Palette.secondary)
            if let note = receipt.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            }
            Text(receipt.id).font(.caption.monospaced()).foregroundStyle(Palette.faint).textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
