// NotchCue: a macOS teleprompter that hangs down from the notch, right under the camera.
//
// By default it listens to you (Apple's built-in, on-device speech recognition) and
// scrolls to wherever you are in the script, so it keeps your pace. It can also
// scroll at a steady words-per-minute pace instead.
//
// Built into an app bundle and launched by the `notchcue` script. The bundle is needed
// so macOS can ask for microphone and speech recognition permission.
//
// MIT licence. https://github.com/LycanaAI/notchcue

import AppKit
import AVFoundation
import QuartzCore
import Speech

let sampleText = """
[Sample text]
This is NotchCue. Start reading out loud and the text follows your voice.

If you pause, it waits for you. If you go back and say a line again, it jumps back to it.

Press V to switch to a steady scroll, and Escape to close the window.
"""

let usageText = """
Usage: notchcue [FILE | -] [options]

Shows FILE (or text from --text, or stdin when FILE is "-") in a window that
hangs down from the top centre of the screen, around the notch.

By default it follows your voice: say the script out loud and it scrolls to
keep the line you're on at the reading arrow. Words you've said turn grey.
With --steady it scrolls at a fixed pace instead.

Lines wrapped in square brackets, like [Hook], are shown as small grey cues
and are not read out.

Options:
  --steady           Scroll at a steady pace instead of following your voice
  --wpm N            Pace for --steady, in words per minute (default 150)
  --locale ID        Speech recognition language (default: your system language, e.g. en-AU)
  --text TEXT        Text to show instead of a file
  --font-size N      Text size in points (default 40)
  --countdown N      Seconds to count down before a steady scroll (default 3, 0 = none)
  --width N          Window width in points (default 760)
  --height N         Window height below the notch, in points (default 280)
  --debug            Write what it hears to ~/Library/Logs/notchcue.log
  --validate         Check the options and text, then exit without opening a window
  -h, --help         Show this help

Keys while running:
  V            Switch between following your voice and a steady scroll
  Space        Pause / resume
  Up / Down    Steady scroll: faster / slower. Voice: move the place marker by a word
  + / -        Bigger / smaller text
  R            Back to the top
  Esc or Q     Close
Drag the window to move it.
"""

struct Options {
    var text: String?
    var file: String?
    var followVoice = true
    var wpm: Double = 150
    var locale: String?
    var fontSize: CGFloat = 40
    var countdown = 3
    var width: CGFloat = 760
    var height: CGFloat = 280
    var validateOnly = false
    var debug = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    func value(for name: String) -> String {
        guard !args.isEmpty else { fail("\(name) needs a value") }
        return args.removeFirst()
    }
    func number(for name: String, minimum: Double) -> Double {
        guard let n = Double(value(for: name)), n >= minimum else { fail("\(name) must be a number of at least \(Int(minimum))") }
        return n
    }

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-h", "--help":
            print(usageText)
            exit(0)
        case "--steady": options.followVoice = false
        case "--text": options.text = value(for: arg)
        case "--wpm": options.wpm = number(for: arg, minimum: 20)
        case "--locale": options.locale = value(for: arg)
        case "--font-size": options.fontSize = CGFloat(number(for: arg, minimum: 12))
        case "--countdown": options.countdown = Int(number(for: arg, minimum: 0))
        case "--width": options.width = CGFloat(number(for: arg, minimum: 300))
        case "--height": options.height = CGFloat(number(for: arg, minimum: 120))
        case "--validate": options.validateOnly = true
        case "--debug": options.debug = true
        case "-": options.file = "/dev/stdin"
        default:
            // macOS adds this when an app is opened from Finder.
            if arg.hasPrefix("-psn_") { continue }
            if arg.hasPrefix("-") { fail("Unknown option: \(arg)\n\n\(usageText)") }
            if options.file != nil { fail("Only one file can be shown at a time") }
            options.file = arg
        }
    }
    return options
}

func loadText(_ options: Options) -> String {
    if let text = options.text { return text }
    if let file = options.file {
        guard let data = FileManager.default.contents(atPath: file),
              let text = String(data: data, encoding: .utf8) else { fail("Can't read file: \(file)") }
        return text
    }
    return sampleText
}

var debugLogging = false

/// Notes for debugging, in ~/Library/Logs/notchcue.log. Only written with --debug.
func log(_ message: String) {
    guard debugLogging else { return }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/notchcue.log")
    let line = Data("\(Date()) \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

/// Lowercase letters and digits only, so "Codex," and "codex" match.
func normalized(_ word: String) -> String {
    String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
}

/// A spoken word in the script and where it sits in the displayed text.
struct Token {
    let word: String
    let range: NSRange
}

/// Turns plain text into styled paragraphs, and lists the words to be spoken.
func styledText(_ text: String, fontSize: CGFloat) -> (NSAttributedString, [Token]) {
    let bodyStyle = NSMutableParagraphStyle()
    bodyStyle.lineSpacing = fontSize * 0.25
    bodyStyle.paragraphSpacing = fontSize * 0.6
    let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: bodyStyle,
    ]
    let cue: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: max(fontSize * 0.4, 12), weight: .bold),
        .foregroundColor: NSColor(white: 0.5, alpha: 1),
        .paragraphStyle: bodyStyle,
    ]

    let result = NSMutableAttributedString()
    var tokens: [Token] = []
    for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let isCue = line.hasPrefix("[") && line.hasSuffix("]")
        if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: body)) }
        let start = result.length
        result.append(NSAttributedString(string: isCue ? line.uppercased() : line, attributes: isCue ? cue : body))
        guard !isCue else { continue }
        let ns = line as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            guard let word, !normalized(word).isEmpty else { return }
            tokens.append(Token(word: normalized(word), range: NSRange(location: start + range.location, length: range.length)))
        }
    }
    return (result, tokens)
}

