// The views inside the panel: reading arrow, hover controls, help, welcome and the minimised pill.

import AppKit

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
    /// Stay exactly where we're put, even over the menu bar and notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The window's content view: a black shape that fills the window from the very top of
/// the screen (covering the menu bar strip and the notch), with rounded bottom corners
/// only, so the notch and the panel read as one shape. Accepts files (and text) dropped
/// onto the panel.
final class DropView: NSView {
    var cornerRadius: CGFloat = 20 { didSet { needsLayout = true } }
    private let shape = CAShapeLayer()
    var maskPathBounds: NSRect? { shape.path?.boundingBox }

    var onDropFile: ((URL) -> Void)?
    var onDropText: ((String) -> Void)?
    var onDragHighlight: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string])
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = shape
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateShape()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShape()
    }

    private func updateShape() {
        // Square top corners, rounded bottom corners (view coordinates: y grows upwards).
        let r = min(cornerRadius, bounds.height / 2, bounds.width / 2)
        let w = bounds.width, h = bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w, y: r))
        path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w - r, y: 0), radius: r)
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: 0, y: r), radius: r)
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path
        CATransaction.commit()
        window?.invalidateShadow()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragHighlight?(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragHighlight?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHighlight?(false)
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            onDropFile?(url)
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            onDropText?(text)
            return true
        }
        return false
    }
}

/// The full-size panel. Reports the mouse coming and going, for the hover controls.
final class PanelView: NSView {
    var onMouse: ((_ inside: Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onMouse?(true) }
    override func mouseMoved(with event: NSEvent) { onMouse?(true) }
    override func mouseExited(with event: NSEvent) { onMouse?(false) }
}

/// A button that works on the first click, even when NotchCue isn't the active app.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

func symbolButton(_ symbol: String, _ tip: String, size: CGFloat = 14, action: @escaping () -> Void) -> FirstClickButton {
    let button = FirstClickButton(frame: .zero)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
    button.symbolConfiguration = .init(pointSize: size, weight: .medium)
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = NSColor(white: 1, alpha: 0.7)
    button.toolTip = tip
    button.setAccessibilityLabel(tip)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    ActionTarget.attach(action, to: button)
    return button
}

/// Lets a closure be a button's action.
final class ActionTarget: NSObject {
    private let action: () -> Void
    private static var key = 0
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }

    static func attach(_ action: @escaping () -> Void, to control: NSControl) {
        let target = ActionTarget(action)
        objc_setAssociatedObject(control, &key, target, .OBJC_ASSOCIATION_RETAIN)
        control.target = target
        control.action = #selector(run)
    }
}

/// The row of small buttons that fades in at the bottom of the panel on hover.
final class ControlsBar: NSView {
    struct Actions {
        var pause: () -> Void
        var mode: () -> Void
        var smaller: () -> Void
        var bigger: () -> Void
        var minimise: () -> Void
        var settings: () -> Void
        var help: () -> Void
        var close: () -> Void
    }

    private var pauseButton: FirstClickButton!
    private var modeButton: FirstClickButton!
    var mouseInside = false

