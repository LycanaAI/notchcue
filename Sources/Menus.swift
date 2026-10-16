// The menu bar icon's menu, and a hidden main menu so standard shortcuts
// (⌘Q, ⌘W, copy and paste in Settings) work.

import AppKit

extension Prompter {
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.aligncenter", accessibilityDescription: "NotchCue")
            button.image?.isTemplate = true
            button.toolTip = "NotchCue"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens, so titles and ticks match what's happening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menu.removeAllItems()

        menu.addItem(item("Open Script…", "o", .command) { [weak self] in self?.openScriptPanel() })
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        recentMenu.autoenablesItems = false
        let paths = RecentFiles.paths
        for path in paths {
            let entry = item((path as NSString).lastPathComponent) { [weak self] in self?.openFile(URL(fileURLWithPath: path)) }
            entry.toolTip = path
            recentMenu.addItem(entry)
        }
        if paths.isEmpty {
            let none = NSMenuItem(title: "No Recent Scripts", action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentMenu.addItem(none)
        } else {
            recentMenu.addItem(.separator())
            recentMenu.addItem(item("Clear Menu") { RecentFiles.clear() })
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(item("Paste Script", "v", .command) { [weak self] in self?.pasteScript() })
        menu.addItem(.separator())

        let pause = item(paused || countingDown ? "Resume" : "Pause", " ") { [weak self] in self?.togglePause() }
        pause.isEnabled = hasScript
        menu.addItem(pause)
        let voice = item("Follow Voice") { [weak self] in self?.setMode(voice: true) }
        voice.state = options.followVoice ? .on : .off
        voice.isEnabled = hasScript
        let steady = item("Steady Scroll") { [weak self] in self?.setMode(voice: false) }
        steady.state = options.followVoice ? .off : .on
        steady.isEnabled = hasScript
        menu.addItem(voice)
        menu.addItem(steady)
        let top = item("Back to Top", "r") { [weak self] in self?.backToTop() }
        top.isEnabled = hasScript
        menu.addItem(top)
        menu.addItem(.separator())

        let size = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        size.submenu = submenu([
            info("\(Int(options.fontSize)) pt"),
            item("Bigger", "+") { [weak self] in self?.changeFontSize(by: 4) },
            item("Smaller", "-") { [weak self] in self?.changeFontSize(by: -4) },
        ])
        menu.addItem(size)
        let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speed.submenu = submenu([
            info("\(Int(options.wpm)) words a minute (steady scroll)"),
            item("Faster", "↑") { [weak self] in self?.changeSpeed(by: 10) },
            item("Slower", "↓") { [weak self] in self?.changeSpeed(by: -10) },
        ])
        menu.addItem(speed)
        menu.addItem(.separator())

        menu.addItem(item(window.isVisible ? "Hide Panel" : "Show Panel") { [weak self] in self?.togglePanel() })
        menu.addItem(item(minimised ? "Expand Panel" : "Minimise", "m") { [weak self] in
            guard let self else { return }
            self.showPanel()
            self.toggleMinimise()
        })
        menu.addItem(.separator())
        menu.addItem(item("Settings…", ",", .command) { [weak self] in self?.showSettings() })
        menu.addItem(item("Help", "?") { [weak self] in self?.showHelp() })
        menu.addItem(item("Full Guide on GitHub") { NSWorkspace.shared.open(guideURL) })
        menu.addItem(.separator())
        menu.addItem(item("Quit NotchCue", "q", .command) { NSApp.terminate(nil) })
    }

    /// A menu item that runs a closure. Key equivalents here are hints: the panel handles the keys.
    func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(ClosureMenuItem.run), keyEquivalent: "")
        let target = ClosureMenuItem(action)
        menuItem.target = target
        menuItem.representedObject = target   // keeps the target alive
        if !key.isEmpty {
            switch key {
            case "↑": menuItem.keyEquivalent = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case "↓": menuItem.keyEquivalent = String(UnicodeScalar(NSDownArrowFunctionKey)!)
            default: menuItem.keyEquivalent = key
            }
            menuItem.keyEquivalentModifierMask = modifiers
        }
        return menuItem
    }

    func info(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    func submenu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    /// Not shown (NotchCue has no Dock icon), but it makes the usual shortcuts work.
    func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", ",", .command) { [weak self] in self?.showSettings() })
        appMenu.addItem(item("Open Script…", "o", .command) { [weak self] in self?.openScriptPanel() })
        appMenu.addItem(NSMenuItem(title: "Quit NotchCue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}

final class ClosureMenuItem: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
