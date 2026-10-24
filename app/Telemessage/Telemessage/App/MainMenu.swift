import Cocoa

/// Adapts the storyboard's template menu to Telemessage. Actions travel the responder chain and
/// end at `AppDelegate` unless a window handles them first.
enum MainMenu {
    static func configure(_ menu: NSMenu?) {
        guard let menu else { return }
        configureAppMenu(menu.items.first?.submenu)
        configureFileMenu(menu.items.first { $0.title == "File" }?.submenu)
        configureWindowMenu(menu.items.first { $0.title == "Window" }?.submenu)
    }

    private static func configureAppMenu(_ menu: NSMenu?) {
        guard let menu else { return }
        if let settings = menu.items.first(where: { $0.keyEquivalent == "," }) {
            settings.title = "Settings…"
            settings.action = #selector(AppDelegate.showSettings(_:))
            let index = menu.index(of: settings)
            menu.insertItem(item("Log Out…", #selector(AppDelegate.logOut(_:))), at: index + 1)
        }
    }

    private static func configureFileMenu(_ menu: NSMenu?) {
        guard let menu else { return }
        menu.removeAllItems()
        menu.addItem(item("Choose Chats…", #selector(AppDelegate.chooseChats(_:)), key: "n", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
    }

    private static func configureWindowMenu(_ menu: NSMenu?) {
        guard let menu else { return }
        menu.insertItem(item("Telemessage", #selector(AppDelegate.showMainWindow(_:)), key: "0"), at: 0)
        menu.insertItem(item("Keep on Top", #selector(ChatWindowController.toggleKeepOnTop(_:)), key: "t", modifiers: [.command, .option]), at: 1)
        menu.insertItem(.separator(), at: 2)
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
