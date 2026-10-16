# Script format

NotchCue shows your script one paragraph per line, in big text, and listens for the words you read. This page covers how it reads each kind of file.

## Plain text (.txt)

- Each line is a paragraph. Blank lines are ignored, so you can space your script out however you like.
- A line wrapped in square brackets is a **cue**: it shows in small grey capitals and isn't read out. Use cues for section names, stage directions or reminders:

  ```text
  [Hook]
  I asked a Big Four auditor what AI they use.
  [Pause. Look at the camera.]
  ```

- Everything else is read out. Punctuation and capitals don't matter to voice following, so "Codex," and "codex" match.
- A file with an unknown extension is still read if it's plain text. Text piped in with `notchcue -`, passed with `--text` or pasted with ⌘V is treated as plain text.

## Markdown (.md, .markdown)

Markdown is turned into the plain-text format above:

| In your file | On the panel |
|---|---|
| `# Heading` (any level, `#` to `######`) | A cue: `[Heading]` |
| A heading underlined with `===` or `---` | A cue |
| `[Like this]` on its own line | A cue, as in plain text |
| `**bold**`, `__bold__`, `*italic*`, `_italic_`, `~~struck~~`, `==highlight==` | The words, without the markers |
| `` `code` `` | The text inside the backticks |
| `[link text](https://...)` or `[link text][ref]` | Just the link text |
| `<https://example.com>` | The address, without the angle brackets |
| `![image](picture.png)` | Nothing: images are dropped |
| `- item`, `* item`, `+ item`, `1. item`, `1) item`, `- [x] task` | Each item is its own paragraph, without the marker |
| `> quote` | The quote, without the `>` |
| Lines wrapped inside one paragraph | Joined back into one paragraph |
| A line ending in two spaces or `\` | Ends the paragraph there |
| Tables | Each row becomes a line, cells separated by commas; the `---` row is dropped |
| Fenced code blocks (```` ``` ```` or `~~~`) | Left out |
| `<!-- comments -->`, even across lines | Left out |
| YAML front matter (`---` block at the very top) | Left out |
| `---`, `***`, `___` on their own line | Left out |
| Link definitions (`[ref]: https://...`) | Left out |
| Inline HTML tags like `<b>` or `<br>` | The tags are removed, the text stays |
| `\*` and other backslash escapes | The character itself |

Underscores inside words (`snake_case`) and lone asterisks (`2 * 3`) are kept.

### Example

This Markdown:

```markdown
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
```

Shows as:

```text
[Hook]
I asked an auditor what AI they use. A chatbot. That was the whole answer.
[The gap]
Most firms buy a licence and stop.
The rest build workflows.
The tools are not the problem.
```

## Word, RTF, OpenDocument and HTML

`.docx`, `.doc`, `.rtf`, `.rtfd`, `.odt`, `.html`, `.htm` and `.webarchive` files are read with macOS's own document reader, and only the text is kept: fonts, colours and images are dropped. Each paragraph in the document becomes a paragraph on the panel. A paragraph in square brackets is still a cue.

## PDF

NotchCue takes the text out of the PDF with PDFKit. PDFs store text as short lines, so NotchCue joins lines back into paragraphs: a new paragraph starts after a blank line, after a line that ends a sentence (`.`, `!`, `?`, `:`, or a closing quote or bracket), and at a line that starts with `[`. Words split with a hyphen at the end of a line are joined back up.

Scanned PDFs (pictures of text) have no text in them, so NotchCue says there's no text to show.

## Files NotchCue can't read

Images, Pages, Keynote and other binary files show a message in the panel: "NotchCue can't read *file*. Use a .txt, .md, .rtf, .docx, .doc, .odt, .html or .pdf file." For a Pages document, export it as Word or PDF first (File → Export To).
