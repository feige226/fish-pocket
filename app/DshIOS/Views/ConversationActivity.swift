import SwiftUI

import Perception
/// What the agent has going on beside the conversation, floating over its foot: the web page it
/// works in, as a small picture of it, and its background jobs. One tap opens either, without a trip
/// to the top bar. Each shows only while there is something to see; a running one carries the green dot.
struct ConversationActivity: View {
    let sessionId: String
    let jobs: JobsModel
    /// The workbench already shows the browser beside the conversation (iPad).
    let browserShown: Bool
    let openBrowser: () -> Void
    let openJobs: () -> Void
    @Environment(AppModel.self) private var app

    /// A subagent works in the browser of the conversation that started it.
    @MainActor
    static func browser(of sessionId: String, in app: AppModel) -> BrowserModel? {
        guard let model = BrowserModel.existing(BrowserAgent.owner(of: sessionId, in: app)), model.hasPages else { return nil }
        return model
    }

    /// How much room the timeline leaves under its last row, so what floats here never sits on it.
    @MainActor
    static func room(sessionId: String, jobs: JobsModel, browserShown: Bool, in app: AppModel) -> CGFloat {
        if !browserShown, let browser = browser(of: sessionId, in: app) { return browser.thumbnailSize.height + 12 }
        return jobs.visibleCount > 0 ? 48 : 0
    }

    private var browser: BrowserModel? { Self.browser(of: sessionId, in: app) }

    var body: some View {
        WithPerceptionTracking {

        // Read here so the chips follow a browser made after this view.
        let browser = browserShown ? nil : browser
        HStack(alignment: .bottom, spacing: 8) {
            if let browser {
                // A view of its own: a new picture redraws it alone, and it is the one that watches.
                BrowserThumbnail(browser: browser, action: openBrowser).id(ObjectIdentifier(browser))
            }
            if jobs.visibleCount > 0 {
                chip(
                    text: jobs.live.isEmpty ? Text("\(jobs.visibleCount) 个后台任务") : Text("\(jobs.live.count) 个后台任务运行中"),
                    running: !jobs.live.isEmpty,
                    action: openJobs
                )
            }
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: browser == nil)
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: jobs.visibleCount)
    
        }}

    /// No picture, only the state, as each job's row in the list shows it: a breathing green dot
    /// while one runs, a grey one when all have ended.
    private func chip(text: Text, running: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 7) {
                JobsDot(running: running)
                text.font(.footnote.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .floatingGlass(in: Capsule())
            .hitTarget()
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
        .accessibilityLabel(text)
    }
}

/// The background jobs chip's mark. The halo breathes while a job runs, unless motion is reduced.
private struct JobsDot: View {
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        let color = running ? Palette.running : Palette.faint
        ZStack {
            if running {
                Circle()
                    .fill(color.opacity(breathing ? 0.08 : 0.25))
                    .scaleEffect(breathing ? 1.7 : 1)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 12, height: 12)
        .onAppear { breathe() }
        .onChange(of: running) { _, _ in breathe() }
        .accessibilityHidden(true)
    }

    private func breathe() {
        breathing = false
        guard running, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathing = true }
    }
}
