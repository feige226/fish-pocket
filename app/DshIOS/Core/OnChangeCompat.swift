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
