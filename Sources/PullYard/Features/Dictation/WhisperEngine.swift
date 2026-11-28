import Foundation
import Observation
@preconcurrency import WhisperKit

enum DictationLanguage: String, CaseIterable, Identifiable {
    case auto = ""
    case armenian = "hy"
    case russian = "ru"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Detect automatically"
        case .armenian: return "Armenian"
        case .russian: return "Russian"
        case .english: return "English"
        }
    }
}

enum DictationEngine: String, CaseIterable, Identifiable {
    case system
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "macOS dictation"
        case .whisper: return "Whisper on this Mac"
        }
    }
}

enum WhisperError: LocalizedError {
    case notDownloaded
    case empty

    var errorDescription: String? {
        switch self {
        case .notDownloaded: return "The Whisper model isn't downloaded on the Mac. Download it in PullYard Settings → Dictation."
        case .empty: return "No speech was recognized."
        }
    }
}

@Observable
@MainActor
final class WhisperEngine {
    enum ModelState: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    static let shared = WhisperEngine()
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let sizeLabel = "632 MB"
    static let engineKey = "dictation.engine"
    static let languageKey = "dictation.language"
    private static let folderKey = "dictation.whisperFolder"

    private(set) var state: ModelState = .missing
    private(set) var transcribing = false
    @ObservationIgnored private var kit: WhisperKit?
    @ObservationIgnored private var loading: Task<WhisperKit, Error>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    private init() {
        if let folder = modelFolder { state = FileManager.default.fileExists(atPath: folder.path) ? .ready : .missing }
    }

    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullYard/Whisper", isDirectory: true)
    }

    var engine: DictationEngine {
        DictationEngine(rawValue: UserDefaults.standard.string(forKey: Self.engineKey) ?? "") ?? .system
    }

    var language: DictationLanguage {
        DictationLanguage(rawValue: UserDefaults.standard.string(forKey: Self.languageKey) ?? "") ?? .auto
    }

    var isReady: Bool { state == .ready }

    private var modelFolder: URL? {
        UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func download() {
        guard downloadTask == nil, state != .ready else { return }
        state = .downloading(0)
        downloadTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: Self.base, withIntermediateDirectories: true)
                let folder = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.base) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = WhisperEngine.shared.state { WhisperEngine.shared.state = .downloading(fraction) }
                    }
                }
                UserDefaults.standard.set(folder.path, forKey: Self.folderKey)
                self?.state = .ready
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .missing
    }

    func remove() async {
        await kit?.unloadModels()
        kit = nil
        loading = nil
        UserDefaults.standard.removeObject(forKey: Self.folderKey)
        try? FileManager.default.removeItem(at: Self.base)
        state = .missing
    }

    func transcribe(file: URL, language: DictationLanguage? = nil) async throws -> String {
        let kit = try await loaded()
        transcribing = true
        defer { transcribing = false }
        let results = try await kit.transcribe(audioPath: file.path, decodeOptions: options(language ?? self.language))
        return try Self.text(results)
    }

    func transcribe(samples: [Float], language: DictationLanguage? = nil) async throws -> String {
        let kit = try await loaded()
        transcribing = true
        defer { transcribing = false }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options(language ?? self.language))
        return try Self.text(results)
    }

    func prewarm() {
        guard isReady, kit == nil else { return }
        Task { _ = try? await loaded() }
    }

    private func options(_ language: DictationLanguage) -> DecodingOptions {
        language == .auto
            ? DecodingOptions(task: .transcribe, language: nil, usePrefillPrompt: true, detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: true)
            : DecodingOptions(task: .transcribe, language: language.rawValue, usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
    }

    private static func text(_ results: [TranscriptionResult]) throws -> String {
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WhisperError.empty }
        return text
    }

    private func loaded() async throws -> WhisperKit {
        if let kit { return kit }
        guard isReady, let folder = modelFolder else { throw WhisperError.notDownloaded }
        if let loading { return try await loading.value }
        let task = Task {
            try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path,
                computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU),
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: true,
                download: false
            ))
        }
        loading = task
        do {
            let kit = try await task.value
            self.kit = kit
            loading = nil
            return kit
        } catch {
            loading = nil
            throw error
        }
    }
}
