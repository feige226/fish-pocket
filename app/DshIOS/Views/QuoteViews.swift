import SwiftUI

/// One quote, compact (the web's `QuotePreview`): the quote mark and the text on one line, the
/// same in the composer and in a sent message. Cut short, a tap shows it whole. In the composer
/// the mark is the ✕ that takes the quote out.
struct QuotePreview: View {
    let text: String
    var remove: (() -> Void)?
    @State private var fullWidth: CGFloat = 0
    @State private var shownWidth: CGFloat = 0
    @State private var showAll = false

    private var line: String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }
    private var clipped: Bool { fullWidth > shownWidth + 1 || text.contains(where: \.isNewline) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.footnote).foregroundStyle(Palette.faint).hitTarget()
                }
                .buttonStyle(.plain)
                // The full 44 pt to tap, without spreading the line apart.
                .padding(-12)
                .accessibilityLabel("移除引用")
            } else {
                Image(systemName: "quote.opening").font(.caption2.weight(.semibold)).foregroundStyle(Palette.faint)
                    .accessibilityHidden(true)
            }
            Text(line)
                .lineLimit(1)
                .foregroundStyle(Palette.secondary)
                .onGeometryChangeCompat(for: CGFloat.self) { $0.size.width } action: { shownWidth = $0 }
                .background(alignment: .leading) {
                    Text(line).lineLimit(1).fixedSize().hidden()
                        .onGeometryChangeCompat(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
                }
                .contentShape(Rectangle())
                .onTapGesture { if clipped { showAll = true } }
                .popover(isPresented: $showAll) { whole.presentationCompactAdaptation(.popover) }
                .accessibilityLabel(Text("引用：\(text)"))
                .accessibilityAddTraits(clipped ? .isButton : [])
        }
        .font(.callout)
        .frame(maxWidth: 300, alignment: .leading)
    }

    /// The text in full, as long as it is: a short one fits, a long one scrolls.
    private var whole: some View {
        let body = Text(text).font(.callout).foregroundStyle(Palette.ink).textSelection(.enabled)
            .padding(12).frame(width: 300, alignment: .leading)
        return ViewThatFits(in: .vertical) {
            body.fixedSize(horizontal: false, vertical: true)
            ScrollView { body }
        }
        .frame(maxHeight: 360)
    }
}

/// The draft's quotes over the input, each with its ✕; sent ahead of the text.
struct QuoteRail: View {
    let quotes: [String]
    let remove: (Int) -> Void

    var body: some View {
        if !quotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(quotes.enumerated()), id: \.offset) { index, quote in
                    QuotePreview(text: quote) { withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) { remove(index) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }
}

/// A message of the user's with its quotes recognized (`MessageQuotes.segments`); a message
/// without any is the one `Text` it always was. `lineLimit` folds each run of text.
struct QuotedText: View {
    let text: String
    var lineLimit: Int?

    var body: some View {
        let segments = MessageQuotes.segments(text)
        if segments.count == 1, case .text(let only) = segments[0] {
            Text(only).lineLimit(lineLimit)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .quote(let quote): QuotePreview(text: quote)
                    case .text(let text): Text(text).lineLimit(lineLimit)
                    }
                }
            }
        }
    }
}
