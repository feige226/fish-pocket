import SwiftUI
import UIKit

/// A voice message the agent sent (`send_voice_message`): a bubble as wide as it is long, tapped
/// to play or stop. The words are made into speech on the first tap, played as they come, and
/// kept; long-press shows them as text or copies them.
struct VoiceMessageBubble: View {
    let call: ToolCall
    let live: Bool

    @State private var showsText = false
    @Environment(\.sessionModel) private var session
    @Environment(\.botComposer) private var botChat

    static let tool = "send_voice_message"
    /// A sent message, or one being written; a refused one stays among the turn's steps.
    static func handles(_ call: ToolCall) -> Bool { call.displayName == tool && !call.isError }

    private var text: String { call.arguments["text"].string ?? "" }
    private var player: VoiceMessagePlayer { .shared }
    /// Read in the voice picked for this Bot or this conversation, else the default.
    private var owner: VoiceOwner? {
        if case .bot(let id)? = botChat { return .bot(id) }
        return session.map { .session($0.sessionId) }
    }

    var body: some View {
        if !call.finished {
            // A call a finished turn never answered shows nothing.
            if live { making }
        } else if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    bubble
                    // Not played yet, as in a chat app.
                    if !player.played.contains(call.id) {
                        Circle().fill(Palette.spot).frame(width: 8, height: 8)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: player.played.contains(call.id))
                if showsText {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 320, alignment: .leading)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.opacity)
                }
            }
        }
    }

    private var making: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在发语音…").font(.subheadline).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Palette.bubble, in: Capsule())
    }

    private var bubble: some View {
        let playing = player.current == call.id
        let loading = playing && player.loading
        let seconds = player.seconds(id: call.id, text: text, owner: owner)
        return Button {
            player.toggle(id: call.id, text: text, owner: owner)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: playing)
                            .foregroundStyle(playing ? Palette.spot : Palette.ink)
                    }
                }
                .frame(width: 22)
                Spacer(minLength: 0)
                Text(verbatim: "\(seconds)″")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 14)
            .frame(width: Self.width(seconds: seconds), height: 40)
            .background(alignment: .leading) { progress(playing: playing && !loading) }
            .background(Palette.bubble)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showsText.toggle() }
            } label: {
                Label(showsText ? "收起文字" : "转文字", systemImage: "text.bubble")
            }
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("复制文字", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel(player.played.contains(call.id) ? Text("语音消息，\(seconds) 秒") : Text("未播放的语音消息，\(seconds) 秒"))
        .accessibilityHint(Text(playing ? "轻点停止" : "轻点播放"))
        .accessibilityAction(named: Text(showsText ? "收起文字" : "转文字")) { showsText.toggle() }
    }

    /// The played part, filling from the left.
    private func progress(playing: Bool) -> some View {
        let fraction = playing ? player.progress(of: call.id) : 0
        return GeometryReader { geometry in
            Palette.spot.opacity(0.14)
                .frame(width: geometry.size.width * fraction)
                .animation(fraction == 0 ? nil : .linear(duration: 0.1), value: fraction)
        }
        .allowsHitTesting(false)
    }

    /// Longer messages are wider, as in a chat app, up to a third of a phone's width more.
    static func width(seconds: Int) -> CGFloat {
        min(96 + CGFloat(min(seconds, 60)) * 3, 240)
    }
}
