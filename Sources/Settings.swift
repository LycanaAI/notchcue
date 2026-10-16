// Command-line options, saved settings, recent files and the Settings window.

import AppKit
import Speech

let usageText = """
Usage: notchcue [FILE | -] [options]

Shows FILE (or text from --text, or stdin when FILE is "-") in a window that
hangs down from the top centre of the screen, around the notch. With no
script it shows a welcome panel where you can drop, open or paste one.

By default it follows your voice: say the script out loud and it scrolls to
keep the line you're on at the reading arrow. Words you've said turn grey.
With --steady it scrolls at a fixed pace instead.

FILE can be .txt, .md, .rtf, .rtfd, .docx, .doc, .odt, .html or .pdf.
Lines wrapped in square brackets, like [Hook], and Markdown headings are
shown as small grey cues and are not read out.

Options (these override Settings for this run):
  --steady           Scroll at a steady pace instead of following your voice
  --voice            Follow your voice (when Settings says to start in steady mode)
  --wpm N            Pace for --steady, in words per minute (default 150)
  --locale ID        Speech recognition language (default: your system language, e.g. en-AU)
  --text TEXT        Text to show instead of a file
  --font-size N      Text size in points (default 40)
  --countdown N      Seconds to count down before a steady scroll (default 3, 0 = none)
  --width N          Window width in points (default 760)
  --height N         Window height below the notch, in points (default 280)
  --sample           Show a short sample script
  --debug            Write what it hears to ~/Library/Logs/notchcue.log
  --validate         Check the options and text, then exit without opening a window
  --show VIEW        Open with a view showing, for screenshots and testing:
                     help, controls, minimised or settings
  --self-test        Run the built-in tests and exit
  -h, --help         Show this help

Keys while running:
  Space        Pause / resume
  V            Switch between following your voice and a steady scroll
  Up / Down    Steady scroll: faster / slower. Voice: move the place marker by a word
  + / -        Bigger / smaller text
  R            Back to the top
  M            Minimise to a small pill at the notch (click it or press M to expand)
  ?            Help
  Cmd-O        Open a script      Cmd-V   Paste text as the script
  Cmd-,        Settings           Esc/Q   Close
Drag the window to move it. NotchCue also has a menu in the menu bar.
"""

