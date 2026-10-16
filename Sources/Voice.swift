// Listening to the microphone with Apple's speech recognition, and the debug log.

import AVFoundation
import Foundation
import QuartzCore
import Speech

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
