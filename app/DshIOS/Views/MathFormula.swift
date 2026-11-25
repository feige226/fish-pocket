import SwiftMath
import SwiftUI

/// On the placeholder character standing in for a formula: the formula it stands for.
enum MathFormulaKey: AttributedStringKey {
    typealias Value = MathSyntax.Formula
    static let name = "dsh.mathFormula"
}

/// A typeset formula: a picture of it, and how far it hangs below the text baseline.
struct TypesetMath {
    struct Picture {
        let image: UIImage
        /// The picture cut where running text may wrap it (after `=`, `+` and the like), as in the
        /// web version; empty when it stays whole.
        var pieces: [UIImage] = []
        var parts: [UIImage] { pieces.isEmpty ? [image] : pieces }
    }

    let picture: Picture
    let descent: CGFloat
    /// Set for a formula with colours of its own (`\color`, `\colorbox`): it is shown as drawn, not
    /// in the colour of the text around it, and this is it drawn for dark mode, the rest in light ink.
    var dark: Picture?

    /// Shown in the colour of the text around it.
    var tinted: Bool { dark == nil }

    func picture(dark: Bool) -> Picture { dark ? self.dark ?? picture : picture }

    @MainActor
    func image(_ picture: UIImage) -> Image {
        Image(uiImage: picture).renderingMode(tinted ? .template : .original)
    }
}

/// Formulas drawn by SwiftMath, kept by source and size: a reply is laid out again
/// on every streamed token and every time its row scrolls back into view. What SwiftMath
/// cannot typeset goes to KaTeX (`KaTeXTypesetter`), which takes a moment.
@MainActor
enum MathTypesetter {
    private final class Entry: NSObject {
        let math: TypesetMath?
        init(_ math: TypesetMath?) { self.math = math }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 600
        return cache
    }()

    /// Nil while KaTeX is still at it, or when neither can typeset the formula: its source is shown
    /// instead. Called in a view's body, the view is drawn again when KaTeX's picture arrives.
    static func typeset(_ formula: MathSyntax.Formula, size: CGFloat) -> TypesetMath? {
        if let math = swiftMath(formula, size: size) { return math }
        if case .ready(let math) = KaTeXTypesetter.shared.state(latex: formula.latex, display: formula.display, size: size) { return math }
        return nil
    }

    private static func swiftMath(_ formula: MathSyntax.Formula, size: CGFloat) -> TypesetMath? {
        let key = "\(formula.display ? "D" : "T")\(size) \(formula.latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.math }
        let math = draw(formula, size: size)
        cache.setObject(Entry(math), forKey: key)
        return math
    }

    private static func draw(_ formula: MathSyntax.Formula, size: CGFloat) -> TypesetMath? {
        // On iOS SwiftMath draws nothing for characters its math font lacks, in `\text{}` too:
        // a formula with Chinese in it would lose them, so it goes to KaTeX.
        guard !formula.latex.contains(#/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u{3000}-\u{303F}\u{FF00}-\u{FFEF}]/#) else { return nil }
        // Its pictures are shown in the text's colour, where a `\colorbox` is a solid block: KaTeX
        // draws colours for both light and dark mode.
        guard !formula.latex.contains(#/\\(color|textcolor|colorbox|fcolorbox)(?![A-Za-z])/#) else { return nil }
        var latex = adapted(formula.latex)
        let boxed = unboxed(latex)
        if let boxed { latex = boxed }
        var picture = MathImage(latex: latex, fontSize: size, textColor: .black, labelMode: formula.display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = picture.asImage()
        guard error == nil, let image, let layout, image.size.width > 0 else { return nil }
        guard boxed != nil else { return TypesetMath(picture: .init(image: image), descent: layout.descent) }
        let inset = size * 0.4
        let frame = CGRect(origin: .zero, size: CGSize(width: image.size.width + inset * 2, height: image.size.height + inset * 2))
        let framed = UIGraphicsImageRenderer(size: frame.size).image { _ in
            image.draw(at: CGPoint(x: inset, y: inset))
            let border = UIBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
            UIColor.black.setStroke()
            border.stroke()
        }
        return TypesetMath(picture: .init(image: framed), descent: layout.descent + inset)
    }

    /// What models write that SwiftMath has under another name.
    private static func adapted(_ latex: String) -> String {
        latex
            .replacing(#/\\dots(?![A-Za-z])/#, with: #"\ldots"#)
            .replacing(#/\\(begin|end)\{align\*?\}/#) { "\\\($0.1){aligned}" }
    }

    /// The inside of a formula that is one `\boxed{…}`: SwiftMath has no box, so it is drawn around the picture.
    private static func unboxed(_ latex: String) -> String? {
        guard latex.hasPrefix("\\boxed{"), latex.hasSuffix("}") else { return nil }
        let inner = latex.dropFirst(7).dropLast()
        var depth = 0
        for character in inner {
            if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
            if depth < 0 { return nil }
        }
        return depth == 0 ? String(inner) : nil
    }
}

@MainActor
enum MathText {
    /// Inline Markdown with its formulas typeset in place, at the size of the text around them.
    /// `linkMarks` puts the site's icon before each web link (`LinkIcons`).
    @MainActor
    static func text(_ string: AttributedString, size: CGFloat, dark: Bool, linkMarks: Bool = false) -> Text {
        let webLinks = linkMarks && string.runs.contains { run in run.link.map { $0.scheme == "http" || $0.scheme == "https" } ?? false }
        guard webLinks || string.runs.contains(where: { $0[MathFormulaKey.self] != nil }) else { return Text(string) }
        var text = Text(verbatim: "")
        var previousLink: URL?
        for run in string.runs {
            // One mark per link, though its text may be several runs (a bold word inside it).
            if webLinks, let link = run.link, link != previousLink, let mark = LinkIcons.shared.mark(for: link, size: size) {
                text = text + mark
            }
            previousLink = run.link
            guard let formula = run[MathFormulaKey.self] else {
                text = text + Text(AttributedString(string[run.range]))
                continue
            }
            // Two equal formulas side by side share a run.
            for _ in string[run.range].characters {
                if let math = MathTypesetter.typeset(formula, size: size) {
                    for (index, piece) in math.picture(dark: dark).parts.enumerated() {
                        // A zero-width space: the line may end there. Between two pictures alone it may not.
                        if index > 0 { text = text + Text(verbatim: "\u{200B}") }
                        text = text + Text(math.image(piece)).baselineOffset(-math.descent)
                    }
                } else {
                    text = text + Text(verbatim: formula.source).font(.system(size: size * 0.9, design: .monospaced))
                }
            }
        }
        return text
    }
}

/// A formula on lines of its own: centred, scrolling sideways when wider than the reply.
struct MathBlockView: View {
    let latex: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let size = UIFont.preferredFont(forTextStyle: .body).pointSize
        if let math = MathTypesetter.typeset(.init(latex: latex, display: true, source: latex), size: size) {
            let image = math.image(math.picture(dark: colorScheme == .dark).image).accessibilityLabel(Text(verbatim: latex))
            ViewThatFits(in: .horizontal) {
                image.frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { image }
            }
            .padding(.vertical, 2)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: latex).font(.system(.footnote, design: .monospaced))
            }
        }
    }
}
