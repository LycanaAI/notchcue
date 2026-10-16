// Built-in tests, run by `notchcue --self-test` and `make check`.

import AppKit

private var failures = 0
private var passes = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected {
        passes += 1
    } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expect(_ condition: Bool, _ name: String) {
    if condition { passes += 1 } else { failures += 1; print("FAIL \(name)") }
}

func runSelfTests() -> Bool {
    testMarkdown()
    testMatcher()
    testStyledText()
    testFiles()
    print(failures == 0 ? "All \(passes) checks passed" : "\(failures) of \(passes + failures) checks failed")
    return failures == 0
}

private func testMarkdown() {
    expect(markdownToScript("# Intro\nHello there."), "[Intro]\nHello there.", "ATX heading becomes a cue")
    expect(markdownToScript("## Part two ##\ntext"), "[Part two]\ntext", "closing hashes removed")
    expect(markdownToScript("Title\n=====\nBody"), "[Title]\nBody", "setext heading")
    expect(markdownToScript("This is **bold**, *italic*, __strong__, _em_ and `code`."),
           "This is bold, italic, strong, em and code.", "emphasis and code stripped")
    expect(markdownToScript("Keep snake_case_words and 2 * 3 * 4 intact."),
           "Keep snake_case_words and 2 * 3 * 4 intact.", "underscores in words and lone asterisks kept")
    expect(markdownToScript("~~old~~ and ==marked== text"), "old and marked text", "strikethrough and highlight")
    expect(markdownToScript("See [the docs](https://example.com) or [this][ref]."),
           "See the docs or this.", "links keep their text")
    expect(markdownToScript("Look ![a chart](chart.png) here"), "Look here", "images dropped")
    expect(markdownToScript("![only an image](x.png)"), "", "image-only line dropped")
    expect(markdownToScript("- one\n- two\n* three\n+ four\n1. five\n2) six\n- [x] done"),
           "one\ntwo\nthree\nfour\nfive\nsix\ndone", "list markers stripped")
    expect(markdownToScript("> quoted line\n> continues\n\n> > nested"), "quoted line continues\nnested", "blockquotes")
    expect(markdownToScript("Before\n```swift\nlet x = 1\n```\nAfter"), "Before\nAfter", "fenced code skipped")
    expect(markdownToScript("A\n~~~\ncode\n~~~\nB"), "A\nB", "tilde fence skipped")
    expect(markdownToScript("---\ntitle: Episode 1\ntags: [a, b]\n---\n# Hook\nGo."), "[Hook]\nGo.", "front matter skipped")
    expect(markdownToScript("Say this <!-- not this --> please\n<!--\nhidden\n-->\nshown"),
           "Say this please\nshown", "HTML comments skipped")
    expect(markdownToScript("one line\nwrapped here\n\nnext paragraph"), "one line wrapped here\nnext paragraph", "soft wraps joined")
    expect(markdownToScript("hard  \nbreak"), "hard\nbreak", "two-space hard break")
    expect(markdownToScript("[Intro]\nWords"), "[Intro]\nWords", "existing cue lines kept")
    expect(markdownToScript("Text\n\n***\n\nMore"), "Text\nMore", "thematic break dropped")
    expect(markdownToScript("Escaped \\*stars\\* stay"), "Escaped *stars* stay", "escaped characters kept")
    expect(markdownToScript("Line with <b>tags</b><br/>"), "Line with tags", "inline HTML tags removed")
    expect(markdownToScript("| A | B |\n|---|---|\n| 1 | 2 |"), "A, B\n1, 2", "tables read as cells")
    expect(markdownToScript("[ref]: https://example.com\nText"), "Text", "link reference definitions dropped")
    expect(markdownToScript("# **Bold** heading"), "[Bold heading]", "emphasis stripped in cues")
    expect(markdownToScript("\u{FEFF}# BOM\nok"), "[BOM]\nok", "byte order mark ignored")
    // The example in docs/script-format.md.
    expect(markdownToScript("""
    ---
    title: Episode 1
    ---

    # Hook

    I asked an **auditor** what *AI* they use. A [chatbot](https://example.com).
    That was the whole answer.

    <!-- director: pause here -->

    ## The gap

    - Most firms buy a `licence` and stop.
    - The rest build workflows.

    > The tools are not the problem.
    """), """
    [Hook]
    I asked an auditor what AI they use. A chatbot. That was the whole answer.
    [The gap]
    Most firms buy a licence and stop.
    The rest build workflows.
    The tools are not the problem.
    """, "docs example")
}

