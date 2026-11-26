import AVFoundation
import Speech
import SwiftUI

enum DictationPrefs {
    static let engine = "dictation.engine"
    static let language = "dictation.language"

    enum Engine: String, CaseIterable, Identifiable {
        case apple
        case mac
        var id: String { rawValue }
        var title: String { self == .apple ? L("iPhone (Apple)") : L("Whisper on Mac") }
    }

    enum Language: String, CaseIterable, Identifiable {
        case auto = ""
        case armenian = "hy"
        case russian = "ru"
        case english = "en"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return L("Detect automatically")
            case .armenian: return L("Armenian")
            case .russian: return L("Russian")
            case .english: return L("English")
            }
        }
        var locale: Locale {
            switch self {
            case .auto: return Locale.current
            case .armenian: return Locale(identifier: "hy-AM")
            case .russian: return Locale(identifier: "ru-RU")
            case .english: return Locale(identifier: "en-US")
            }
        }
    }

    static var currentEngine: Engine { Engine(rawValue: UserDefaults.standard.string(forKey: engine) ?? "") ?? .apple }
    static var currentLanguage: Language { Language(rawValue: UserDefaults.standard.string(forKey: language) ?? "") ?? .auto }
}

@MainActor
final class SpeechDictation: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var recordingURL: URL?

    func toggle() {
        guard !isTranscribing else { return }
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        error = nil
        let language = DictationPrefs.currentLanguage
        if DictationPrefs.currentEngine == .mac, LinkClient.shared.isConnected {
            await startRecording()
            return
        }
        if language == .armenian {
            error = DictationPrefs.currentEngine == .mac
                ? L("Connect to PullYard on your Mac to dictate in Armenian.")
                : L("Armenian dictation works through Whisper on your Mac. Choose it in Settings → Mac & agents.")
            return
        }
        guard await Self.authorize() else {
            error = L("Allow microphone and speech recognition for PullYard in Settings to dictate.")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: language.locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
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
        if recorder != nil {
            stopRecording()
            return
        }
        request?.endAudio()
        finish()
    }

    private func startRecording() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            error = L("Allow microphone access for PullYard in Settings to dictate.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: 300) else { throw NSError(domain: "PullYard", code: 1) }
            self.recorder = recorder
            recordingURL = url
            transcript = ""
            isRecording = true
            meter = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let power = recorder.averagePower(forChannel: 0)
                    self.level = CGFloat(max(0, min(1, (power + 50) / 45)))
                }
            }
        } catch {
            self.error = L("Couldn't start recording.")
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func stopRecording() {
        meter?.invalidate()
        meter = nil
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let url = recordingURL else { return }
        recordingURL = nil
        guard duration > 0.4 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        isTranscribing = true
        let language = DictationPrefs.currentLanguage
        Task {
            defer {
                try? FileManager.default.removeItem(at: url)
                isTranscribing = false
            }
            do {
                let data = try Data(contentsOf: url)
                transcript = try await LinkClient.shared.transcribe(data, mediaType: "audio/m4a", language: language == .auto ? nil : language.rawValue)
            } catch {
                self.error = error.localizedDescription
            }
        }
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
                if dictation.isTranscribing {
                    ProgressView()
                        .frame(width: 34, height: 34)
                        .background(MobileTheme.ink.opacity(0.06), in: Circle())
                } else if dictation.isRecording {
                    Circle()
                        .fill(MobileTheme.red.opacity(0.22))
                        .frame(width: 34 + 18 * dictation.level, height: 34 + 18 * dictation.level)
                        .animation(.easeOut(duration: 0.12), value: dictation.level)
                }
                if !dictation.isTranscribing {
                    Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: dictation.isRecording ? 13 : 16, weight: .semibold))
                        .foregroundStyle(dictation.isRecording ? .white : MobileTheme.muted)
                        .frame(width: 34, height: 34)
                        .background(dictation.isRecording ? MobileTheme.red : MobileTheme.ink.opacity(0.06), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.pyPlain)
        .accessibilityLabel(dictation.isTranscribing ? "Transcribing" : dictation.isRecording ? "Stop dictation" : "Dictate")
    }
}
