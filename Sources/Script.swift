// Script loading and the voice matcher. No windows here, so it can be tested on its own
// (see SelfTest.swift).

import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: Loading files

enum ScriptError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "NotchCue can't read \(name). Use a .txt, .md, .rtf, .docx, .doc, .odt, .html or .pdf file."
        case .unreadable(let name):
            return "Can't read file: \(name)"
        case .empty(let name):
            return "There's no text to show in \(name)"
        }
    }
}

/// File extensions NotchCue reads, and how.
enum ScriptFormat {
    case plain, markdown, richText(NSAttributedString.DocumentType), pdf

    static func forExtension(_ ext: String) -> ScriptFormat? {
        switch ext.lowercased() {
        case "", "txt", "text": return .plain
        case "md", "markdown", "mdown", "mkd", "mkdn": return .markdown
        case "rtf": return .richText(.rtf)
        case "rtfd": return .richText(.rtfd)
        case "docx": return .richText(.officeOpenXML)
        case "doc": return .richText(.docFormat)
        case "odt": return .richText(.openDocument)
        case "html", "htm": return .richText(.html)
        case "webarchive": return .richText(.webArchive)
        case "pdf": return .pdf
        default:
            if let type = UTType(filenameExtension: ext), type.conforms(to: .plainText) { return .plain }
            return nil
        }
    }

    /// File types for the Open dialog.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.plainText, .rtf, .rtfd, .html, .pdf, .webArchive]
        let extra = ["net.daringfireball.markdown", "org.openxmlformats.wordprocessingml.document",
                     "com.microsoft.word.doc", "org.oasis-open.opendocument.text"].compactMap { UTType($0) }
        types += extra
        types += ["md", "markdown", "docx", "doc", "odt"].compactMap { UTType(filenameExtension: $0) }
        return types
    }
}

/// Reads a script file and returns it as NotchCue script text: one paragraph per line,
/// with cue lines in [square brackets].
func scriptText(fromFileAt url: URL) throws -> String {
    let name = url.lastPathComponent
    let ext = url.pathExtension
    let text: String
    switch ScriptFormat.forExtension(ext) {
    case .plain?:
        text = try readPlainText(url)
    case .markdown?:
        text = markdownToScript(try readPlainText(url))
    case .richText(let type)?:
        guard let attributed = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else {
            throw ScriptError.unreadable(name)
        }
        text = cleanExtractedText(attributed.string)
    case .pdf?:
        guard let document = PDFDocument(url: url) else { throw ScriptError.unreadable(name) }
        text = reflowExtractedLines(cleanExtractedText(document.string ?? ""))
    case nil:
        // Unknown extension: fine if it's really text (keeps the old "any text file" behaviour).
        guard let data = FileManager.default.contents(atPath: url.path), !data.contains(0),
              let decoded = String(data: data, encoding: .utf8) else { throw ScriptError.unsupported(name) }
        text = decoded
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ScriptError.empty(name) }
    return text
}

