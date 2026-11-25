import SwiftUI
import WebKit

/// Formulas SwiftMath cannot typeset, typeset by KaTeX, which the web version renders every formula
/// with: Chinese in `\text{}`, `\xrightarrow`, `\boxed` inside a formula, `\overset`, `cases` and the
/// rest of what models write, and colours (`\color`, `\colorbox`). KaTeX (`Math/KaTeX`, built by
/// scripts/build-katex.sh) runs in a web view no one sees, on `Math/MathPage.html`; WebKit draws each
/// formula to a PDF, which becomes a picture.
///
/// The first time a formula is asked for, it is not ready: the caller shows the source, and reading
/// it in a view's body draws the view again once the picture arrives.
@MainActor
final class KaTeXTypesetter: NSObject {
    static let shared = KaTeXTypesetter()

    enum State {
        case pending
        case ready(TypesetMath)
        /// KaTeX cannot typeset it either.
        case failed
    }

    /// One formula's outcome, watched on its own: a picture arriving redraws the views that show it,
    /// not every reply on screen.
    @Observable
    final class Slot {
        var state: State = .pending
    }

    private struct Job {
        let key: String
        let latex: String
        let display: Bool
        let size: CGFloat
    }

    private var slots: [String: Slot] = [:]
    /// Keys in the order they were made, to forget the oldest past `capacity`.
    private var order: [String] = []
    private static let capacity = 400

    private var queue: [Job] = []
    private var running = false
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Bool, Never>?
    private var pageReady = false

    func state(latex: String, display: Bool, size: CGFloat) -> State {
        let key = "\(display ? "D" : "T")\(size) \(latex)"
        if let slot = slots[key] { return slot.state }
        let slot = Slot()
        slots[key] = slot
        order.append(key)
        if order.count > Self.capacity {
            let old = order.removeFirst()
            slots[old] = nil
        }
        queue.append(Job(key: key, latex: latex, display: display, size: size))
        if !running {
            running = true
            Task { await drain() }
        }
        return slot.state
    }

    private func drain() async {
        defer { running = false }
        while !queue.isEmpty {
            // WebKit draws nothing for an app in the background, and may never answer: wait.
            guard UIApplication.shared.applicationState != .background else { return requeueLater() }
            guard await page() else {
                // Without the page nothing can be typeset: every formula keeps its source.
                for job in queue { slots[job.key]?.state = .failed }
                queue.removeAll()
                return
            }
            let job = queue.removeFirst()
            guard let slot = slots[job.key] else { continue }
            switch await withDeadline({ await self.typeset(job) }) {
            case .some(.some(let math)): slot.state = .ready(math)
            case .some(.none): slot.state = .failed
            case .none:
                // WebKit did not answer: the page starts afresh, and the formulas still waiting are
                // asked for again the next time a reply shows them.
                webView = nil
                pageReady = false
                slots[job.key] = nil
                for job in queue { slots[job.key] = nil }
                queue.removeAll()
                return
            }
        }
    }

    /// The work's result, or nil when it takes longer than a few seconds.
    private func withDeadline<T>(_ work: @escaping @MainActor () async -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let value = await work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Back in the foreground, the formulas still waiting are typeset.
    private func requeueLater() {
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func resume() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        guard !running, !queue.isEmpty else { return }
        running = true
        Task { await drain() }
    }

    /// The web view with KaTeX loaded, made on first use.
    private func page() async -> Bool {
        if pageReady { return true }
        guard let url = Bundle.main.url(forResource: "MathPage", withExtension: "html"),
              let folder = Bundle.main.resourceURL else { return false }
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        // Wide enough that no formula wraps; it is never on screen.
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 4000, height: 2000), configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = self
        webView = view
        let ok = await withCheckedContinuation { continuation in
            loaded = continuation
            view.loadFileURL(url, allowingReadAccessTo: folder)
        }
        pageReady = ok
        if !ok { webView = nil }
        return ok
    }

    private func typeset(_ job: Job) async -> TypesetMath? {
        guard let webView else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return await typeset(latex, display, size, inks)",
            arguments: ["latex": job.latex, "display": job.display, "size": Double(job.size), "inks": [Self.ink.light, Self.ink.dark]],
            contentWorld: .page)
        guard let frame = result as? [String: Any],
              let x = frame["x"] as? Double, let y = frame["y"] as? Double,
              let width = frame["width"] as? Double, let height = frame["height"] as? Double,
              let descent = frame["descent"] as? Double,
              width > 0, height > 0, width < 4000, height < 2000 else { return nil }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let breaks = (frame["breaks"] as? [Double] ?? []).map { CGFloat($0) }
        guard let light = await picture(webView, rect, breaks) else { return nil }
        guard frame["colored"] as? Bool == true else { return TypesetMath(picture: light, descent: descent) }
        // Shown as drawn, so drawn again for dark mode.
        do {
            _ = try await webView.callAsyncJavaScript("recolor(ink)", arguments: ["ink": Self.ink.dark], contentWorld: .page)
        } catch {
            return nil
        }
        guard let dark = await picture(webView, rect, breaks) else { return nil }
        return TypesetMath(picture: light, descent: descent, dark: dark)
    }

    private func picture(_ webView: WKWebView, _ rect: CGRect, _ breaks: [CGFloat]) async -> TypesetMath.Picture? {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        guard let data = try? await webView.pdf(configuration: configuration),
              let image = Self.picture(pdf: data, size: rect.size) else { return nil }
        return .init(image: image, pieces: Self.cut(image, at: breaks))
    }

    /// The text's ink in light and dark mode, as CSS: what a formula with colours of its own is
    /// drawn in where it has none. Other formulas are tinted, and their ink does not matter.
    private static let ink: (light: String, dark: String) = {
        let ink = UIColor(named: "Ink") ?? .label
        func css(_ style: UIUserInterfaceStyle) -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
            return "rgba(\(channel(red)), \(channel(green)), \(channel(blue)), \(min(max(alpha, 0), 1)))"
        }
        return (css(.light), css(.dark))
    }()

    /// The picture in pieces side by side, cut on whole pixels; none when there is nowhere to cut.
    private static func cut(_ image: UIImage, at breaks: [CGFloat]) -> [UIImage] {
        let scale = image.scale
        let edges = ([0] + breaks.map { ($0 * scale).rounded() / scale } + [image.size.width])
        guard edges.count > 2 else { return [] }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = scale
        return zip(edges, edges.dropFirst()).compactMap { left, right in
            guard right - left > 0 else { return nil }
            return UIGraphicsImageRenderer(size: CGSize(width: right - left, height: image.size.height), format: format).image { _ in
                image.draw(at: CGPoint(x: -left, y: 0))
            }
        }
    }

    /// The PDF's first page drawn at the screen's scale.
    private static func picture(pdf data: Data, size: CGSize) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / box.width, y: -size.height / box.height)
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.drawPDFPage(page)
        }
    }
}

extension KaTeXTypesetter: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(returning: true)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(returning: false)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(returning: false)
        loaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Loaded again on the next formula.
        pageReady = false
        self.webView = nil
    }
}
