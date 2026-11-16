import SwiftUI
import Perception
/// The official 思考过程翻译 plugin (`@deepseek-ai/dsh-experimental-cot-translation-bundle`)
/// in the native reasoning sheet. Its web half registers on the chat's reasoning body;
/// here the sheet asks the same Host methods (`cotTranslation/limits`, `cotTranslation/translate`)
/// while the plugin is enabled. The Host keeps every result in the session, so reopening
/// reuses it; the summary row and the session stay in the original language.
@MainActor
@Perceptible
final class ReasoningTranslation {
    /// The accepted service and language with the request limit; nil while the plugin is off.
    private(set) var setup: (provider: String, targetLanguage: String, maxTextChars: Int)?
    /// The reasoning with every translated fragment in place, the rest as written.
    private(set) var text = ""
    private(set) var pending = false
    private(set) var failed = false

    @PerceptionIgnored private let sessionId: String
    @PerceptionIgnored private let client: EngineClient
    @PerceptionIgnored private var fragments: [Fragment] = []
    @PerceptionIgnored private var cache: [String: String] = [:]
    @PerceptionIgnored private var worker: Task<Void, Never>?
    /// Bumped by `cancel()`: a run whose number is stale has been called off.
    @PerceptionIgnored private var generation = 0
    @PerceptionIgnored private var source = (text: "", running: false)

    init(sessionId: String, client: EngineClient) {
        self.sessionId = sessionId
        self.client = client
    }

    /// Reads the plugin's settings; a failed read means it is off (the method is not mounted).
    /// Read again on 重试, so a service fixed in the meantime is the one asked.
    func prepare() async {
        guard let value = try? await client.call("cotTranslation/limits"),
              let provider = value["preferences"]["provider"].string,
              let language = value["preferences"]["targetLanguage"].string,
              let limit = value["maxTextChars"].int, limit >= 2 else {
            cancel()
            setup = nil
            return
        }
        // `auto` follows the interface language, as the web follows the browser's.
        let target = language == "auto" ? (Bundle.main.preferredLocalizations.first ?? "en") : language
        if let setup, setup != (provider, target, limit) {
            cancel()
            cache = [:]
        }
        setup = (provider, target, limit)
        failed = false
        update(source.text, running: source.running)
    }

    /// Adopts the current reasoning and translates newly completed fragments.
    func update(_ text: String, running: Bool) {
        source = (text, running)
        guard let setup else { return }
        fragments = Fragment.split(text, running: running, limit: setup.maxTextChars)
        compose()
        run()
    }

    func retry() {
        Task { await prepare() }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        generation += 1
        pending = false
    }

    private func compose() {
        text = fragments.map { ($0.complete ? cache[$0.text] ?? $0.text : $0.text) + $0.suffix }.joined()
    }

    private var next: Fragment? {
        fragments.first { $0.complete && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cache[$0.text] == nil }
    }

    /// One request at a time, in order; a failure stops until 重试.
    private func run() {
        guard worker == nil, !failed, let setup, next != nil else { return }
        pending = true
        let generation = generation
        worker = Task { [weak self] in
            // A cancelled run that ends late leaves the state of the run after it alone.
            defer { if let self, self.generation == generation { self.worker = nil; self.pending = false } }
            while let self, self.generation == generation, let fragment = self.next {
                let request: JSON = ["request": [
                    "text": .string(fragment.text),
                    "targetLanguage": .string(setup.targetLanguage),
                    "provider": .string(setup.provider),
                    "sessionId": .string(self.sessionId),
                ]]
                do {
                    let value = try await self.client.call("cotTranslation/translate", request)
                    guard self.generation == generation else { return }
                    self.cache[fragment.text] = value.string ?? fragment.text
                    self.compose()
                } catch {
                    if self.generation == generation { self.failed = true }
                    return
                }
            }
        }
    }

    /// One piece of the reasoning and the whitespace after it, which is never sent.
    struct Fragment: Equatable {
        let text: String
        let suffix: String
        /// A finished paragraph, or a request-sized piece of a long one; a streaming tail is not.
        let complete: Bool

        /// Paragraphs split at blank lines, each cut to `limit` UTF-16 units at a space when there
        /// is one and never inside a surrogate pair (as the web client cuts them).
        static func split(_ text: String, running: Bool, limit: Int) -> [Fragment] {
            let whole = text as NSString
            let separators = try! NSRegularExpression(pattern: #"\r?\n(?:[\t ]*\r?\n)+"#)
            let lastSpace = try! NSRegularExpression(pattern: #"\s+\S*$"#)
            let leadingSpace = try! NSRegularExpression(pattern: #"^\s+"#)
            var result: [Fragment] = []
            var start = 0
            let matches = separators.matches(in: text, range: NSRange(location: 0, length: whole.length))
            for index in 0...matches.count {
                let match = index < matches.count ? matches[index] : nil
                let end = match?.range.location ?? whole.length
                var remaining = whole.substring(with: NSRange(location: start, length: end - start)) as NSString
                while remaining.length > limit {
                    var cut = limit
                    if CFStringIsSurrogateHighCharacter(remaining.character(at: cut - 1)) { cut -= 1 }
                    let head = NSRange(location: 0, length: cut)
                    if let space = lastSpace.firstMatch(in: remaining as String, range: head), space.range.location > 0 {
                        cut = space.range.location
                    }
                    let piece = remaining.substring(to: cut)
                    remaining = remaining.substring(from: cut) as NSString
                    let space = leadingSpace.firstMatch(in: remaining as String, range: NSRange(location: 0, length: remaining.length))
                    let suffix = space.map { remaining.substring(with: $0.range) } ?? ""
                    remaining = remaining.substring(from: (suffix as NSString).length) as NSString
                    result.append(Fragment(text: piece, suffix: suffix, complete: true))
                }
                let suffix = match.map { whole.substring(with: $0.range) } ?? ""
                result.append(Fragment(text: remaining as String, suffix: suffix, complete: match != nil || !running))
                if let match { start = match.range.location + match.range.length }
            }
            return result
        }
    }
}

/// Above the reasoning while the plugin is on: switch between translation and original,
/// the request under way, and a failure with 重试. Failed shows the original.
struct ReasoningTranslationBar: View {
    let translation: ReasoningTranslation
    @Binding var original: Bool

    var body: some View {
        WithPerceptionTracking {

        HStack(spacing: 10) {
            Button(original || translation.failed ? "查看译文" : "查看原文") { original.toggle() }
                .disabled(translation.failed)
            if translation.pending {
                ProgressView().controlSize(.small).accessibilityLabel("正在翻译思考内容")
            }
            if translation.failed {
                Text("翻译暂不可用，已显示原文").foregroundStyle(Palette.secondary)
                Button("重试") { translation.retry() }
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
    
        }}
}
