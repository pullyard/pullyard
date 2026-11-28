import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechDictation: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: SpeechDictation.historyLength)
    @Published private(set) var startedAt = Date()
    static let historyLength = 36
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
                Task { @MainActor in self?.push(level) }
            }
            engine.prepare()
            try engine.start()
            self.request = request
            transcript = ""
            startedAt = Date()
            levels = Array(repeating: 0, count: Self.historyLength)
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

    private func push(_ value: CGFloat) {
        guard isRecording else { return }
        level = value
        levels = Array((levels + [value]).suffix(Self.historyLength))
    }

    func stop() {
        request?.endAudio()
        finish()
    }

    func discard() {
        task?.cancel()
        task = nil
        transcript = ""
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
        let value = Double(sqrt(sum / Float(buffer.frameLength)))
        let db = 20 * log10(max(value, 1e-6))
        return CGFloat(min(1, max(0, (db + 55) / 45)))
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

struct DictationLevelStrip: View {
    @ObservedObject var dictation: SpeechDictation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(MobileTheme.red).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(dictation.level > 0.25 ? "Listening…" : "Speak now")
                    .mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.ink)
                Text(timerInterval: dictation.startedAt...Date.distantFuture, countsDown: false)
                    .mobileFont(size: 11).monospacedDigit().foregroundStyle(MobileTheme.muted)
            }
            .frame(width: 78, alignment: .leading)
            GeometryReader { geo in
                let count = max(dictation.levels.count, 1)
                let gap: CGFloat = 2.5
                let width = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                HStack(alignment: .center, spacing: gap) {
                    ForEach(Array(dictation.levels.enumerated()), id: \.offset) { index, value in
                        Capsule()
                            .fill(LinearGradient(colors: [MobileTheme.violet, MobileTheme.sky, MobileTheme.coral], startPoint: .bottom, endPoint: .top))
                            .frame(width: width, height: max(3, geo.size.height * value))
                            .opacity(0.35 + 0.65 * Double(index) / Double(count))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.linear(duration: 0.06), value: dictation.levels)
            }
            .frame(height: 26)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MobileTheme.muted)
                    .frame(width: 30, height: 30)
                    .background(MobileTheme.ink.opacity(0.07), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.pyPlain)
            .accessibilityLabel("Cancel dictation")
        }
        .padding(.leading, 12).padding(.trailing, 2).padding(.vertical, 2)
        .background(MobileTheme.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording your voice")
    }
}
