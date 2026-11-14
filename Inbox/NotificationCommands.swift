import SwiftUI

// What the Notification menu acts on: the row selected in the inbox window, with the window's own
// actions, which also move the selection on.
struct SelectedNotification {
    let open: () -> Void
    let markAsRead: () -> Void
}

extension FocusedValues {
    @Entry var selectedNotification: SelectedNotification?
}

struct NotificationCommands: Commands {
    @FocusedValue(\.selectedNotification) private var selected

    var body: some Commands {
        CommandMenu("Notification") {
            // No shortcut: Return opens the selected row in the list, and Command-O is for
            // opening files.
            Button("Open") { selected?.open() }
                .disabled(selected == nil)
            // Mail's shortcut for the same command.
            Button("Mark as Read") { selected?.markAsRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(selected == nil)
        }
    }
}
