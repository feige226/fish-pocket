import SwiftUI

/// A turn that ran out of balance. It is said here in the conversation, never as a popup: someone
/// on their own key did not come to buy anything. Where Fish Pocket credits can be bought (the App
/// Store build, `FishPocketAccount.offeredOnQuota`), the card offers them; a route with a top-up
/// page of its own (the DeepSeek account) links that. With neither, it stays the line it was.
struct QuotaNotice: View {
    let id: String
    let text: String
    let model: SessionModel
    @Environment(AppModel.self) private var app
    /// The route the turn ran on, kept from first sight: switching to Fish Pocket here must not
    /// turn this card into Fish Pocket's own before the message goes out again.
    @State private var route: String?
    @State private var switching = false

    /// A later turn has moved on: this one is only a record, and only the last can be sent again.
    private var isLast: Bool { model.items.last?.id == id && !model.running }

    private var resendText: String? {
        guard isLast else { return nil }
        for item in model.items.reversed() {
            if case .user(_, let text, _, _) = item, !text.isEmpty { return text }
        }
        return nil
    }

    private var current: String? { model.modelCatalog?.selection(model)?.provider }
    private var offer: Bool { app.fishPocket.offeredOnQuota }

    var body: some View {
        content
            .task(id: current) { if route == nil { route = current } }
    }

    @ViewBuilder
    private var content: some View {
        let route = route ?? current
        if !isLast {
            line
        } else if route == FishPocketAPI.provider {
            if offer {
                ConversationCard("Fish Pocket 额度已用完", "购买额度后，把刚才的消息重新发送一次。") {
                    Button("购买额度") { Haptics.tap(); app.fishPocket.quotaPrompt = true }
                        .buttonStyle(.capsule(.primary, height: 44))
                    resendButton
                }
            } else {
                line
            }
        } else if route == "deepseek-account", app.account.topUpURL != nil || offer {
            ConversationCard("DeepSeek 账号余额不足", offer
                ? "到 DeepSeek 充值后重新发送，或者改用 Fish Pocket 额度继续。"
                : "到 DeepSeek 充值后，把刚才的消息重新发送一次。") {
                if let url = app.account.topUpURL {
                    Button("去 DeepSeek 充值") {
                        InAppSafari.open(url) { Task { await app.account.refreshDetails() } }
                    }
                    .buttonStyle(.capsule(.primary, height: 44))
                }
                resendButton
            } below: {
                if offer { fishPocketButton(primary: false) }
            }
        } else if route != "deepseek-account", offer {
            ConversationCard("API 余额不足", "服务商提示额度已用完。到服务商那里充值后重新发送，或者改用 Fish Pocket 额度继续。") {
                fishPocketButton(primary: true)
                resendButton
            }
        } else {
            line
        }
    }

    private var line: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(Palette.removed)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var resendButton: some View {
        if let resendText {
            Button("重新发送") {
                Haptics.tap()
                Task { await model.send(text: resendText) }
            }
            .buttonStyle(.capsule(.outline, height: 44))
        }
    }

    /// With credits in hand it moves this conversation to Fish Pocket and sends again; before that it
    /// opens Fish Pocket, to sign in or to buy, and leaves the model as it is.
    @ViewBuilder
    private func fishPocketButton(primary: Bool) -> some View {
        let style: CapsuleButtonStyle = .capsule(primary ? .primary : .outline, height: 44)
        if app.fishPocket.signedIn, (app.fishPocket.balance ?? 0) > 0, resendText != nil {
            Button("改用 Fish Pocket 发送") { Task { await switchAndResend() } }
                .buttonStyle(style)
                .disabled(switching)
        } else {
            Button("用 Fish Pocket 继续") {
                Haptics.tap()
                if app.fishPocket.signedIn { app.fishPocket.quotaPrompt = true } else { app.requestCredentials(.fishPocket) }
            }
            .buttonStyle(style)
        }
    }

    private func switchAndResend() async {
        guard let text = resendText, let catalog = model.modelCatalog else { return }
        Haptics.tap()
        switching = true
        defer { switching = false }
        func offered() -> ModelChoice? { catalog.catalog.first { $0.id == FishPocketAPI.provider }?.models.first }
        // Signing in just now offers its models only once the catalog is read again.
        if offered() == nil { await catalog.loadCatalog(model) }
        guard let choice = offered() else {
            model.toast(String(localized: "没能切换到 Fish Pocket，请稍后再试。"))
            return
        }
        do {
            try await model.applyModel(provider: choice.provider, model: choice.model, effort: nil)
        } catch {
            model.toast(String(localized: "没能切换到 Fish Pocket，请稍后再试。"))
            return
        }
        await model.send(text: text)
    }
}
