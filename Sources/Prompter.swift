// The panel that hangs from the notch, and the menu bar icon that controls it.
//
// By default it listens to you (Apple's built-in, on-device speech recognition) and
// scrolls to wherever you are in the script, so it keeps your pace. It can also
// scroll at a steady words-per-minute pace instead.
//
// MIT licence. https://github.com/LycanaAI/notchcue

import AppKit
import QuartzCore

let guideURL = URL(string: "https://github.com/LycanaAI/notchcue#readme")!

final class Prompter: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var options: Options
    var text = ""
    var hasScript: Bool { !text.isEmpty }
    let launchText: String?
    let launchPath: String?
    var pendingURL: URL?
    var launched = false

    var window: PrompterWindow!
    var content: DropView!
    var mainView: PanelView!
    var scrollView: NSScrollView!
    var textView: NSTextView!
    var guide: GuideView!
    var hud: NSTextField!
    var countdownLabel: NSTextField!
    var controls: ControlsBar!
    var welcome: WelcomeView!
    var help: HelpView!
    var pill: PillView!
    var statusItem: NSStatusItem!
    var settingsController: SettingsWindowController?

    var frameTimer: Timer?
    var countdownTimer: Timer?
    var hudHide: DispatchWorkItem?
    var controlsHide: DispatchWorkItem?

    var lastTick: CFTimeInterval = 0
    var lastPillUpdate: CFTimeInterval = 0
    var paused = true
    var countingDown = false
    var position: CGFloat = 0
    var lastSetPosition: CGFloat = 0
    var startOffset: CGFloat = 0
    var endOffset: CGFloat = 0
    var pointsPerSecond: CGFloat = 0

    var tokens: [Token] = []
    var scriptWords: [String] = []
    var cursor = 0                       // index of the next word to be said
    var follower: VoiceFollower?
    var paceSamples: [(time: CFTimeInterval, cursor: Int)] = []

    var screen: NSScreen!
    var topInset: CGFloat = 0            // height of the notch / menu bar strip at the top
    var notchWidth: CGFloat = 0
    let readingLineFraction: CGFloat = 0.28
    let sideMargin: CGFloat = 44

    var minimised = false
    var panelFrame = NSRect.zero         // the full panel's frame, kept while minimised
    var resumeAfterMinimise = false
    var resumeAfterHelp = false
    var pinControls = false

    init(options: Options, text: String?) {
        self.options = options
        self.launchText = text
        self.launchPath = options.file == "/dev/stdin" ? nil : options.file
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
    }

    /// Files dropped on the app icon, or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        // A file given on the command line can also arrive here; it's already loaded.
        let fresh = urls.filter { !(!launched && $0.path == launchPath) }
        guard let url = fresh.last else { return }
        if launched { showPanel(); openFile(url) } else { pendingURL = url }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildStatusItem()
        installDebugHooks()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer

        launched = true
        if let launchText {
            load(script: launchText, path: launchPath)
        } else if let pendingURL {
            openFile(pendingURL)
        } else if options.sample {
            load(script: sampleText, path: nil)
        } else {
            showWelcome()
        }

        switch options.show {
        case "help": showHelp()
        case "controls": pinControls = true; setControlsVisible(true)
        case "minimised", "minimized": minimise()
        case "settings": showSettings()
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { follower?.stop() }

    /// Opening the app again (Spotlight, Finder) brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        if minimised { expand() }
        return false
    }

    // MARK: Building the panel

    func buildPanel() {
        measureScreen()
        let size = panelSize()

        // The top strip sits behind the notch and the menu bar; it's black so it blends in.
        window = PrompterWindow(contentRect: panelFrameAtTop(), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .statusBar
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        content = DropView(frame: NSRect(origin: .zero, size: size))
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        content.onDropFile = { [weak self] url in self?.openFile(url) }
        content.onDropText = { [weak self] text in self?.load(script: text, path: nil) }
        content.onDragHighlight = { [weak self] on in
            self?.content.layer?.borderWidth = on ? 2 : 0
            self?.content.layer?.borderColor = NSColor.systemBlue.cgColor
        }
        window.contentView = content

        mainView = PanelView(frame: content.bounds)
        mainView.autoresizingMask = [.width, .height]
        mainView.onMouse = { [weak self] inside in self?.mouseMoved(inside: inside) }
        content.addSubview(mainView)

        let textArea = NSRect(x: 0, y: 0, width: mainView.bounds.width, height: mainView.bounds.height - topInset)
        scrollView = NSScrollView(frame: textArea)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.unregisterDraggedTypes()    // let drops reach the panel
        scrollView.documentView = textView
        mainView.addSubview(scrollView)

        guide = GuideView(frame: textArea)
        guide.autoresizingMask = [.width, .height]
        mainView.addSubview(guide)

        welcome = WelcomeView(onOpen: { [weak self] in self?.openScriptPanel() },
                              onSample: { [weak self] in self?.load(script: sampleText, path: nil) },
                              onHelp: { [weak self] in self?.showHelp() })
        welcome.frame = textArea.insetBy(dx: 12, dy: 10)
        welcome.autoresizingMask = [.width, .height]
        welcome.isHidden = true
        mainView.addSubview(welcome)

        hud = makeLabel(size: 13, weight: .medium, color: NSColor(white: 0.6, alpha: 1))
        // A black backing so the status line stays readable over the script.
        hud.drawsBackground = true
        hud.backgroundColor = .black
        countdownLabel = makeLabel(size: 90, weight: .bold, color: .white)
        mainView.addSubview(hud)
        mainView.addSubview(countdownLabel)

        controls = ControlsBar(actions: .init(
            pause: { [weak self] in self?.togglePause() },
            mode: { [weak self] in self?.toggleMode() },
            smaller: { [weak self] in self?.changeFontSize(by: -4) },
            bigger: { [weak self] in self?.changeFontSize(by: 4) },
            minimise: { [weak self] in self?.minimise() },
            settings: { [weak self] in self?.showSettings() },
            help: { [weak self] in self?.toggleHelp() },
            close: { NSApp.terminate(nil) }))
        controls.alphaValue = 0
        controls.isHidden = true
        mainView.addSubview(controls)

        help = HelpView(onGuide: { NSWorkspace.shared.open(guideURL) }, onClose: { [weak self] in self?.hideHelp() })
        help.frame = textArea
        help.autoresizingMask = [.width, .height]
        help.isHidden = true
        mainView.addSubview(help)

        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: mainView.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -10),
            countdownLabel.centerXAnchor.constraint(equalTo: mainView.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            controls.centerXAnchor.constraint(equalTo: mainView.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: mainView.bottomAnchor, constant: -8),
        ])

        pill = PillView(frame: .zero)
        pill.notchWidth = notchWidth
        pill.topInset = topInset
        pill.autoresizingMask = [.width, .height]
        pill.isHidden = true
        pill.onClick = { [weak self] in self?.expand() }
        content.addSubview(pill)

        updateControls()
    }

    /// Picks the screen to use and measures its notch and menu bar.
    func measureScreen() {
        // Prefer the built-in screen with the notch (and its camera).
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        topInset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : frame.maxY - screen.visibleFrame.maxY
        notchWidth = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        }
    }

    /// Where the full panel goes: centred, its top edge at the very top of the screen.
    func panelFrameAtTop() -> NSRect {
        let size = panelSize()
        let frame = screen.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Displays were added, removed or rearranged: measure again and go back to the top.
    @objc func screensChanged() {
        measureScreen()
        pill.topInset = topInset
        pill.notchWidth = notchWidth
        panelFrame = panelFrameAtTop()
        if minimised {
            window.setFrame(pillFrame(), display: true)
        } else {
            window.setFrame(panelFrame, display: true)
            relayoutAfterResize()
        }
    }

    /// The text area sits below the notch strip; keep it that way after a resize.
    func relayoutAfterResize() {
        let textArea = NSRect(x: 0, y: 0, width: mainView.bounds.width, height: mainView.bounds.height - topInset)
        for view in [scrollView!, guide!, help!] as [NSView] { view.frame = textArea }
        welcome.frame = textArea.insetBy(dx: 12, dy: 10)
        if hasScript { relayout(keepProgress: true) }
    }

    func panelSize() -> NSSize {
        let frame = screen.frame
        let width = min(max(options.width, notchWidth + 120), frame.width)
        let height = min(options.height, frame.height / 2) + topInset
        return NSSize(width: width, height: height)
    }

    func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: Loading scripts

    func showWelcome(message: String? = nil) {
        welcome.isHidden = false
        welcome.showMessage(message)
        guide.isHidden = true
        hud.isHidden = true
        countdownLabel.isHidden = true
        updateControls()
    }

    func load(script: String, path: String?) {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return showError("There's no text to show")
        }
        follower?.stop()
        follower = nil
        countdownTimer?.invalidate()
        text = script
        cursor = 0
        paceSamples = []
        if let path { RecentFiles.add(path) }
        welcome.isHidden = true
        guide.isHidden = false
        if !help.isHidden { help.isHidden = true; resumeAfterHelp = false }
        reloadText(keepProgress: false)
        log("loaded \(path ?? "text"), \(tokens.count) words")
        if minimised {
            // Keep following quietly in the pill; a steady scroll waits for the panel.
            if options.followVoice { startFollowing() } else { paused = true; resumeAfterMinimise = true }
        } else if options.followVoice {
            startFollowing()
        } else {
            startCountdown()
        }
        updateControls()
    }

    func openFile(_ url: URL) {
        do {
            let script = try scriptText(fromFileAt: url)
            load(script: script, path: url.path)
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Shows a problem in the panel: on the welcome screen, or in the status line.
    func showError(_ message: String) {
        log("error: \(message)")
        showPanel()
        if minimised { expand() }
        if hasScript {
            showHUD(message, color: .systemOrange, hideAfter: 6)
        } else {
            showWelcome(message: message)
        }
    }

    func openScriptPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open a Script"
        panel.prompt = "Open"
        panel.allowedContentTypes = ScriptFormat.contentTypes
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        // Let the dialog sit above the panel while it's open.
        let level = window.level
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        window.level = level
        if response == .OK, let url = panel.url {
            showPanel()
            openFile(url)
        }
    }

    func pasteScript() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            return openFile(url)
        }
        guard let pasted = pasteboard.string(forType: .string), !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return showError("There's no text on the clipboard to paste")
        }
        load(script: pasted, path: nil)
        showHUD("Pasted script")
    }

    // MARK: Layout

    var progress: CGFloat {
        endOffset > startOffset ? (position - startOffset) / (endOffset - startOffset) : 0
    }

    func reloadText(keepProgress: Bool) {
        let (styled, tokens) = styledText(text, fontSize: options.fontSize)
        let saved = progress
        textView.textStorage?.setAttributedString(styled)
        self.tokens = tokens
        scriptWords = tokens.map(\.word)
        relayout(keepProgress: false)
        if keepProgress { setPosition(startOffset + saved * (endOffset - startOffset)) }
        markSpoken()
    }

    /// Pads the text by one window height above and below, so the first line can start
    /// on the reading line and the last line can scroll up to it.
    func relayout(keepProgress: Bool) {
        let saved = progress
        let viewHeight = scrollView.contentView.bounds.height
        textView.textContainerInset = NSSize(width: sideMargin, height: viewHeight)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        textView.sizeToFit()

        let textHeight = layout.usedRect(for: container).height
        let readingY = viewHeight * readingLineFraction
        let lineHeight = options.fontSize * 1.2
        guide.readingY = readingY + lineHeight / 2
        startOffset = viewHeight - readingY
        endOffset = viewHeight + textHeight - readingY - lineHeight

        let readingSeconds = Double(max(tokens.count, 1)) / options.wpm * 60
        pointsPerSecond = (endOffset - startOffset) / CGFloat(max(readingSeconds, 1))

        setPosition(keepProgress ? startOffset + saved * (endOffset - startOffset) : startOffset)
    }

    // MARK: Following your voice

    func startFollowing() {
        countdownTimer?.invalidate()
        countingDown = false
        countdownLabel.isHidden = true
        scrollView.alphaValue = 1
        options.followVoice = true
        paused = false
        guard hasScript else { return updateControls() }
        if follower == nil {
            let hints = Array(Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }))
            let follower = VoiceFollower(locale: options.locale, hints: Array(hints.prefix(100)))
            follower.onWords = { [weak self] words in self?.heard(words) }
            follower.onStatus = { [weak self] message in
                self?.showHUD(message, sticky: true)
                self?.updateControls()
            }
            self.follower = follower
        }
        if follower?.running != true { follower?.start() }
        showHUD("Following your voice", sticky: true)
        updateControls()
    }

    func heard(_ words: [String]) {
        guard options.followVoice, !paused, let next = matchPosition(heard: words, script: scriptWords, current: cursor),
              next != cursor else { return }
        log("cursor \(cursor) -> \(next)")
        cursor = next
        markSpoken()
        recordPace()
    }

    /// Greys out the words already said.
    func markSpoken() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let done = cursor > 0 && cursor <= tokens.count ? NSMaxRange(tokens[cursor - 1].range) : 0
        storage.beginEditing()
        for token in tokens {
            let said = NSMaxRange(token.range) <= done
            storage.addAttribute(.foregroundColor, value: said ? NSColor(white: 1, alpha: 0.32) : NSColor.white, range: token.range)
        }
        storage.endEditing()
        if minimised { updatePill() }
    }

    /// Where to scroll so the line with the next word to say sits on the reading arrow.
    func voiceTarget() -> CGFloat {
        guard let layout = textView.layoutManager, let container = textView.textContainer, !tokens.isEmpty else { return startOffset }
        let token = tokens[min(cursor, tokens.count - 1)]
        let glyphs = layout.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
        let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return startOffset + line.minY
    }

    func recordPace() {
        let now = CACurrentMediaTime()
        paceSamples.append((now, cursor))
        paceSamples.removeAll { now - $0.time > 8 }
        guard let first = paceSamples.first, now - first.time > 2 else { return }
        let wpm = Double(cursor - first.cursor) / (now - first.time) * 60
        if wpm > 0 { showHUD("● \(Int(wpm.rounded())) wpm", sticky: true) }
    }

    // MARK: Scrolling

    func setPosition(_ y: CGFloat) {
        position = min(max(y, 0), endOffset)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: position))
        scrollView.reflectScrolledClipView(clip)
        lastSetPosition = clip.bounds.origin.y
    }

    func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(now - lastTick, 0.1)
        lastTick = now
        guard hasScript else { return }

        if minimised && now - lastPillUpdate > 0.5 { updatePill() }

        // If the user scrolled by hand (trackpad), continue from where they left it.
        let actual = scrollView.contentView.bounds.origin.y
        if abs(actual - lastSetPosition) > 2 { position = actual }

        guard !paused else { return }
        if options.followVoice {
            // Glide toward the line being read rather than jumping.
            let target = voiceTarget()
            if abs(target - position) > 0.5 { setPosition(position + (target - position) * min(1, CGFloat(elapsed) * 7)) }
            return
        }
        let next = position + pointsPerSecond * CGFloat(elapsed)
        if next >= endOffset {
            setPosition(endOffset)
            paused = true
            showHUD("End · R to restart", sticky: true)
            updateControls()
        } else {
            setPosition(next)
        }
    }

    func startCountdown() {
        countdownTimer?.invalidate()
        paused = true
        guard hasScript else { return }
        guard options.countdown > 0 else { return resume() }
        countingDown = true
        var remaining = options.countdown
        countdownLabel.stringValue = "\(remaining)"
        countdownLabel.isHidden = false
        scrollView.alphaValue = 0.25
        showHUD("Space to start now", sticky: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            remaining -= 1
            if remaining <= 0 { self?.resume() } else { self?.countdownLabel.stringValue = "\(remaining)" }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
        updateControls()
    }

    func resume() {
        guard hasScript else { return }
        countdownTimer?.invalidate()
        countingDown = false
        countdownLabel.isHidden = true
        scrollView.alphaValue = 1
        if !options.followVoice && position >= endOffset { setPosition(startOffset) }
        lastTick = CACurrentMediaTime()
        paused = false
        showHUD(options.followVoice ? "Following your voice" : "\(Int(options.wpm)) wpm")
        updateControls()
    }

    // MARK: Actions (keys, buttons and the menu all come here)

    func handleKey(_ event: NSEvent) -> Bool {
        // Only the panel's keys; typing in the Settings window is left alone.
        guard event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.command) {
            switch key {
            case "o": openScriptPanel()
            case "v": pasteScript()
            case ",": showSettings()
            case "q": NSApp.terminate(nil)
            case "m": toggleMinimise()
            case "w": hidePanel()
            default: return false
            }
            return true
        }

        if !help.isHidden && (event.keyCode == 53 || key == "?" || key == "/") {
            hideHelp()
            return true
        }

        switch event.keyCode {
        case 49: togglePause()                                  // space
        case 126: if options.followVoice { moveCursor(by: -1) } else { changeSpeed(by: 10) }   // up
        case 125: if options.followVoice { moveCursor(by: 1) } else { changeSpeed(by: -10) }   // down
        case 53: NSApp.terminate(nil)                           // escape
        case 36, 76: if minimised { expand() } else { return false }   // return
        default:
            switch key {
            case "q": NSApp.terminate(nil)
            case "r": backToTop()
            case "v": toggleMode()
            case "=", "+": changeFontSize(by: 4)
            case "-", "_": changeFontSize(by: -4)
            case "m": toggleMinimise()
            case "?", "/", "h": toggleHelp()
            default: return false
            }
        }
        return true
    }

    func togglePause() {
        guard hasScript else { return }
        if countingDown || paused { resume() } else { paused = true; showHUD("Paused", sticky: true) }
        updateControls()
    }

    func backToTop() {
        guard hasScript else { return }
        cursor = 0
        markSpoken()
        setPosition(startOffset)
        if options.followVoice { resume() } else { startCountdown() }
    }

    func toggleMode() {
        guard hasScript else { return }
        // If listening stopped (for example Dictation was off), V tries again.
        if options.followVoice && follower?.running == false {
            return startFollowing()
        }
        if options.followVoice {
            options.followVoice = false
            follower?.stop()
            resume()
        } else {
            startFollowing()
        }
    }

    func setMode(voice: Bool) {
        if voice != options.followVoice || (voice && follower?.running != true) { toggleMode() }
    }

    func moveCursor(by delta: Int) {
        cursor = min(max(cursor + delta, 0), tokens.count)
        markSpoken()
    }

    func changeSpeed(by delta: Double) {
        options.wpm = min(max(options.wpm + delta, 40), 400)
        if hasScript { relayout(keepProgress: true) }
        showHUD("\(Int(options.wpm)) wpm")
    }

    func changeFontSize(by delta: CGFloat) {
        options.fontSize = min(max(options.fontSize + delta, 20), 160)
        if hasScript { reloadText(keepProgress: true) }
        showHUD("Text size \(Int(options.fontSize))")
    }

    func showHUD(_ message: String, sticky: Bool = false, color: NSColor = NSColor(white: 0.6, alpha: 1), hideAfter: Double = 1.5) {
        hudHide?.cancel()
        hud.stringValue = message
        hud.textColor = color
        hud.isHidden = !hasScript
        if minimised { updatePill() }
        guard !sticky else { return }
        let hide = DispatchWorkItem { [weak self] in self?.hud.isHidden = true }
        hudHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: hide)
    }

    // MARK: Hover controls

    func mouseMoved(inside: Bool) {
        controlsHide?.cancel()
        guard !pinControls else { return }
        guard inside, help.isHidden else { return scheduleControlsHide(after: 0.4) }
        setControlsVisible(true)
        // While reading, get out of the way again once the mouse rests.
        scheduleControlsHide(after: 2.5)
    }

    func scheduleControlsHide(after delay: Double) {
        controlsHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            guard let self, !self.pinControls else { return }
            if self.controls.mouseInside { return self.scheduleControlsHide(after: 1.5) }
            self.setControlsVisible(false)
        }
        controlsHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hide)
    }

    func setControlsVisible(_ visible: Bool) {
        if visible { controls.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.15 : 0.35
            controls.animator().alphaValue = visible ? 1 : 0
            hud.animator().alphaValue = visible ? 0 : 1
        } completionHandler: { [weak self] in
            if !visible { self?.controls.isHidden = true }
        }
    }

    func updateControls() {
        controls?.update(paused: paused || countingDown || !hasScript, followVoice: options.followVoice)
        if minimised { updatePill() }
    }

    // MARK: Help

    func toggleHelp() { help.isHidden ? showHelp() : hideHelp() }

    func showHelp() {
        showPanel()
        if minimised { expand() }
        help.isHidden = false
        setControlsVisible(false)
        if hasScript && !options.followVoice && !paused { paused = true; resumeAfterHelp = true }
        updateControls()
    }

    func hideHelp() {
        help.isHidden = true
        if resumeAfterHelp { resumeAfterHelp = false; resume() }
    }

    // MARK: Minimise

    func toggleMinimise() { minimised ? expand() : minimise() }

    func minimise() {
        guard !minimised else { return }
        if !help.isHidden { hideHelp() }
        // A steady scroll stops while you can't see it; voice keeps tracking your place.
        if hasScript && !options.followVoice && (!paused || countingDown) {
            countdownTimer?.invalidate()
            countingDown = false
            countdownLabel.isHidden = true
            scrollView.alphaValue = 1
            paused = true
            resumeAfterMinimise = true
        }
        showPanel()
        panelFrame = window.frame
        minimised = true
        // Hide the hover controls now: the mouse-exit event never comes once the panel shrinks.
        controlsHide?.cancel()
        controls.mouseInside = false
        controls.alphaValue = 0
        controls.isHidden = true
        hud.alphaValue = 1
        // Take the full panel out of the window while it's small, so its fixed size and
        // constraints can't pull the window back to the wrong size.
        mainView.removeFromSuperview()
        pill.frame = content.bounds
        pill.isHidden = false
        content.cornerRadius = 13
        window.setFrame(pillFrame(), display: true, animate: true)
        pill.frame = content.bounds
        updatePill()
    }

    func expand() {
        guard minimised else { return }
        minimised = false
        pill.isHidden = true
        content.cornerRadius = 20
        window.setFrame(panelFrame, display: true, animate: true)
        if window.frame != panelFrame { window.setFrame(panelFrame, display: true) }
        mainView.frame = content.bounds
        mainView.autoresizingMask = [.width, .height]
        content.addSubview(mainView, positioned: .below, relativeTo: pill)
        content.layoutSubtreeIfNeeded()
        if hasScript { relayout(keepProgress: true); markSpoken() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if resumeAfterMinimise {
            resumeAfterMinimise = false
            if !options.followVoice { startCountdown() }
        }
        updateControls()
    }

    func pillFrame() -> NSRect {
        let frame = (window.screen ?? screen).frame
        let width = min(max(notchWidth + 200, 380), frame.width)
        let height = topInset + 28
        return NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
    }

    func updatePill() {
        lastPillUpdate = CACurrentMediaTime()
        let (color, status): (NSColor, String)
        if !hasScript {
            (color, status) = (.systemGray, "No script")
        } else if paused || countingDown {
            (color, status) = (.systemOrange, "Paused")
        } else if !options.followVoice {
            (color, status) = (.systemBlue, "Scrolling")
        } else if follower?.running == true {
            (color, status) = (.systemGreen, "Listening")
        } else {
            (color, status) = (.systemGray, "Not listening")
        }
        let fraction: CGFloat? = hasScript ? (options.followVoice ? CGFloat(cursor) / CGFloat(max(tokens.count, 1)) : progress) : nil
        pill.update(color: color, status: status, line: currentLineHint(), progress: fraction)
    }

    /// The rest of the line you're on, for the minimised pill.
    func currentLineHint() -> String {
        guard hasScript, let storage = textView.textStorage, storage.length > 0 else { return "Click to expand" }
        let string = storage.string as NSString
        var index: Int
        if options.followVoice || tokens.isEmpty {
            guard cursor < tokens.count else { return "End of script" }
            index = tokens[cursor].range.location
        } else {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return "" }
            let viewHeight = scrollView.contentView.bounds.height
            let y = position + viewHeight * readingLineFraction - textView.textContainerOrigin.y
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(y, 0)), in: container)
            index = layout.characterIndexForGlyph(at: glyph)
            if let token = tokens.last(where: { $0.range.location <= index }) { index = token.range.location }
        }
        index = min(index, string.length - 1)
        let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
        let rest = string.substring(with: NSRange(location: index, length: NSMaxRange(paragraph) - index))
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Showing and hiding

    func showPanel() {
        if !window.isVisible { window.orderFront(nil) }
    }

    func hidePanel() { window.orderOut(nil) }

    func togglePanel() {
        if window.isVisible { hidePanel() } else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Settings

    func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: Settings.load()) { [weak self] s in self?.apply(settings: s) }
        }
        guard let settingsWindow = settingsController?.window else { return }
        // Place it below the panel so they don't overlap.
        let visible = screen.visibleFrame
        let size = settingsWindow.frame.size
        let top = min(window.frame.minY - 24, visible.maxY)
        settingsWindow.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: max(top - size.height, visible.minY)))
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    /// Settings apply to the running panel straight away.
    func apply(settings s: Settings) {
        let fontSize = CGFloat(s.fontSize), width = CGFloat(s.width), height = CGFloat(s.height)
        if fontSize != options.fontSize {
            options.fontSize = fontSize
            if hasScript { reloadText(keepProgress: true) }
        }
        if width != options.width || height != options.height {
            options.width = width
            options.height = height
            resizePanel()
        }
        if s.wpm != options.wpm {
            options.wpm = s.wpm
            if hasScript { relayout(keepProgress: true) }
        }
        options.countdown = s.countdown
        let locale = s.locale.isEmpty ? nil : s.locale
        if locale != options.locale {
            options.locale = locale
            if options.followVoice && hasScript {
                follower?.stop()
                follower = nil
                startFollowing()
            }
        }
    }

    func resizePanel() {
        panelFrame = panelFrameAtTop()
        guard !minimised else { return }
        window.setFrame(panelFrame, display: true)
        relayoutAfterResize()
    }
}
