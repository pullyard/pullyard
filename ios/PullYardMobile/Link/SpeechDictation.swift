import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechDictation: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        error = nil
        guard await Self.authorize() else {
            error = L("Allow microphone and speech recognition for PullYard in Settings to dictate.")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            error = L("Dictation isn't available right now.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            self.request = request
            transcript = ""
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.finish() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            finish()
        }
    }

    func stop() {
        request?.endAudio()
        finish()
    }

    private func finish() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.finish()
        task = nil
        request = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
        let value = sqrt(sum / Float(buffer.frameLength))
        return CGFloat(min(1, value * 12))
    }
}

struct DictationButton: View {
    @ObservedObject var dictation: SpeechDictation

    var body: some View {
        Button { dictation.toggle() } label: {
            ZStack {
                if dictation.isRecording {
                    Circle()
                        .fill(MobileTheme.red.opacity(0.22))
                        .frame(width: 34 + 18 * dictation.level, height: 34 + 18 * dictation.level)
                        .animation(.easeOut(duration: 0.12), value: dictation.level)
                }
                Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: dictation.isRecording ? 13 : 16, weight: .semibold))
                    .foregroundStyle(dictation.isRecording ? .white : MobileTheme.muted)
                    .frame(width: 34, height: 34)
                    .background(dictation.isRecording ? MobileTheme.red : MobileTheme.ink.opacity(0.06), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.pyPlain)
        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
    }
}
