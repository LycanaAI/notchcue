// Test hooks for driving the panel from a script, only active with --debug.
//
// Post the distributed notification "ai.lycana.notchcue.debug" with the command as the
// object: key:<chars>, button:minimise, menu:<title>, click-pill, dump. Each command runs
// the same code a real key press, click or menu choice would, then `dump` writes the
// panel's state to ~/Library/Logs/notchcue.log.

import AppKit

extension Prompter {
    func installDebugHooks() {
        guard debugLogging else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("ai.lycana.notchcue.debug"), object: nil, queue: .main) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            log("debug command: \(command)")
            self.runDebugCommand(command)
        }
    }

    func runDebugCommand(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "key":
            let codes: [String: UInt16] = ["m": 46, " ": 49, "v": 9, "?": 44, "r": 15]
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: argument,
                                            charactersIgnoringModifiers: argument, isARepeat: false, keyCode: codes[argument] ?? 0) {
                log("key handled: \(handleKey(event))")
            }
        case "button":
            // Clicks the hover control with this tooltip prefix.
            let buttons = controls.descendants.compactMap { $0 as? NSButton }
            if let button = buttons.first(where: { ($0.toolTip ?? "").lowercased().hasPrefix(argument.lowercased()) }) {
                button.performClick(nil)
            } else {
                log("no button \(argument)")
            }
        case "menu":
            guard let menu = statusItem.menu else { return }
            menuNeedsUpdate(menu)
            if let item = menu.items.first(where: { $0.title == argument }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                log("no menu item \(argument)")
            }
        case "size":
            // size:WIDTHxHEIGHT, as if changed in Settings (not saved).
            let numbers = argument.split(separator: "x").compactMap { Double($0) }
            if numbers.count == 2 {
                var settings = Settings.load()
                settings.width = numbers[0]
                settings.height = numbers[1]
                apply(settings: settings)
            }
        case "screens":
            screensChanged()
        case "click-pill":
            pill.onClick?()
        case "dump":
            dumpState()
        case "fitting":
            for (name, view) in [("help", help!), ("welcome", welcome!), ("controls", controls!), ("hud", hud!), ("countdown", countdownLabel!), ("mainView", mainView!), ("content", content!)] as [(String, NSView)] {
                log("fitting \(name): \(view.fittingSize) frame \(view.frame) ambiguous=\(view.hasAmbiguousLayout)")
            }
            for v in help.descendants + welcome.descendants where v.fittingSize.height > 400 || v.intrinsicContentSize.height > 400 {
                log("tall: \(type(of: v)) \(v.intrinsicContentSize) \((v as? NSTextField)?.stringValue.prefix(30) ?? "")")
            }
        default:
            log("unknown debug command")
        }
    }

    func dumpState() {
        func r(_ rect: NSRect) -> String { "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))" }
        log("""
        state: minimised=\(minimised) window=\(r(window.frame)) visible=\(window.isVisible) key=\(window.isKeyWindow) appActive=\(NSApp.isActive) \
        content=\(r(content.bounds)) mainView=\(r(mainView.frame)) hidden=\(mainView.isHidden) mask=\(content.maskPathBounds.map(r) ?? "nil") \
        scroll=\(r(scrollView.frame)) guide=\(r(guide.frame)) readingY=\(Int(guide.readingY)) position=\(Int(position)) start=\(Int(startOffset)) end=\(Int(endOffset)) \
        clipY=\(Int(scrollView.contentView.bounds.origin.y)) cursor=\(cursor)/\(tokens.count) paused=\(paused) voice=\(options.followVoice) listening=\(follower?.running ?? false) \
        controls(alpha=\(controls.alphaValue) hidden=\(controls.isHidden)) hud(alpha=\(hud.alphaValue) hidden=\(hud.isHidden) "\(hud.stringValue)") pill(hidden=\(pill.isHidden) \(r(pill.frame)))
        """)
    }
}

extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