func readPlainText(_ url: URL) throws -> String {
    guard let data = FileManager.default.contents(atPath: url.path) else { throw ScriptError.unreadable(url.path) }
    if let text = String(data: data, encoding: .utf8) { return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
    if let text = String(data: data, encoding: .utf16) { return text }
    if let text = String(data: data, encoding: .macOSRoman) { return text }
    throw ScriptError.unreadable(url.path)
}

/// Tidies text pulled out of rich documents: odd line separators, attachment markers,
/// non-breaking spaces and runs of blank lines.
func cleanExtractedText(_ text: String) -> String {
    var t = text.replacingOccurrences(of: "\r\n", with: "\n")
    for separator in ["\r", "\u{2028}", "\u{2029}", "\u{000C}"] { t = t.replacingOccurrences(of: separator, with: "\n") }
    t = t.replacingOccurrences(of: "\u{FFFC}", with: "")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
    let lines = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// PDFs break paragraphs into short lines. Joins lines back into paragraphs: a line is
/// kept separate when it ends a sentence, is blank, or is a [cue].
func reflowExtractedLines(_ text: String) -> String {
    var paragraphs: [String] = []
    var current = ""
    func flush() {
        if !current.isEmpty { paragraphs.append(current) }
        current = ""
    }
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { flush(); continue }
        if line.hasPrefix("[") { flush() }
        if current.isEmpty {
            current = line
        } else if current.hasSuffix("-"), current.dropLast().last?.isLetter == true, line.first?.isLowercase == true {
            current = String(current.dropLast()) + line   // a word split by a hyphen at the line end
        } else {
            current += " " + line
        }
        if let last = current.last, ".!?:]\"”’)".contains(last) { flush() }
    }
    flush()
    return paragraphs.joined(separator: "\n")
}

// MARK: Markdown

/// Turns Markdown into NotchCue script text.
///
/// - Headings become cue lines: `# Intro` -> `[Intro]`.
/// - Emphasis, inline code and link markup are stripped, keeping the words.
/// - Images, fenced code blocks, HTML comments and YAML front matter are left out.
/// - List and quote markers are removed; each list item is its own paragraph.
/// - Lines wrapped inside one paragraph are joined back together.
func markdownToScript(_ markdown: String) -> String {
    var source = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
    var lines = source.components(separatedBy: "\n")

    // YAML front matter: a block between --- lines at the very top.
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
       let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
        lines.removeSubrange(0...end)
    }

    // HTML comments, including ones that span lines. An unclosed comment hides the rest.
    var joined = lines.joined(separator: "\n")
    joined = joined.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    joined = joined.replacingOccurrences(of: "<!--[\\s\\S]*$", with: "", options: .regularExpression)
    lines = joined.components(separatedBy: "\n")

    var output: [String] = []
    var paragraph: [String] = []
    var fence: String?

    func flush() {
        let text = collapseSpaces(stripInlineMarkdown(paragraph.joined(separator: " ")))
        if !text.isEmpty { output.append(text) }
        paragraph = []
    }
    func addCue(_ text: String) {
        let cue = collapseSpaces(stripInlineMarkdown(text))
        if !cue.isEmpty { output.append("[\(cue)]") }
    }

    for raw in lines {
        var line = raw.trimmingCharacters(in: .whitespaces)

        // Fenced code blocks are skipped entirely.
        if let marker = fence {
            if line.hasPrefix(marker), line.allSatisfy({ $0 == marker.first || $0 == " " }) { fence = nil }
            continue
        }
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            flush()
            fence = String(line.prefix(while: { $0 == line.first }))
            continue
        }

        // Blockquote markers: "> text", "> > text".
        var quoted = false
        while line.hasPrefix(">") {
            quoted = true
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if quoted && paragraph.isEmpty == false && line.isEmpty { flush(); continue }

        if line.isEmpty { flush(); continue }

        // Setext headings: a line underlined with === or ---.
        if !paragraph.isEmpty, line.range(of: "^(=+|-+)$", options: .regularExpression) != nil {
            let heading = paragraph.joined(separator: " ")
            paragraph = []
            addCue(heading)
            continue
        }
        // Thematic breaks: ---, ***, ___
        if line.range(of: "^([-*_])( *\\1){2,}$", options: .regularExpression) != nil { flush(); continue }

        // ATX headings: # Title
        if let match = line.range(of: "^#{1,6}(\\s+|$)", options: .regularExpression) {
            flush()
            var heading = String(line[match.upperBound...])
            heading = heading.replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
            if heading.allSatisfy({ $0 == "#" }) { heading = "" }
            addCue(heading)
            continue
        }

        // A NotchCue cue line, [Like this], stays as it is.
        if line.range(of: "^\\[[^\\]]+\\]$", options: .regularExpression) != nil {
            flush()
            output.append(collapseSpaces(line))
            continue
        }
        // Link reference definitions: [id]: https://...
        if line.range(of: "^\\[[^\\]]+\\]:\\s*\\S+", options: .regularExpression) != nil { flush(); continue }

        // Tables: drop the |---|---| row, read the cells of the others.
        if line.contains("|"), line.range(of: "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)+\\|?$", options: .regularExpression) != nil { flush(); continue }
        if line.hasPrefix("|") {
            flush()
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            paragraph = [cells.joined(separator: ", ")]
            flush()
            continue
        }

        // List items: "- ", "* ", "+ ", "1. ", "1) ", with optional task boxes.
        if let match = line.range(of: "^([-*+]|\\d{1,9}[.)])\\s+", options: .regularExpression) {
            flush()
            line = String(line[match.upperBound...])
            line = line.replacingOccurrences(of: "^\\[[ xX]\\]\\s+", with: "", options: .regularExpression)
        }

        // Two trailing spaces or a backslash end a line early.
        let hardBreak = raw.hasSuffix("  ") || line.hasSuffix("\\")
        if line.hasSuffix("\\") { line.removeLast() }
        paragraph.append(line)
        if hardBreak { flush() }
    }
    flush()
    return output.joined(separator: "\n")
}

