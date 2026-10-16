// NotchCue: a macOS teleprompter that hangs down from the notch, right under the camera.
//
// Built into an app bundle by the `notchcue` script (or `make install`). The bundle is
// needed so macOS can ask for microphone and speech recognition permission.
//
// MIT licence. https://github.com/LycanaAI/notchcue

import AppKit

let launchArguments = Array(CommandLine.arguments.dropFirst())
if launchArguments.contains("--self-test") { exit(runSelfTests() ? 0 : 1) }

// Don't let AppKit treat command-line arguments as files to open; we read them ourselves.
UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])

let launchOptions = parseOptions(launchArguments, settings: Settings.load())

var launchScript: String?
if let text = launchOptions.text {
    launchScript = text
} else if let file = launchOptions.file {
    do {
        launchScript = try scriptText(fromFileAt: URL(fileURLWithPath: file))
    } catch {
        fail(error.localizedDescription)
    }
} else if launchOptions.sample {
    launchScript = sampleText
}
if let launchScript, launchScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("There's no text to show") }
if launchOptions.validateOnly { exit(0) }
debugLogging = launchOptions.debug

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let prompter = Prompter(options: launchOptions, text: launchScript)
app.delegate = prompter
app.run()
