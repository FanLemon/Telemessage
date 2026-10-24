//
//  AppDelegate.swift
//  Telemessage
//
//  Created by Farsonic on 10/24/26.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        TDLibInfo.setLogVerbosity(1)
        MainMenu.configure(NSApp.mainMenu)
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.session != nil else { return .terminateNow }
        // TDLib must close before exit to keep its database consistent; give it a few seconds.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await coordinator.prepareForTermination()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: reply)
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { coordinator.reopen() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        coordinator.account?.showSettings()
    }

    @objc func logOut(_ sender: Any?) {
        coordinator.confirmLogOut()
    }

    @objc func chooseChats(_ sender: Any?) {
        coordinator.account?.showChatPicker()
    }

    @objc func showMainWindow(_ sender: Any?) {
        coordinator.reopen()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showSettings(_:)), #selector(logOut(_:)), #selector(chooseChats(_:)):
            coordinator.isSignedIn
        default:
            true
        }
    }

}
