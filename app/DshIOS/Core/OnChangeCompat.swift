import SwiftUI

/// Backports the two-value and initial variants of SwiftUI's iOS 17 onChange API.
extension View {
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(OnChangeCompatModifier(value: value, initial: initial, action: action))
    }

    func onChangeCompat<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        modifier(OnChangeCompatNoArgumentsModifier(value: value, initial: initial, action: action))
    }
}

private struct OnChangeCompatModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void

    @State private var previous: Value?
    @State private var didAppear = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !didAppear else { return }
                didAppear = true
                previous = value
                if initial { action(value, value) }
            }
            .onChange(of: value) { newValue in
                let oldValue = previous ?? newValue
                previous = newValue
                action(oldValue, newValue)
            }
    }
}

private struct OnChangeCompatNoArgumentsModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: () -> Void

    @State private var didAppear = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !didAppear else { return }
                didAppear = true
                if initial { action() }
            }
            .onChange(of: value) { _ in action() }
    }
}


extension View {
    /// Uses the system scroll anchor where available; leaves iOS 16 at its native layout.
    @ViewBuilder
    func defaultScrollAnchorCompat(_ anchor: UnitPoint) -> some View {
        if #available(iOS 17.0, *) {
            self.defaultScrollAnchor(anchor)
        } else {
            self
        }
    }
}


/// iOS 16 fallback for SwiftUI's iOS 17 ContentUnavailableView.
struct ContentUnavailableView: View {
    private let title: Text?
    private let systemImage: String?
    private let label: AnyView?
    private let detail: AnyView?
    private let actions: AnyView?

    init(_ titleKey: LocalizedStringKey, systemImage: String) {
        self.title = Text(titleKey)
        self.systemImage = systemImage
        self.label = nil
        self.detail = nil
        self.actions = nil
    }

    init(_ titleKey: LocalizedStringKey, systemImage: String, description: Text) {
        self.title = Text(titleKey)
        self.systemImage = systemImage
        self.label = nil
        self.detail = AnyView(description)
        self.actions = nil
    }

    init<LabelContent: View, DescriptionContent: View, ActionsContent: View>(
        @ViewBuilder _ label: () -> LabelContent,
        @ViewBuilder description: () -> DescriptionContent,
        @ViewBuilder actions: () -> ActionsContent
    ) {
        self.title = nil
        self.systemImage = nil
        self.label = AnyView(label())
        self.detail = AnyView(description())
        self.actions = AnyView(actions())
    }

    init<LabelContent: View, ActionsContent: View>(
        @ViewBuilder _ label: () -> LabelContent,
        @ViewBuilder actions: () -> ActionsContent
    ) {
        self.title = nil
        self.systemImage = nil
        self.label = AnyView(label())
        self.detail = nil
        self.actions = AnyView(actions())
    }
    init<LabelContent: View, DescriptionContent: View>(
        @ViewBuilder _ label: () -> LabelContent,
        @ViewBuilder description: () -> DescriptionContent
    ) {
        self.title = nil
        self.systemImage = nil
        self.label = AnyView(label())
        self.detail = AnyView(description())
        self.actions = nil
    }


    static func search(text: String) -> ContentUnavailableView {
        ContentUnavailableView(
            "没有搜索结果",
            systemImage: "magnifyingglass",
            description: Text(text.isEmpty ? "没有可显示的内容。" : "没有找到与“\\(text)”匹配的内容。")
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            if let label {
                label
            } else {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                if let title {
                    title.font(.headline).foregroundStyle(.primary)
                }
            }
            if let detail {
                detail.foregroundStyle(.secondary)
            }
            if let actions {
                actions
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
