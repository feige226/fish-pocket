import Foundation

// The iOS 27.2 SDK declares Foundation's `Date.<=` and `Date.>=` as
// `@backDeployed(before: iOS 27.2)`: on 27.2 and later the call goes straight to the
// system's symbol. Early iOS 27.2 betas report 27.2 but do not have it yet, so the weakly
// linked symbol resolves to null and the app crashes on the first comparison.
// These same-signature operators shadow Foundation's for every concrete call in this
// module, which then never references the system symbol. Generic code (`max()`, ranges)
// goes through `Comparable` and is not affected.
extension Date {
    static func <= (lhs: Date, rhs: Date) -> Bool { !(lhs > rhs) }
    static func >= (lhs: Date, rhs: Date) -> Bool { !(lhs < rhs) }
}