    init(actions: Actions) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.92).cgColor
        layer?.cornerRadius = 15
        translatesAutoresizingMaskIntoConstraints = false

        pauseButton = symbolButton("pause.fill", "Pause or resume (Space)", action: actions.pause)
        modeButton = symbolButton("waveform", "Switch voice / steady scroll (V)", action: actions.mode)
        let buttons: [NSView] = [
            pauseButton,
            modeButton,
            divider(),
            symbolButton("textformat.size.smaller", "Smaller text (−)", action: actions.smaller),
            symbolButton("textformat.size.larger", "Bigger text (+)", action: actions.bigger),
            divider(),
            symbolButton("chevron.up", "Minimise to the notch (M)", action: actions.minimise),
            symbolButton("gearshape", "Settings (⌘,)", action: actions.settings),
            symbolButton("questionmark.circle", "Help (?)", action: actions.help),
            symbolButton("xmark", "Close NotchCue (Esc)", action: actions.close),
        ]
        let stack = NSStackView(views: buttons)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    func update(paused: Bool, followVoice: Bool) {
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")
        pauseButton.toolTip = paused ? "Resume (Space)" : "Pause (Space)"
        modeButton.image = NSImage(systemSymbolName: followVoice ? "waveform" : "arrow.down.to.line", accessibilityDescription: nil)
        modeButton.toolTip = followVoice ? "Following your voice. Switch to steady scroll (V)" : "Steady scroll. Switch to following your voice (V)"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The minimised panel: a small pill against the notch with a status dot, the line
/// you're on and how far through you are. Click it to expand.
final class PillView: NSView {
    var onClick: (() -> Void)?
    var notchWidth: CGFloat = 0
    var topInset: CGFloat = 0

    private let dot = NSView()
    private let status = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        for label in [status, percent] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = NSColor(white: 0.75, alpha: 1)
        }
        line.font = .systemFont(ofSize: 13, weight: .medium)
        line.textColor = NSColor(white: 0.92, alpha: 1)
        line.lineBreakMode = .byTruncatingTail
        line.alignment = .left
        percent.alignment = .right
        [dot, percent, line].forEach(addSubview)
        toolTip = "Click or press M to expand"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func update(color: NSColor, status text: String, line snippet: String, progress: CGFloat?) {
        dot.layer?.backgroundColor = color.cgColor
        status.stringValue = text
        toolTip = "\(text). Click or press M to expand"
        line.stringValue = snippet
        percent.stringValue = progress.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // One row under the notch: status dot, the line you're on, and progress.
        let w = bounds.width
        let midY = topInset + (bounds.height - topInset) / 2
        dot.frame = NSRect(x: 14, y: midY - 4, width: 8, height: 8)
        percent.frame = NSRect(x: w - 52, y: midY - 8, width: 40, height: 16)
        line.frame = NSRect(x: 30, y: midY - 9, width: w - 88, height: 18)
    }
}

/// The cheat sheet shown over the text by ? or the Help menu.
final class HelpView: NSView {
    init(onGuide: @escaping () -> Void, onClose: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.97).cgColor

