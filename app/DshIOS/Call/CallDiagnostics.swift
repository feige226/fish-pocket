import Foundation

/// What a call did, step by step, for looking into it afterwards on a real phone: debug builds
/// only, in `Documents/call-diagnostics.log` (the last 200 KB), read off the phone with
/// `devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id>`
/// without starting the app. Release builds write nothing.
enum CallDiagnostics {
    #if DEBUG
    private static let queue = DispatchQueue(label: "call.diagnostics")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds, .withColonSeparatorInTime]
        return formatter
    }()
    private static let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("call-diagnostics.log")
    #endif

    static func note(_ line: @autoclosure () -> String) {
        #if DEBUG
        let text = "\(formatter.string(from: Date())) \(line())\n"
        print("[call] \(text)", terminator: "")
        queue.async {
            guard let file else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) ?? 0 > 200_000 {
                    // Keep the newer half.
                    let data = (try? Data(contentsOf: file)) ?? Data()
                    try? (data.suffix(100_000) + Data(text.utf8)).write(to: file)
                    return
                }
                handle.write(Data(text.utf8))
            } else {
                try? Data(text.utf8).write(to: file)
            }
        }
        #endif
    }
}
