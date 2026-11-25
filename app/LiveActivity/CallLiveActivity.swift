import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// A voice call outside the app: in the Dynamic Island a voice mark (vermilion while she speaks)
/// and the call's length; expanded and on the lock screen, who is on the line, what the call is
/// doing, and 静音 and 结束. A tap opens the call's screen (`fishpocket://call`).
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            CallLockScreen(title: context.attributes.title, avatar: context.attributes.avatar, state: context.state)
                .activityBackgroundTint(nil)
                .widgetURL(DshLink.call.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CallMark(state: state, avatar: context.attributes.avatar, size: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CallElapsed(state: state)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        Text(CallPhaseLabel.text(state)).font(.caption).foregroundStyle(CallTint.of(state))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CallButtons(state: state, height: 42)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                }
            } compactLeading: {
                CallMark(state: state, avatar: context.attributes.avatar, size: 24)
            } compactTrailing: {
                CallElapsed(state: state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } minimal: {
                CallMark(state: state, avatar: context.attributes.avatar, size: 24)
            }
            .widgetURL(DshLink.call.url)
            .keylineTint(CallTint.spot)
        }
    }
}

/// The app's one accent: vermilion, the colour of her voice in the call.
private enum CallTint {
    static let spot = Color(red: 0.95, green: 0.33, blue: 0.17)

    static func of(_ state: CallActivityAttributes.ContentState) -> Color {
        switch state.phase {
        case .speaking: spot
        case .waiting: Color(red: 0.96, green: 0.65, blue: 0.14)
        default: .secondary
        }
    }
}

private enum CallPhaseLabel {
    static func text(_ state: CallActivityAttributes.ContentState) -> LocalizedStringKey {
        switch state.phase {
        case .connecting: "正在接通…"
        case .listening: state.muted ? "已静音" : "在听"
        case .thinking: "在想"
        case .speaking: "在说"
        case .waiting: "等你确认"
        }
    }
}

/// The face of the one on the line, with a vermilion ring while she speaks and a small mark
/// while muted. Without a face (no App Group, a failed drawing) a voice mark in a circle.
private struct CallMark: View {
    let state: CallActivityAttributes.ContentState
    let avatar: String?
    let size: CGFloat

    var body: some View {
        ZStack {
            if let avatar, let url = CallAvatarFile.url(avatar), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                Circle()
                    .strokeBorder(state.phase == .speaking ? CallTint.spot : .clear, lineWidth: max(2, size * 0.07))
            } else {
                Circle().fill(state.phase == .speaking ? CallTint.spot : Color.white.opacity(0.16))
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if state.muted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(Color(white: 0.25)))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
        .accessibilityLabel(Text(CallPhaseLabel.text(state)))
    }
}

/// The call's length, counting up. The timer text takes all the width it is given, so it says
/// which side it keeps to.
private struct CallElapsed: View {
    let state: CallActivityAttributes.ContentState
    var alignment: TextAlignment = .trailing

    var body: some View {
        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
            .multilineTextAlignment(alignment)
    }
}

/// 静音 and 结束, answered in the app's process.
private struct CallButtons: View {
    let state: CallActivityAttributes.ContentState
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleCallMuteIntent()) {
                Label(state.muted ? "取消静音" : "静音", systemImage: state.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: height)
            }
            .tint(.gray)
            Button(intent: HangUpCallIntent()) {
                Label("结束", systemImage: "phone.down.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: height)
            }
            .tint(CallTint.spot)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
}

/// The lock screen: who is on the line, what the call is doing and for how long, the buttons.
private struct CallLockScreen: View {
    let title: String
    let avatar: String?
    let state: CallActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CallMark(state: state, avatar: avatar, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(CallPhaseLabel.text(state)).foregroundStyle(CallTint.of(state))
                        Text(verbatim: "·").foregroundStyle(.secondary)
                        CallElapsed(state: state, alignment: .leading).foregroundStyle(.secondary)
                    }
                    .font(.subheadline.monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            CallButtons(state: state, height: 40)
        }
        .padding(16)
    }
}