/// Finds where in the script the speaker is, from the last few words heard.
///
/// Looks a little behind and well ahead of the current place, scores each spot by how
/// many of the recent words line up with the script there, and only jumps backwards
/// when the match is strong (you went back and said a line again).
func matchPosition(heard: [String], script: [String], current: Int) -> Int? {
    let recent = Array(heard.suffix(5))
    guard let last = recent.last, !script.isEmpty else { return nil }

    func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Partial results can cut a word short, and plurals or tenses can differ.
        let shorter = min(a.count, b.count)
        return shorter >= 4 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    var best: (index: Int, score: Int)?
    let lower = max(0, current - 40)
    let upper = min(script.count - 1, current + 30)
    guard lower <= upper else { return nil }
    for j in lower...upper where same(script[j], last) {
        // Walk back through what was heard, allowing a skipped or misheard word.
        var score = 1
        var s = j - 1
        for word in recent.dropLast().reversed() {
            guard s >= 0 else { break }
            if same(script[s], word) { score += 1; s -= 1 }
            else if s >= 1 && same(script[s - 1], word) { score += 1; s -= 2 }
        }
        let backwards = j + 1 < current
        let farAhead = j > current + 8
        // Short or common words ("the", "a") are everywhere; need more evidence for far jumps.
        if backwards && score < 3 { continue }
        if farAhead && score < 2 { continue }
        if score == 1 && last.count < 3 { continue }
        // Prefer the strongest match; among equals, the one closest after the current place.
        if best == nil || score > best!.score
            || (score == best!.score && abs(j - current) < abs(best!.index - current)) {
            best = (j, score)
        }
    }
    return best.map { $0.index + 1 }
}

/// Listens to the microphone and reports the words heard so far, using Apple's
/// on-device speech recognition when the Mac supports it (free and offline).
final class VoiceFollower {
    var onWords: (([String]) -> Void)?
    var onStatus: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hints: [String]
    private(set) var running = false
    private var quickFailures = 0

    init(locale: String?, hints: [String]) {
        let wanted = locale.map(Locale.init(identifier:)) ?? Locale.current
        recognizer = SFSpeechRecognizer(locale: wanted) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.hints = hints
    }

    var onDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start() {
        guard let recognizer else { return report("Speech recognition isn't available for this language") }
        log("locale \(recognizer.locale.identifier), on-device \(recognizer.supportsOnDeviceRecognition), available \(recognizer.isAvailable)")
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    return self.report("Speech recognition is off. Allow it in System Settings → Privacy & Security → Speech Recognition")
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            return self.report("Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone")
                        }
                        guard recognizer.isAvailable else { return self.report("Speech recognition isn't available right now") }
                        self.beginListening()
                    }
                }
            }
        }
    }

    func stop() {
        running = false
        task?.cancel()
        request?.endAudio()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func report(_ message: String) {
        log("status: \(message)")
        onStatus?(message)
    }

    private func beginListening() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            return report("Couldn't start the microphone: \(error.localizedDescription)")
        }
        running = true
        startTask()
        report(onDevice ? "Listening (on this Mac)" : "Listening")
    }

    /// Recognition sessions end on their own after a while, so start a fresh one each time.
    private func startTask() {
        guard running, let recognizer else { return }
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        request.contextualStrings = hints
        self.request = request
        let started = CACurrentMediaTime()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error { log("recognition error: \(error)") }
            if let result {
                log("heard: \(result.bestTranscription.formattedString)")
                let words = result.bestTranscription.segments.map { normalized($0.substring) }.filter { !$0.isEmpty }
                DispatchQueue.main.async { self.onWords?(words) }
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    guard self.running, self.request === request else { return }
                    // A session that fails straight away will keep failing; stop and say why.
                    if let error = error as NSError?, CACurrentMediaTime() - started < 2 {
                        self.quickFailures += 1
                        if error.code == 201 {
                            self.stop()
                            return self.report("Turn on Dictation first: System Settings → Keyboard → Dictation. Then press V")
                        }
                        if self.quickFailures >= 3 {
                            self.stop()
                            return self.report("Speech recognition stopped: \(error.localizedDescription). Press V to retry")
                        }
                    } else {
                        self.quickFailures = 0
                    }
                    self.startTask()
                }
            }
        }
    }
}

