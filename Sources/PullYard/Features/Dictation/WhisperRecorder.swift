import AVFoundation
import Observation

@Observable
@MainActor
final class WhisperRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Double = 0
    private(set) var levels: [Double] = Array(repeating: 0, count: WhisperRecorder.historyLength)
    static let historyLength = 48
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let buffer = SampleBuffer()

    static let sampleRate: Double = 16_000

    func start() async throws {
        guard phase == .idle else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw NSError(domain: "PullYard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access for PullYard in System Settings → Privacy & Security → Microphone."])
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "PullYard", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone format isn't supported."])
        }
        buffer.reset()
        let sink = buffer
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcm, _ in
            let ratio = Self.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return pcm
            }
            guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            sink.append(samples)
            let chunks = Self.loudness(samples, chunk: 800)
            Task { @MainActor in self?.push(chunks) }
        }
        engine.prepare()
        try engine.start()
        phase = .recording
    }

    private func push(_ chunks: [Double]) {
        guard phase == .recording, !chunks.isEmpty else { return }
        levels = Array((levels + chunks).suffix(Self.historyLength))
        level = chunks.last ?? 0
    }

    // Speech sits roughly between -55 dB (quiet room) and -10 dB (close and loud); map that range to 0…1.
    nonisolated static func loudness(_ samples: [Float], chunk: Int) -> [Double] {
        stride(from: 0, to: samples.count, by: chunk).map { start in
            let slice = samples[start..<min(start + chunk, samples.count)]
            var sum: Float = 0
            for s in slice { sum += s * s }
            let rms = Double(sqrt(sum / Float(max(slice.count, 1))))
            let db = 20 * log10(max(rms, 1e-6))
            return min(1, max(0, (db + 55) / 45))
        }
    }

    func stop() -> [Float] {
        guard phase == .recording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        level = 0
        levels = Array(repeating: 0, count: Self.historyLength)
        phase = .idle
        return buffer.take()
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count > Int(Self.sampleRate * 0.3) else { throw WhisperError.empty }
        phase = .transcribing
        defer { phase = .idle }
        return try await WhisperEngine.shared.transcribe(samples: samples)
    }

    func cancel() {
        _ = stop()
    }
}

final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() {
        lock.lock(); samples = []; lock.unlock()
    }

    func append(_ more: [Float]) {
        lock.lock(); samples.append(contentsOf: more); lock.unlock()
    }

    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }
}