let sampleText = """
[Sample text]
This is NotchCue. Start reading out loud and the text follows your voice.

If you pause, it waits for you. If you go back and say a line again, it jumps back to it.

Press V to switch to a steady scroll, M to minimise, and Escape to close the window.
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
    var sample = false
    var show: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

/// Starts from the saved settings, then applies the command-line options on top.
func parseOptions(_ arguments: [String], settings: Settings) -> Options {
    var options = settings.options
    var args = arguments

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
        case "--voice": options.followVoice = true
        case "--text": options.text = value(for: arg)
        case "--wpm": options.wpm = number(for: arg, minimum: 20)
        case "--locale": options.locale = value(for: arg)
        case "--font-size": options.fontSize = CGFloat(number(for: arg, minimum: 12))
        case "--countdown": options.countdown = Int(number(for: arg, minimum: 0))
        case "--width": options.width = CGFloat(number(for: arg, minimum: 300))
        case "--height": options.height = CGFloat(number(for: arg, minimum: 120))
        case "--validate": options.validateOnly = true
        case "--debug": options.debug = true
        case "--sample": options.sample = true
        case "--show":
            let view = value(for: arg)
            guard ["help", "controls", "minimised", "minimized", "settings"].contains(view) else {
                fail("--show must be help, controls, minimised or settings")
            }
            options.show = view
        case "-": options.file = "/dev/stdin"
        default:
            // macOS adds this when an app is opened from Finder.
            if arg.hasPrefix("-psn_") { continue }
            // AppKit-style defaults passed on the command line, e.g. -NSFoo YES.
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") { if !args.isEmpty { args.removeFirst() }; continue }
            if arg.hasPrefix("-") { fail("Unknown option: \(arg)\n\n\(usageText)") }
            if options.file != nil { fail("Only one file can be shown at a time") }
            options.file = arg
        }
    }
    return options
}

// MARK: Saved settings

/// The defaults the user picks in the Settings window, saved in UserDefaults.
struct Settings: Equatable {
    var fontSize: Double = 40
    var width: Double = 760
    var height: Double = 280
    var locale = ""            // "" means the system language
    var wpm: Double = 150
    var startWithVoice = true
    var countdown = 3

    static let fontRange = 20.0...160.0
    static let widthRange = 300.0...3000.0
    static let heightRange = 120.0...1200.0
    static let wpmRange = 40.0...400.0
    static let countdownRange = 0...10

    private static let store = UserDefaults.standard
    private static let prefix = "settings."

    static func load() -> Settings {
        var s = Settings()
        func number(_ key: String) -> Double? { store.object(forKey: prefix + key) as? Double }
        if let v = number("fontSize") { s.fontSize = v.clamped(to: fontRange) }
        if let v = number("width") { s.width = v.clamped(to: widthRange) }
        if let v = number("height") { s.height = v.clamped(to: heightRange) }
        if let v = number("wpm") { s.wpm = v.clamped(to: wpmRange) }
        if let v = store.object(forKey: prefix + "countdown") as? Int { s.countdown = min(max(v, 0), 10) }
        if let v = store.string(forKey: prefix + "locale") { s.locale = v }
        if let v = store.object(forKey: prefix + "startWithVoice") as? Bool { s.startWithVoice = v }
        return s
    }

    func save() {
        let store = Settings.store, p = Settings.prefix
        store.set(fontSize, forKey: p + "fontSize")
        store.set(width, forKey: p + "width")
        store.set(height, forKey: p + "height")
        store.set(wpm, forKey: p + "wpm")
        store.set(countdown, forKey: p + "countdown")
        store.set(locale, forKey: p + "locale")
        store.set(startWithVoice, forKey: p + "startWithVoice")
    }

    var options: Options {
        var o = Options()
        o.fontSize = CGFloat(fontSize)
        o.width = CGFloat(width)
        o.height = CGFloat(height)
        o.wpm = wpm
        o.countdown = countdown
        o.locale = locale.isEmpty ? nil : locale
        o.followVoice = startWithVoice
        return o
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// The last few scripts opened, newest first.
enum RecentFiles {
    private static let key = "recentFiles"
    static let limit = 5

    static var paths: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func add(_ path: String) {
        // Text piped in through the command line is saved to a temporary file; skip those.
        let tmp = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        if path.hasPrefix(tmp) || path.hasPrefix(NSTemporaryDirectory()) || path.hasPrefix("/dev/") { return }
        var list = paths.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: Settings window

/// A small native window for the saved defaults. Changes are saved and applied straight away.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var settings: Settings
    private let onChange: (Settings) -> Void

    private let fontRow = NumberRow(range: Settings.fontRange, step: 2, unit: "pt")
    private let widthRow = NumberRow(range: Settings.widthRange, step: 20, unit: "pt")
    private let heightRow = NumberRow(range: Settings.heightRange, step: 20, unit: "pt")
    private let wpmRow = NumberRow(range: Settings.wpmRange, step: 10, unit: "words a minute")
    private let countdownRow = NumberRow(range: 0...10, step: 1, unit: "seconds")
    private let localePopup = NSPopUpButton()
    private let modeControl = NSSegmentedControl(labels: ["Follow voice", "Steady scroll"], trackingMode: .selectOne, target: nil, action: nil)

    init(settings: Settings, onChange: @escaping (Settings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NotchCue Settings"
        window.isReleasedWhenClosed = false
        // Float, so it shows up even when macOS doesn't bring NotchCue to the front.
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        build()
        show(settings)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for row in [fontRow, widthRow, heightRow, wpmRow, countdownRow] {
            row.onChange = { [weak self] in self?.changed() }
        }

        let system = Locale.current
        localePopup.addItem(withTitle: "System language (\(system.localizedString(forIdentifier: system.identifier) ?? system.identifier))")
        localePopup.lastItem?.representedObject = ""
        localePopup.menu?.addItem(.separator())
        let locales = SFSpeechRecognizer.supportedLocales().map { locale -> (String, String) in
            (locale.identifier, Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        for (id, name) in locales {
            localePopup.addItem(withTitle: "\(name)  (\(id))")
            localePopup.lastItem?.representedObject = id
        }
        localePopup.target = self
        localePopup.action = #selector(changedControl)
        modeControl.target = self
        modeControl.action = #selector(changedControl)

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label("Text size:"), fontRow.view],
            [label("Panel width:"), widthRow.view],
            [label("Panel height:"), heightRow.view],
            [label("Speech language:"), localePopup],
            [label("Start in:"), modeControl],
            [label("Steady speed:"), wpmRow.view],
            [label("Countdown:"), countdownRow.view],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        let note = NSTextField(wrappingLabelWithString: "Changes apply straight away and are kept for next time. Options given on the command line win for that run. The panel height is measured below the notch; the countdown is shown before a steady scroll starts.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))

        let stack = NSStackView(views: [grid, note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            note.widthAnchor.constraint(equalToConstant: 420),
        ])
        window?.contentView = content
    }

    private func show(_ s: Settings) {
        fontRow.value = s.fontSize
        widthRow.value = s.width
        heightRow.value = s.height
        wpmRow.value = s.wpm
        countdownRow.value = Double(s.countdown)
        modeControl.selectedSegment = s.startWithVoice ? 0 : 1
        let index = localePopup.itemArray.firstIndex { ($0.representedObject as? String) == s.locale } ?? 0
        localePopup.selectItem(at: index)
    }

    @objc private func changedControl() { changed() }

    private func changed() {
        var s = settings
        s.fontSize = fontRow.value
        s.width = widthRow.value
        s.height = heightRow.value
        s.wpm = wpmRow.value
        s.countdown = Int(countdownRow.value)
        s.startWithVoice = modeControl.selectedSegment == 0
        s.locale = localePopup.selectedItem?.representedObject as? String ?? ""
        guard s != settings else { return }
        settings = s
        s.save()
        onChange(s)
    }

    @objc private func resetDefaults() {
        show(Settings())
        changed()
    }
}

/// A number field with a stepper and a unit, clamped to a range.
final class NumberRow: NSObject, NSTextFieldDelegate {
    let view: NSStackView
    var onChange: (() -> Void)?
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let range: ClosedRange<Double>

    init(range: ClosedRange<Double>, step: Double, unit: String) {
        self.range = range
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.textColor = .secondaryLabelColor
        view = NSStackView(views: [field, stepper, unitLabel])
        view.spacing = 6
        super.init()
        field.delegate = self
        field.target = self
        field.action = #selector(fieldChanged)
        stepper.target = self
        stepper.action = #selector(stepped)
    }

    var value: Double {
        get { stepper.doubleValue }
        set {
            stepper.doubleValue = newValue.clamped(to: range)
            field.stringValue = String(Int(stepper.doubleValue.rounded()))
        }
    }

    @objc private func stepped() {
        field.stringValue = String(Int(stepper.doubleValue.rounded()))
        onChange?()
    }

    @objc private func fieldChanged() {
        if let n = Double(field.stringValue.trimmingCharacters(in: .whitespaces)) { value = n } else { value = stepper.doubleValue }
        onChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) { fieldChanged() }
}