/// Draws a marker showing where the line you're reading should sit.
final class GuideView: NSView {
    var readingY: CGFloat = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 14, y: readingY - 10))
        arrow.line(to: NSPoint(x: 29, y: readingY))
        arrow.line(to: NSPoint(x: 14, y: readingY + 10))
        arrow.close()
        NSColor.systemRed.setFill()
        arrow.fill()
    }
}

/// A borderless window that can still take key presses.
final class PrompterWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Prompter: NSObject, NSApplicationDelegate {
    var options: Options
    let text: String

    var window: NSWindow!
    var scrollView: NSScrollView!
    var textView: NSTextView!
    var guide: GuideView!
    var hud: NSTextField!
    var countdownLabel: NSTextField!

    var frameTimer: Timer?
    var countdownTimer: Timer?
    var hudHide: DispatchWorkItem?

    var lastTick: CFTimeInterval = 0
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

    var topInset: CGFloat = 0            // height of the notch / menu bar strip at the top
    let readingLineFraction: CGFloat = 0.28
    let sideMargin: CGFloat = 44

    init(options: Options, text: String) {
        self.options = options
        self.text = text
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prefer the built-in screen with the notch (and its camera).
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        topInset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : frame.maxY - screen.visibleFrame.maxY
        var notchWidth: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        }
        let width = min(max(options.width, notchWidth + 120), frame.width)
        let height = min(options.height, frame.height / 2) + topInset

        // The top strip sits behind the notch and the menu bar; it's black so it blends in.
        window = PrompterWindow(contentRect: NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .statusBar
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 22
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        window.contentView = content

        let textArea = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - topInset)
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
        scrollView.documentView = textView
        content.addSubview(scrollView)

        guide = GuideView(frame: textArea)
        guide.autoresizingMask = [.width, .height]
        content.addSubview(guide)

        hud = makeLabel(size: 13, weight: .medium, color: NSColor(white: 0.6, alpha: 1))
        countdownLabel = makeLabel(size: 90, weight: .bold, color: .white)
        content.addSubview(hud)
        content.addSubview(countdownLabel)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            countdownLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        reloadText(keepProgress: false)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer

        if options.followVoice { startFollowing() } else { startCountdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { follower?.stop() }

    // MARK: Layout

    func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

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
        if follower == nil {
            let hints = Array(Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }))
            let follower = VoiceFollower(locale: options.locale, hints: Array(hints.prefix(100)))
            follower.onWords = { [weak self] words in self?.heard(words) }
            follower.onStatus = { [weak self] message in self?.showHUD(message, sticky: true) }
            self.follower = follower
        }
        if follower?.running != true { follower?.start() }
        showHUD("Following your voice", sticky: true)
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
        } else {
            setPosition(next)
        }
    }

    func startCountdown() {
        countdownTimer?.invalidate()
        paused = true
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
    }

    func resume() {
        countdownTimer?.invalidate()
        countingDown = false
        countdownLabel.isHidden = true
        scrollView.alphaValue = 1
        if !options.followVoice && position >= endOffset { setPosition(startOffset) }
        lastTick = CACurrentMediaTime()
        paused = false
        showHUD(options.followVoice ? "Following your voice" : "\(Int(options.wpm)) wpm")
    }

    // MARK: Keys

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: // space
            if countingDown || paused { resume() } else { paused = true; showHUD("Paused", sticky: true) }
        case 126: // up
            if options.followVoice { moveCursor(by: -1) } else { changeSpeed(by: 10) }
        case 125: // down
            if options.followVoice { moveCursor(by: 1) } else { changeSpeed(by: -10) }
        case 53: // escape
            NSApp.terminate(nil)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q": NSApp.terminate(nil)
            case "r":
                cursor = 0
                markSpoken()
                setPosition(startOffset)
                if options.followVoice { resume() } else { startCountdown() }
            case "v": toggleMode()
            case "=", "+": changeFontSize(by: 4)
            case "-", "_": changeFontSize(by: -4)
            default: return false
            }
        }
        return true
    }

    func toggleMode() {
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

    func moveCursor(by delta: Int) {
        cursor = min(max(cursor + delta, 0), tokens.count)
        markSpoken()
    }

    func changeSpeed(by delta: Double) {
        options.wpm = min(max(options.wpm + delta, 40), 400)
        relayout(keepProgress: true)
        showHUD("\(Int(options.wpm)) wpm")
    }

    func changeFontSize(by delta: CGFloat) {
        options.fontSize = min(max(options.fontSize + delta, 20), 160)
        reloadText(keepProgress: true)
        showHUD("Text size \(Int(options.fontSize))")
    }

    func showHUD(_ message: String, sticky: Bool = false) {
        hudHide?.cancel()
        hud.stringValue = message
        hud.isHidden = false
        guard !sticky else { return }
        let hide = DispatchWorkItem { [weak self] in self?.hud.isHidden = true }
        hudHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hide)
    }
}

let options = parseOptions()
let text = loadText(options)
if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("There's no text to show") }
if options.validateOnly { exit(0) }
debugLogging = options.debug

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let prompter = Prompter(options: options, text: text)
app.delegate = prompter
app.run()
