import SwiftUI
import Perception
import UniformTypeIdentifiers

/// 「分享为图片」: the conversation drawn as one long picture, sent on through the system share
/// sheet or saved to the album. Nothing leaves the phone but the picture: no link, no upload.
/// The reader picks the rounds it holds; the picture has the questions and the replies, the work
/// in between as one line per reply, secrets drawn as dots, and the AI label at its foot.
struct ConversationShareSheet: View {
    let title: String
    let rounds: [ShareRound]
    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @State private var selected: Set<String>
    /// The round a reply's menu opened on, scrolled to at once.
    private let focus: String?
    @State private var image: UIImage?
    @State private var drawing = false
    @State private var saving = false

    /// `focus` is the one round to start with (a reply's menu); nil starts with all of them.
    init(title: String, rounds: [ShareRound], focus: String? = nil) {
        self.title = title
        self.rounds = rounds
        let focus = focus.flatMap { id in rounds.contains { $0.id == id } ? id : nil }
        self.focus = focus
        _selected = State(initialValue: Set(focus.map { [$0] } ?? rounds.map(\.id)))
    }

    private var chosen: [ShareRound] { rounds.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                if rounds.isEmpty {
                    Text("这个会话还没有可以分享的内容")
                        .font(.callout)
                        .foregroundStyle(Palette.secondary)
                        .padding(.top, 80)
                } else {
                    ConversationShareCard(title: title, rounds: rounds, selection: $selected)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.stroke) }
                        .frame(maxWidth: ConversationShareCard.width + 44)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                }
            }
            .onAppear { if let focus { proxy.scrollTo(focus, anchor: .top) } }
            }
            actions
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 16)
        }
        .background(Palette.grouped)
        .navigationTitle("分享为图片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if rounds.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    let all = selected.count == rounds.count
                    Button(all ? LocalizedStringKey("全不选") : "全选") { selected = all ? [] : Set(rounds.map(\.id)) }
                }
            }
        }
        // Drawn again a moment after the choice settles, so tapping through rounds stays quick.
        .task(id: selected) {
            image = nil
            guard !selected.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            drawing = true
            defer { drawing = false }
            image = ConversationShareCard.draw(title: title, rounds: chosen, locale: locale)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Text(selected.isEmpty ? String(localized: "点左边的圆圈选择要分享的对话") : String(localized: "已选 \(selected.count) 轮对话"))
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
            HStack(spacing: 10) {
                Button {
                    guard let image else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        await PhotoAlbum.add(image, app: app)
                    }
                } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.capsule(.secondary))
                    .disabled(image == nil || saving)
                if let image {
                    let file = SharedPicture(name: title, image: image)
                    ShareLink(item: file, preview: SharePreview(title, image: Image(uiImage: image))) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.capsule())
                } else {
                    Button {} label: {
                        if drawing { ProgressView() } else { Label("分享", systemImage: "square.and.arrow.up") }
                    }
                    .buttonStyle(.capsule())
                    .disabled(true)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

/// A picture handed to the share sheet as a PNG file named after the conversation, so it keeps
/// that name in Files, AirDrop and chat apps.
struct SharedPicture: Transferable {
    let name: String
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { picture in
            let safe = picture.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe.isEmpty ? "Fish Pocket" : String(safe.prefix(60))).appendingPathExtension("png")
            guard let data = picture.image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - What the picture holds

/// One round of the conversation: a message of the user's (or what started the turn) and the replies to it.
struct ShareRound: Identifiable, Hashable {
    enum Entry: Hashable {
        case user(text: String, images: Int, files: [String])
        /// Something other than the user started the work (a reminder, an event).
        case trigger(title: String, symbol: String)
        /// A reply: its closing words, and its work as the timeline's one line (「运行了 3 条命令」).
        case reply(text: String, work: String?)
    }

    let id: String
    var entries: [Entry]
    /// The assistant turns in it, to start from the one a reply's menu was opened on.
    var turns: [Int] = []

    /// The rounds of a loaded timeline. A reply still being written is left out.
    @MainActor
    static func rounds(of model: SessionModel) -> [ShareRound] {
        var rounds: [ShareRound] = []
        func append(_ entry: Entry, id: String) {
            if rounds.isEmpty { rounds.append(ShareRound(id: id, entries: [])) }
            rounds[rounds.count - 1].entries.append(entry)
        }
        for item in model.items {
            switch item {
            case .user(_, let text, let attachments, _):
                let plain = SessionMention.plain(text)
                rounds.append(ShareRound(id: item.id, entries: [.user(
                    text: SecretMask.masked(plain) ?? plain,
                    images: attachments.filter(\.isImage).count,
                    files: attachments.filter { !$0.isImage }.map { $0.name ?? String(localized: "附件") }
                )]))
            case .questionReply(let reply):
                append(.user(text: SecretMask.masked(reply.copyText) ?? reply.copyText, images: 0, files: []), id: item.id)
            case .trigger(let trigger) where !trigger.post:
                rounds.append(ShareRound(id: item.id, entries: [.trigger(title: trigger.title, symbol: trigger.symbol)]))
            case .assistant(let turn, let blocks, _, let ended):
                if ended == nil && model.running { continue }
                let text = closingText(blocks)
                let calls = blocks.compactMap { if case .tool(let call) = $0 { call } else { nil } }
                guard !text.isEmpty || !calls.isEmpty else { continue }
                append(.reply(text: SecretMask.masked(text) ?? text, work: calls.isEmpty ? nil : StepKind.title(calls: calls)), id: item.id)
                rounds[rounds.count - 1].turns.append(turn)
            default: break
            }
        }
        // A round needs something to show besides what started it.
        return rounds.filter { round in
            round.entries.contains { if case .trigger = $0 { false } else { true } }
        }
    }

    /// The words the reply ends on, as the timeline shows them under the work; a reply that ends
    /// on a tool call (stopped, failed) keeps whatever it said.
    private static func closingText(_ blocks: [AssistantBlock]) -> String {
        var tail: [String] = []
        for block in blocks.reversed() {
            guard case .text(_, let text) = block else { break }
            tail.insert(text, at: 0)
        }
        let closing = tail.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !closing.isEmpty { return closing }
        return blocks.compactMap { if case .text(_, let text) = $0 { text } else { nil } }
            .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The picture

/// The conversation as it is drawn into the picture, at a fixed width so every phone makes the
/// same one, in light colours whatever the app's appearance: it is read on someone else's screen.
/// With a selection it is the sheet's preview: a circle beside each round picks it.
struct ConversationShareCard: View {
    let title: String
    let rounds: [ShareRound]
    var selection: Binding<Set<String>>?

    static let width: CGFloat = 390
    /// The most pixels a picture may have; a longer one is drawn at a lower scale (never below 1).
    private static let pixelBudget: CGFloat = 32_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rounds) { round in
                    row(round).id(round.id)
                }
            }
            .padding(.vertical, 8)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .background(Palette.background)
        // The preview shows what the picture will: code whole, tables wrapped, no buttons.
        .environment(\.drawnAsPicture, true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if let image = UIImage(named: "AppIcon") {
                        Image(uiImage: image).resizable()
                    } else {
                        Image("LaunchMark").resizable().scaledToFit()
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(verbatim: "Fish Pocket").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Text(Date.now, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.caption2)
            Text("内容由 AI 生成")
            Spacer(minLength: 8)
            Text(verbatim: AppLinks.site.host() ?? "")
        }
        .font(.caption)
        .foregroundStyle(Palette.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func row(_ round: ShareRound) -> some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(round.entries.enumerated()), id: \.offset) { _, entry in
                self.entry(entry)
            }
        }
        .padding(.vertical, 12)
        if let selection {
            let on = selection.wrappedValue.contains(round.id)
            HStack(alignment: .top, spacing: 0) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Palette.faint)
                    .frame(width: 44, height: 44)
                    .padding(.top, 4)
                content
                    .padding(.trailing, 20)
                    .opacity(on ? 1 : 0.35)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if on { selection.wrappedValue.remove(round.id) } else { selection.wrappedValue.insert(round.id) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        } else {
            content.padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func entry(_ entry: ShareRound.Entry) -> some View {
        switch entry {
        case .user(let text, let images, let files):
            VStack(alignment: .trailing, spacing: 6) {
                if images > 0 {
                    attachmentChip(images == 1 ? String(localized: "1 张图片") : String(localized: "\(images) 张图片"), symbol: "photo")
                }
                ForEach(Array(files.enumerated()), id: \.offset) { _, name in
                    attachmentChip(name, symbol: "doc")
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
        case .trigger(let title, let symbol):
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
        case .reply(let text, let work):
            VStack(alignment: .leading, spacing: 8) {
                if let work {
                    Label(work, systemImage: "checklist")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                if !text.isEmpty {
                    MarkdownView(text: text, cached: false, selectable: false)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func attachmentChip(_ name: String, symbol: String) -> some View {
        Label(name, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.field, in: Capsule())
    }

    /// The picture: 3× for a usual conversation, lower for a very long one so it stays a size a
    /// phone can hold and a chat app will take.
    @MainActor
    static func draw(title: String, rounds: [ShareRound], locale: Locale) -> UIImage? {
        let card = ConversationShareCard(title: title, rounds: rounds)
            .frame(width: width)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, locale)
        let renderer = ImageRenderer(content: card)
        var picture: UIImage?
        renderer.render { size, draw in
            guard size.width > 0, size.height > 0 else { return }
            let scale = max(1, min(3, (pixelBudget / (size.width * size.height)).squareRoot()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
                // SwiftUI draws as Core Graphics does, from the bottom up.
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                draw(context.cgContext)
            }
        }
        return picture
    }
}
