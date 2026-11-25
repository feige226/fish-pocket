import SwiftUI

/// The 探索 page's own icons: a small scene in ink lines with one piece in the spot color, the
/// piece that says what the entry does: the part being plugged in, the node that is lit, the
/// phone in front of the computer. Drawn here rather than taken from SF Symbols, so the page has
/// a look of its own, and in one color for all of them, so the page stays black and white.
///
/// Every icon is drawn on a 38-point grid and scaled to `size`.
struct ExploreGlyph: View {
    enum Kind {
        case miniApps, plugins, connectors, phoneControl, remote, watch, shortcuts, web, share, settings
        case rate, site, feedback, wechat, discord, follow
    }

    let kind: Kind
    var size: CGFloat = 38

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 38, y: canvas.height / 38)
            var pen = Pen(context: context)
            switch kind {
            case .miniApps: pen.miniApps()
            case .plugins: pen.plugins()
            case .connectors: pen.connectors()
            case .phoneControl: pen.phoneControl()
            case .remote: pen.remote()
            case .watch: pen.watch()
            case .shortcuts: pen.shortcuts()
            case .web: pen.web()
            case .share: pen.share()
            case .settings: pen.settings()
            case .rate: pen.rate()
            case .site: pen.site()
            case .feedback: pen.feedback()
            case .wechat: pen.wechat()
            case .discord: pen.discord()
            case .follow: pen.follow()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// What the icons are drawn with: ink lines of one weight with round ends, and the spot color.
private struct Pen {
    var context: GraphicsContext
    private let ink = GraphicsContext.Shading.color(Palette.ink)
    private let spot = GraphicsContext.Shading.color(Palette.spot)
    private let line = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)

    private func stroke(_ path: Path) { context.stroke(path, with: ink, style: line) }
    private func fill(_ path: Path) { context.fill(path, with: spot) }

    private func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius, style: .continuous)
    }

    private func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    private func lines(_ points: [(CGFloat, CGFloat)]...) -> Path {
        Path { path in
            for run in points {
                path.addLines(run.map { CGPoint(x: $0.0, y: $0.1) })
            }
        }
    }

    /// A square on a circle, as the Mini Apps tab's symbol was: something made, set on a round.
    mutating func miniApps() {
        stroke(dot(15, 15, 10))
        fill(box(16, 16, 17, 17, 4.5))
    }

    /// A block with a socket in its side, and the piece on its way in.
    mutating func plugins() {
        stroke(Path { path in
            path.move(to: CGPoint(x: 22.5, y: 15.3))
            path.addLine(to: CGPoint(x: 22.5, y: 14))
            path.addArc(tangent1End: CGPoint(x: 22.5, y: 9.5), tangent2End: CGPoint(x: 18, y: 9.5), radius: 4.5)
            path.addLine(to: CGPoint(x: 9, y: 9.5))
            path.addArc(tangent1End: CGPoint(x: 4.5, y: 9.5), tangent2End: CGPoint(x: 4.5, y: 14), radius: 4.5)
            path.addLine(to: CGPoint(x: 4.5, y: 24))
            path.addArc(tangent1End: CGPoint(x: 4.5, y: 28.5), tangent2End: CGPoint(x: 9, y: 28.5), radius: 4.5)
            path.addLine(to: CGPoint(x: 18, y: 28.5))
            path.addArc(tangent1End: CGPoint(x: 22.5, y: 28.5), tangent2End: CGPoint(x: 22.5, y: 24), radius: 4.5)
            path.addLine(to: CGPoint(x: 22.5, y: 22.7))
            path.addArc(center: CGPoint(x: 22.5, y: 19), radius: 3.7, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        })
        fill(box(25.5, 12.5, 9, 13, 2.8).union(dot(25, 19, 2.8)))
    }

    /// Three services joined up, one of them lit.
    mutating func connectors() {
        stroke(lines([(14.6, 27), (23.4, 27)], [(12.4, 22.8), (16.4, 15.7)], [(25.6, 22.8), (21.6, 15.7)]))
        stroke(dot(10, 27, 4))
        stroke(dot(28, 27, 4))
        fill(dot(19, 11, 4.5))
    }

    /// A phone, and a tap landing on it.
    mutating func phoneControl() {
        stroke(box(8, 5, 15, 27, 4.5))
        context.stroke(dot(23.5, 21, 7.5), with: .color(Palette.spot.opacity(0.45)), lineWidth: 1.5)
        fill(dot(23.5, 21, 3.5))
    }

    /// A computer, and the phone in front of it.
    mutating func remote() {
        stroke(box(6, 8, 23, 16, 3.5))
        stroke(lines([(3.5, 28.5), (20, 28.5)]))
        fill(box(23, 15, 10.5, 18, 3))
    }

    /// A watch with something on its face.
    mutating func watch() {
        stroke(box(11, 11, 16, 16, 5))
        stroke(lines([(14.5, 11), (15.5, 5.5), (22.5, 5.5), (23.5, 11)], [(14.5, 27), (15.5, 32.5), (22.5, 32.5), (23.5, 27)]))
        fill(dot(19, 19, 3.5))
    }

    /// A tile of the Shortcuts app, and the spark that runs it.
    mutating func shortcuts() {
        stroke(box(5, 10, 22, 22, 6))
        stroke(lines([(10.5, 19), (21.5, 19)], [(10.5, 24.5), (17, 24.5)]))
        var bolt = lines([(28.5, 4), (22.5, 14.5), (27.5, 14.5), (25, 22.5), (32.5, 11.5), (27.5, 11.5), (30.5, 4)])
        bolt.closeSubpath()
        fill(bolt)
        context.stroke(bolt, with: spot, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }

    /// A browser window with a page in it.
    mutating func web() {
        stroke(box(5, 7, 28, 24, 5))
        stroke(lines([(5, 14.5), (33, 14.5)]))
        context.fill(dot(9.6, 10.9, 1).union(dot(13.2, 10.9, 1)), with: ink)
        fill(box(9.5, 18.5, 9, 8, 2.2))
        stroke(lines([(22.5, 20), (28.5, 20)], [(22.5, 24.5), (26, 24.5)]))
    }

    /// Two sliders, one of them being set.
    mutating func settings() {
        stroke(lines([(5, 12), (19, 12)], [(29, 12), (33, 12)], [(5, 26), (9, 26)], [(19, 26), (33, 26)]))
        stroke(dot(24, 12, 4.5))
        fill(dot(14, 26, 4.8))
    }

    /// A tray, and what leaves it.
    mutating func share() {
        stroke(Path { path in
            path.move(to: CGPoint(x: 13, y: 17))
            path.addLine(to: CGPoint(x: 11.5, y: 17))
            path.addArc(tangent1End: CGPoint(x: 7.5, y: 17), tangent2End: CGPoint(x: 7.5, y: 21), radius: 4)
            path.addLine(to: CGPoint(x: 7.5, y: 28))
            path.addArc(tangent1End: CGPoint(x: 7.5, y: 32), tangent2End: CGPoint(x: 11.5, y: 32), radius: 4)
            path.addLine(to: CGPoint(x: 26.5, y: 32))
            path.addArc(tangent1End: CGPoint(x: 30.5, y: 32), tangent2End: CGPoint(x: 30.5, y: 28), radius: 4)
            path.addLine(to: CGPoint(x: 30.5, y: 21))
            path.addArc(tangent1End: CGPoint(x: 30.5, y: 17), tangent2End: CGPoint(x: 26.5, y: 17), radius: 4)
            path.addLine(to: CGPoint(x: 25, y: 17))
        })
        stroke(lines([(19, 24.5), (19, 13)]))
        var head = lines([(14, 12), (19, 5.5), (24, 12)])
        head.closeSubpath()
        fill(head)
        context.stroke(head, with: spot, style: line)
    }

    /// A star, and the spark of the one just given.
    mutating func rate() {
        var star = Path()
        for point in 0..<10 {
            let radius: CGFloat = point.isMultiple(of: 2) ? 13 : 5.6
            let angle = Double(point) * .pi / 5 - .pi / 2
            let corner = CGPoint(x: 17 + radius * cos(angle), y: 21 + radius * sin(angle))
            if point == 0 { star.move(to: corner) } else { star.addLine(to: corner) }
        }
        star.closeSubpath()
        stroke(star)
        var spark = lines([(31, 3.5), (32.3, 7.7), (36.5, 9), (32.3, 10.3), (31, 14.5), (29.7, 10.3), (25.5, 9), (29.7, 7.7)])
        spark.closeSubpath()
        fill(spark)
    }

    /// A compass, its needle set.
    mutating func site() {
        stroke(dot(19, 19, 13.5))
        var needle = lines([(26.5, 11.5), (21.5, 21.5), (11.5, 26.5), (16.5, 16.5)])
        needle.closeSubpath()
        fill(needle)
        context.fill(dot(19, 19, 1.6), with: ink)
    }

    /// A speech bubble with something to point out.
    mutating func feedback() {
        stroke(Path { path in
            path.move(to: CGPoint(x: 13, y: 28))
            path.addLine(to: CGPoint(x: 10, y: 33.5))
            path.addLine(to: CGPoint(x: 19, y: 28))
            path.addLine(to: CGPoint(x: 28, y: 28))
            path.addArc(tangent1End: CGPoint(x: 33, y: 28), tangent2End: CGPoint(x: 33, y: 23), radius: 5)
            path.addLine(to: CGPoint(x: 33, y: 10))
            path.addArc(tangent1End: CGPoint(x: 33, y: 5), tangent2End: CGPoint(x: 28, y: 5), radius: 5)
            path.addLine(to: CGPoint(x: 10, y: 5))
            path.addArc(tangent1End: CGPoint(x: 5, y: 5), tangent2End: CGPoint(x: 5, y: 10), radius: 5)
            path.addLine(to: CGPoint(x: 5, y: 23))
            path.addArc(tangent1End: CGPoint(x: 5, y: 28), tangent2End: CGPoint(x: 10, y: 28), radius: 5)
            path.closeSubpath()
        })
        fill(box(17.3, 9.5, 3.4, 10, 1.7).union(dot(19, 23.3, 1.9)))
    }

    /// A conversation: a bubble, and the answer in front of it.
    mutating func wechat() {
        stroke(Path { path in
            path.addRoundedRect(in: CGRect(x: 4, y: 5, width: 22, height: 16), cornerSize: CGSize(width: 6, height: 6), style: .continuous)
            path.move(to: CGPoint(x: 9, y: 21))
            path.addLine(to: CGPoint(x: 7.5, y: 25.5))
            path.addLine(to: CGPoint(x: 13, y: 21))
        })
        var tail = lines([(24, 28), (30.5, 34), (30, 26)])
        tail.closeSubpath()
        fill(box(14, 15, 20, 15, 6).union(tail))
    }

    /// A game controller, its buttons lit: a server to play and talk in.
    mutating func discord() {
        stroke(box(4, 10, 30, 19, 9.5))
        stroke(lines([(9.5, 19.5), (16.5, 19.5)], [(13, 16), (13, 23)]))
        fill(dot(24, 17, 2.3).union(dot(28.5, 21.5, 2.3)))
    }

    /// Someone, and the plus that follows them.
    mutating func follow() {
        stroke(dot(15, 13.5, 6))
        stroke(Path { path in
            path.addArc(center: CGPoint(x: 15, y: 33), radius: 11, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        })
        context.stroke(lines([(30, 5), (30, 17)], [(24, 11), (36, 11)]), with: spot,
                       style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
    }
}
