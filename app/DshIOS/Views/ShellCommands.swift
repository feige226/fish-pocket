import SwiftUI

/// What the window in front can do. Its menu bar and keyboard shortcuts (iPad, or
/// any hardware keyboard) reach it through the focused scene.
struct WindowCommands: Equatable {
    /// The window's latest way to do each, in a box that stays the same (see `WorkbenchCommands.Box`).
    final class Box {
        var newConversation: () -> Void = {}
        var newWindow: () -> Void = {}
        var search: () -> Void = {}
        var toggleSidebar: () -> Void = {}
        var openSettings: () -> Void = {}
    }

    private let box: Box
    /// False where the system has one window.
    private let opensWindows: Bool

    /// The window's latest actions, put in the box it keeps. `newWindow` is nil where the system has one window.
    init(_ box: Box, newConversation: @escaping () -> Void, newWindow: (() -> Void)?, search: @escaping () -> Void,
         toggleSidebar: @escaping () -> Void, openSettings: @escaping () -> Void) {
        box.newConversation = newConversation
        box.newWindow = newWindow ?? {}
        box.search = search
        box.toggleSidebar = toggleSidebar
        box.openSettings = openSettings
        self.box = box
        opensWindows = newWindow != nil
    }

    func newConversation() { box.newConversation() }
    /// Nil where the system has one window.
    var newWindow: (() -> Void)? { opensWindows ? { [box] in box.newWindow() } : nil }
    func search() { box.search() }
    func toggleSidebar() { box.toggleSidebar() }
    func openSettings() { box.openSettings() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.box === rhs.box && lhs.opensWindows == rhs.opensWindows }
}

/// The conversation in that window. A blank one has no workbench.
struct WorkbenchCommands: Equatable {
    /// The conversation's latest way to do it. The closures are made again on every pass of its
    /// body; held as they are, the scene's focused value changed each time, and before iOS 26
    /// that makes a sheet up from the list beside the conversation over again: its fields
    /// emptied, the keyboard gone (the keyboard coming up is itself such a pass, so 新建 Bot
    /// could not be typed into on an iPad with a chat open). In a box that stays the same, the
    /// value changes only with `available`.
    final class Box {
        var toggle: () -> Void = {}
        var open: (WorkbenchTab) -> Void = { _ in }
    }

    private let box: Box
    let available: Bool

    /// The conversation's latest actions, put in the box it keeps.
    init(_ box: Box, available: Bool, toggle: @escaping () -> Void, open: @escaping (WorkbenchTab) -> Void) {
        box.toggle = toggle
        box.open = open
        self.box = box
        self.available = available
    }

    func toggle() { box.toggle() }
    func open(_ tab: WorkbenchTab) { box.open(tab) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.box === rhs.box && lhs.available == rhs.available }
}

extension FocusedValues {
    @Entry var windowCommands: WindowCommands?
    @Entry var workbenchCommands: WorkbenchCommands?
}

/// The keys follow macOS habits (⌘N, ⌘,) and the desktop client's where it has one.
struct ShellCommands: Commands {
    @FocusedValue(\.windowCommands) private var window
    @FocusedValue(\.workbenchCommands) private var conversation

    private var workbench: WorkbenchCommands? { conversation?.available == true ? conversation : nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新对话") { window?.newConversation() }
                .keyboardShortcut("n")
                .disabled(window == nil)
            if let newWindow = window?.newWindow {
                Button("新窗口", action: newWindow)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { window?.openSettings() }
                .keyboardShortcut(",")
                .disabled(window == nil)
        }
        CommandMenu("会话") {
            Button("搜索会话") { window?.search() }
                .keyboardShortcut("k")
                .disabled(window == nil)
            Button("显示或隐藏侧边栏") { window?.toggleSidebar() }
                .keyboardShortcut("b")
                .disabled(window == nil)
        }
        CommandMenu("工作台") {
            Button("显示或隐藏工作台") { workbench?.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(workbench == nil)
            Divider()
            tab(.terminal).keyboardShortcut("`", modifiers: .control)
            tab(.files).keyboardShortcut("p")
            tab(.browser).keyboardShortcut("t")
            tab(.changes).keyboardShortcut("d", modifiers: [.command, .shift])
            tab(.context)
        }
    }

    private func tab(_ tab: WorkbenchTab) -> some View {
        Button(tab.title) { workbench?.open(tab) }.disabled(workbench == nil)
    }
}