/// Removes inline Markdown: emphasis, code, links, images and HTML tags. Keeps the words.
func stripInlineMarkdown(_ input: String) -> String {
    // Hide backslash-escaped characters so they survive as literal text.
    var text = ""
    var chars = Array(input)
    var i = 0
    let escapable = Set("\\`*_{}[]()#+-.!<>~|=")
    while i < chars.count {
        if chars[i] == "\\", i + 1 < chars.count, escapable.contains(chars[i + 1]),
           let ascii = chars[i + 1].asciiValue, let scalar = Unicode.Scalar(0xE000 + UInt32(ascii)) {
            text.append(Character(scalar))
            i += 2
        } else {
            text.append(chars[i])
            i += 1
        }
    }
    chars = []

    let rules: [(String, String)] = [
        ("(`+)(.+?)\\1", "$2"),                                     // `code`
        ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),                          // ![image](url)
        ("!\\[[^\\]]*\\]\\[[^\\]]*\\]", ""),                        // ![image][ref]
        ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),                       // [text](url)
        ("\\[([^\\]]+)\\]\\[[^\\]]*\\]", "$1"),                     // [text][ref]
        ("<((?:https?|mailto):[^>\\s]+)>", "$1"),                   // <https://...>
        ("</?[A-Za-z][A-Za-z0-9-]*(\\s[^>]*)?/?>", ""),             // <b>, <br/>, </span>
        ("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1", "$2"),               // **bold**, __bold__
        ("~~(?=\\S)(.+?)(?<=\\S)~~", "$1"),                         // ~~struck~~
        ("==(?=\\S)(.+?)(?<=\\S)==", "$1"),                         // ==highlight==
        ("\\*(?=\\S)(.+?)(?<=\\S)\\*", "$1"),                       // *italic*
        ("(?<![A-Za-z0-9])_(?=\\S)(.+?)(?<=\\S)_(?![A-Za-z0-9])", "$1"), // _italic_, not snake_case
    ]
    for (pattern, template) in rules {
        text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    // Put escaped characters back.
    return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        (0xE000...0xE07F).contains(scalar.value) ? Unicode.Scalar(UInt8(scalar.value - 0xE000)) : scalar
    }))
}

func collapseSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

// MARK: Words and matching

/// Lowercase letters and digits only, so "Codex," and "codex" match.
func normalized(_ word: String) -> String {
    String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
}

/// A spoken word in the script and where it sits in the displayed text.
struct Token {
    let word: String
    let range: NSRange
}

func isCueLine(_ line: String) -> Bool { line.hasPrefix("[") && line.hasSuffix("]") }

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
        let isCue = isCueLine(line)
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

/// The script's spoken words, normalised, as the matcher sees them.
func scriptWords(_ text: String) -> [String] { styledText(text, fontSize: 20).1.map(\.word) }

/// Finds where in the script the speaker is, from the last few words heard.
///
/// Looks a little behind and well ahead of the current place, scores each spot by how
/// many of the recent words line up with the script there, and only jumps backwards
/// when the match is strong (you went back and said a line again).
/// Returns the index of the next word to be said.
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
