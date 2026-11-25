import SwiftUI

/// 探索 → 快捷指令: what the app offers Siri and the Shortcuts app, and how to make an automation
/// that opens one Bot or one Mini App. Up to iOS 26 the automation editor offers the app's actions
/// only as plain tiles, with no way to say which Bot, so the steps go through a blank automation;
/// from iOS 27 automations are made like any shortcut, and the Bot is picked straight from search.
struct ShortcutsGuidePage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                actions
                VStack(alignment: .leading, spacing: 10) {
                    Text("设成自动化")
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 4)
                    steps
                }
                Text("Siri 也能直接用，比如说「用 Fish Pocket 打开大肥鱼」。Bot 或 Mini App 改了名字，过一会儿 Siri 就认得新名字。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.grouped)
        .navigationTitle("快捷指令")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ExploreGlyph(kind: .shortcuts, size: 76)
                .padding(.top, 6)
            VStack(spacing: 6) {
                Text("一步打开常用的地方")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.ink)
                Text("在「快捷指令」里用 Fish Pocket 的操作，或者设成自动化，到点、到地方就打开某个 Bot 或 Mini App。")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.stroke) }
    }

    // MARK: What there is

    private struct Action: Identifiable {
        let icon: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        var id: String { icon }
    }

    /// The same five, in the same words and order, as `DshShortcuts`.
    private let actionList = [
        Action(icon: "square.and.pencil", title: "新对话", detail: "打开一个新对话，可以带上一段草稿。"),
        Action(icon: "person.crop.circle", title: "打开 Bot", detail: "直接进入和某个 Bot 的聊天。"),
        Action(icon: "square.on.circle", title: "打开 Mini App", detail: "全屏打开某个 Mini App。"),
        Action(icon: "globe", title: "打开网页版", detail: "直接进入网页版。"),
        Action(icon: "creditcard", title: "查看余额", detail: "打开余额页面。"),
    ]

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(actionList.enumerated()), id: \.element.id) { index, action in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: action.icon)
                        .font(.body)
                        .foregroundStyle(Palette.ink)
                        .frame(width: 26)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title).font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(action.detail).font(.subheadline).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if index < actionList.count - 1 { Divider().padding(.leading, 40) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.stroke) }
    }

    // MARK: Steps

    private struct Step {
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    /// For the system on this device, as each was walked through: iOS 27 made automations part of
    /// the shortcut editor; iOS 18 started listing each Bot in the action search (iOS 17 lists only
    /// 打开 Bot, the Bot picked after); iOS 26 renamed the blank automation's tile and saves with a ✓.
    private var stepList: [Step] {
        if #available(iOS 27, *) {
            return [
                Step(title: "打开「快捷指令」，点下面的 ＋", detail: "新建一个快捷指令。"),
                Step(title: "点「自动化」，选什么时候运行", detail: "在下方搜索框底下的那排标签里。比如选「特定时间」再设好时间，选「到达」要选好地点；没设好的话不会自动运行。"),
                Step(title: "搜索「Bot」，点你要打开的 Bot", detail: "搜索结果里直接列出了你的每个 Bot。想打开 Mini App 就搜「Mini App」。"),
                Step(title: "点左上角返回，就存好了", detail: "在「资料库」的「自动化」里能找到它。"),
            ]
        }
        var list = [
            Step(title: "打开「快捷指令」，切到「自动化」", detail: "在屏幕底部。"),
            Step(title: "新建自动化，选什么时候运行", detail: "点右上角的 ＋（还没有自动化时点页面中间的蓝色按钮），选一个条件，比如「特定时间」。想到点直接打开，在这一页最下面选「立即运行」，然后点「下一步」。"),
        ]
        if #available(iOS 26, *) {
            list += [
                Step(title: "点「创建新快捷指令」", detail: "不要点下面列表里的 Fish Pocket：那里选不了具体是哪个 Bot。"),
                Step(title: "搜索「Bot」，点你要打开的 Bot", detail: "搜索结果里直接列出了你的每个 Bot。想打开 Mini App 就搜「Mini App」。"),
                Step(title: "点右上角的 ✓ 存好", detail: "列表里只写「打开 Bot」，点进去能看到选的是哪个。"),
            ]
        } else if #available(iOS 18, *) {
            list += [
                Step(title: "点「新建空白自动化」", detail: "不要点下面列表里的 Fish Pocket：那里选不了具体是哪个 Bot。"),
                Step(title: "搜索「Bot」，点你要打开的 Bot", detail: "搜索结果里直接列出了你的每个 Bot。想打开 Mini App 就搜「Mini App」。"),
                Step(title: "点右上角的「完成」", detail: "列表里只写「打开 Bot」，点进去能看到选的是哪个。"),
            ]
        } else {
            list += [
                Step(title: "点「新建空白自动化」", detail: "不要点下面列表里的 Fish Pocket：那里选不了具体是哪个 Bot。"),
                Step(title: "搜索「Bot」，点「打开 Bot」", detail: "想打开 Mini App 就搜「Mini App」。"),
                Step(title: "点浅蓝色的「Bot」，选一个", detail: "选好后点右上角的「完成」。列表里只写「打开 Bot」，点进去能看到选的是哪个。"),
            ]
        }
        return list
    }

    private var steps: some View {
        let list = stepList
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Text(verbatim: "\(index + 1)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Palette.onInk)
                            .frame(width: 30, height: 30)
                            .background(Palette.ink, in: Circle())
                        if index < list.count - 1 {
                            Rectangle()
                                .fill(Palette.stroke)
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                                .padding(.vertical, 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 5)
                        Text(step.detail)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if index == 0 { openButton.padding(.top, 8) }
                    }
                    .padding(.bottom, index < list.count - 1 ? 18 : 0)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.stroke) }
    }

    /// Straight into the app the steps happen in.
    private var openButton: some View {
        Button {
            Haptics.tap()
            openURL(URL(string: "shortcuts://")!) { opened in
                if !opened { app.showToast(String(localized: "没能打开，请在主屏幕上找到它")) }
            }
        } label: {
            Label("打开「快捷指令」", systemImage: "arrow.up.right")
                .labelStyle(TrailingIconLabel())
        }
        .buttonStyle(.capsule(height: 38, fill: false))
    }
}