        func keys(_ rows: [(String, String)]) -> NSTextField {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .left, location: 58)]
            style.headIndent = 58
            style.paragraphSpacing = 3
            let text = NSMutableAttributedString()
            for (i, (key, action)) in rows.enumerated() {
                text.append(NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: style]))
                text.append(NSAttributedString(string: "\t" + action + (i < rows.count - 1 ? "\n" : ""), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.7, alpha: 1), .paragraphStyle: style]))
            }
            let label = NSTextField(labelWithAttributedString: text)
            label.maximumNumberOfLines = 0
            return label
        }
        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .bold)
            label.textColor = NSColor(white: 0.5, alpha: 1)
            return label
        }
        func column(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            return stack
        }

        let left = column([heading("Keys"), keys([
            ("Space", "Pause / resume"),
            ("V", "Follow voice / steady scroll"),
            ("↑ ↓", "Speed, or nudge your place"),
            ("+ −", "Bigger / smaller text"),
            ("R", "Back to the top"),
            ("M", "Minimise to the notch"),
        ])])
        let middle = column([heading(" "), keys([
            ("?", "This help"),
            ("⌘O", "Open a script"),
            ("⌘V", "Paste a script"),
            ("⌘,", "Settings"),
            ("Esc Q", "Close"),
            ("Drag", "Move panel"),
        ])])

        let about = NSTextField(wrappingLabelWithString: """
        Read out loud. Words you've said turn grey and the text scrolls with you. It waits when you stop, and jumps back if you say a line again.

        Needs Dictation on: System Settings → Keyboard → Dictation. The first time, allow Speech Recognition and Microphone. Change them later in System Settings → Privacy & Security.
        """)
        about.font = .systemFont(ofSize: 12)
        about.textColor = NSColor(white: 0.7, alpha: 1)
        let right = column([heading("Following your voice"), about])

        let columns = NSStackView(views: [left, middle, right])
        columns.alignment = .top
        columns.spacing = 22
        columns.distribution = .fill
        right.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        about.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let guide = FirstClickButton(title: "Full guide ↗", target: nil, action: nil)
        guide.isBordered = false
        guide.attributedTitle = NSAttributedString(string: "Full guide ↗", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemBlue])
        ActionTarget.attach(onGuide, to: guide)
        let hint = NSTextField(labelWithString: "Esc or ? to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 0.45, alpha: 1)
        let close = symbolButton("xmark.circle.fill", "Close help", size: 15, action: onClose)
        let footer = NSStackView(views: [guide, NSView(), hint, close])
        footer.distribution = .fill

        let stack = NSStackView(views: [columns, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 44, bottom: 10, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            // Everything below may clip, but must never be stronger than the panel's
            // size (priority 500): otherwise AppKit grows the whole window to fit the help.
            stack.trailingAnchor.constraint(equalTo: trailingAnchor).withPriority(.defaultLow),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor).withPriority(.defaultLow),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -68).withPriority(.defaultLow),
            columns.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -68).withPriority(.defaultLow),
            // A fixed wrap width, so the paragraph's height doesn't depend on past layouts.
            about.widthAnchor.constraint(equalToConstant: 300).withPriority(.defaultLow),
        ])
        about.preferredMaxLayoutWidth = 300
        relaxCompression(self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// What the panel shows when there's no script yet.
final class WelcomeView: NSView {
    private let message = NSTextField(wrappingLabelWithString: "")
    var highlighted = false { didSet { layer?.borderWidth = highlighted ? 2 : 0 } }

    init(onOpen: @escaping () -> Void, onSample: @escaping () -> Void, onHelp: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderColor = NSColor.systemBlue.cgColor

        let title = NSTextField(labelWithString: "Drop a script here, press ⌘O, or paste with ⌘V")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keyText = NSMutableAttributedString()
        for (i, (key, action)) in [("Space", "pause"), ("V", "voice or steady scroll"), ("M", "minimise")].enumerated() {
            if i > 0 { keyText.append(NSAttributedString(string: "      ", attributes: [:])) }
            keyText.append(NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white]))
            keyText.append(NSAttributedString(string: "  " + action, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.62, alpha: 1)]))
        }
        let keys = NSTextField(labelWithAttributedString: keyText)

        let formats = NSTextField(labelWithString: "Text, Markdown, Word, RTF, OpenDocument, HTML or PDF. Settings and more are in the menu bar.")
        formats.font = .systemFont(ofSize: 11)
        formats.textColor = NSColor(white: 0.45, alpha: 1)
        formats.lineBreakMode = .byTruncatingTail
        formats.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        message.font = .systemFont(ofSize: 13, weight: .medium)
        message.textColor = .systemOrange
        message.alignment = .center
        message.isHidden = true
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        func button(_ title: String, _ action: @escaping () -> Void) -> FirstClickButton {
            let b = FirstClickButton(title: title, target: nil, action: nil)
            b.bezelStyle = .rounded
            ActionTarget.attach(action, to: b)
            return b
        }
        let buttons = NSStackView(views: [button("Open Script…", onOpen), button("Try a Sample", onSample), button("Help", onHelp)])
        buttons.spacing = 10

        let stack = NSStackView(views: [title, keys, message, buttons, formats])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: keys)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40).withPriority(.defaultLow),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            formats.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        title.preferredMaxLayoutWidth = 680
        message.preferredMaxLayoutWidth = 680
        relaxCompression(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    func showMessage(_ text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// Overlays clip rather than push: their contents never resize the panel's window.
func relaxCompression(_ root: NSView) {
    for view in root.subviews {
        if view is NSTextField || view is NSStackView {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        relaxCompression(view)
    }
}