private func testMatcher() {
    let script = scriptWords("The quick brown fox jumps over the lazy dog. Then the fox runs home to the den and sleeps.")
    expect(matchPosition(heard: ["the", "quick", "brown"], script: script, current: 0) == 3, "follows from the start")
    expect(matchPosition(heard: ["quick", "brown", "fox", "jump"], script: script, current: 2) == 5, "partial word matches")
    expect(matchPosition(heard: ["brown", "fax", "jumps"], script: script, current: 2) == 5, "tolerates a misheard word")
    expect(matchPosition(heard: ["quick", "jumps"], script: script, current: 2) == 5, "tolerates a skipped word")
    expect(matchPosition(heard: [], script: script, current: 0) == nil, "nothing heard")
    let lone = matchPosition(heard: ["the"], script: script, current: 12)
    expect(lone == nil || (lone! >= 12 && lone! <= 21), "a lone common word never jumps back")
    let jumpedBack = matchPosition(heard: ["the", "quick", "brown", "fox"], script: script, current: 15)
    expect(jumpedBack == 4, "retake jumps back on a strong match (got \(String(describing: jumpedBack)))")
    let weakBack = matchPosition(heard: ["fox"], script: script, current: 15)
    expect(weakBack == nil || weakBack! >= 14, "weak match doesn't jump back")
    expect(matchPosition(heard: ["zebra"], script: script, current: 3) == nil, "unknown word ignored")
    expect(normalized("Codex,") == "codex" && normalized("It's") == "its", "normalising words")
}

private func testStyledText() {
    let (styled, tokens) = styledText("[Hook]\nHello, world!\n\nSecond line", fontSize: 30)
    expect(tokens.map(\.word).joined(separator: " "), "hello world second line", "cue words aren't spoken")
    expect(styled.string.hasPrefix("[HOOK]\nHello"), "cues shown in capitals")
    let ns = styled.string as NSString
    expect(ns.substring(with: tokens[1].range), "world", "token ranges point at the words")
}

private func testFiles() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchcue-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ data: Data) -> URL {
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }
    func load(_ url: URL) -> String { (try? scriptText(fromFileAt: url)) ?? "<error>" }

    expect(load(write("a.txt", Data("[Cue]\nPlain text".utf8))), "[Cue]\nPlain text", "txt read as is")
    expect(load(write("a.md", Data("# Cue\n**Bold** text".utf8))), "[Cue]\nBold text", "md converted")
    expect(load(write("notes", Data("No extension".utf8))), "No extension", "no extension read as text")
    expect(load(write("script.fountain", Data("Unknown but text".utf8))), "Unknown but text", "unknown text file still read")

    let rich = NSAttributedString(string: "First paragraph.\nSecond paragraph.", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    let range = NSRange(location: 0, length: rich.length)
    if let rtf = try? rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
        expect(load(write("a.rtf", rtf)), "First paragraph.\nSecond paragraph.", "rtf read")
    } else { expect(false, "making rtf") }
    if let docx = try? rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
        expect(load(write("a.docx", docx)), "First paragraph.\nSecond paragraph.", "docx read")
    } else { expect(false, "making docx") }
    expect(load(write("a.html", Data("<html><body><h1>Title</h1><p>Hello <b>there</b>.</p></body></html>".utf8))).contains("Hello there."), "html read")

    // A one-page PDF with real text in it.
    let pdfURL = dir.appendingPathComponent("a.pdf")
    var box = CGRect(x: 0, y: 0, width: 400, height: 200)
    if let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil) {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello from a PDF.", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }
    expect(load(pdfURL), "Hello from a PDF.", "pdf text extracted")

    var unsupported = ""
    do { _ = try scriptText(fromFileAt: write("a.png", Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0]))) } catch { unsupported = error.localizedDescription }
    expect(unsupported.contains("can't read a.png"), "unsupported file gives a clear message")
    var empty = ""
    do { _ = try scriptText(fromFileAt: write("empty.md", Data("```\ncode only\n```".utf8))) } catch { empty = error.localizedDescription }
    expect(empty.contains("no text"), "empty script is reported")

    expect(reflowExtractedLines("This line was\nwrapped by the PDF.\nNew one\nstarts here."),
           "This line was wrapped by the PDF.\nNew one starts here.", "pdf lines rejoined")
    expect(reflowExtractedLines("hyphen-\nated word."), "hyphenated word.", "hyphenated line breaks joined")
    expect(reflowExtractedLines("[Intro]\nText"), "[Intro]\nText", "cues kept on their own line")
}
