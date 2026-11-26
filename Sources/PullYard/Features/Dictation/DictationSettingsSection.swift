import SwiftUI

struct DictationSettingsSection: View {
    @AppStorage(WhisperEngine.engineKey) private var engine: DictationEngine = .system
    @AppStorage(WhisperEngine.languageKey) private var language: DictationLanguage = .auto
    @State private var confirmRemove = false
    private var whisper: WhisperEngine { WhisperEngine.shared }

    var body: some View {
        Section {
            Picker("Dictation", selection: $engine) {
                ForEach(DictationEngine.allCases) { Text($0.title).tag($0) }
            }
            Picker("Language", selection: $language) {
                ForEach(DictationLanguage.allCases) { Text($0.title).tag($0) }
            }
            .disabled(engine != .whisper)
            modelRow
            Text("Whisper runs on this Mac, so speech never leaves it. It understands Armenian, Russian and English. PullYard on iPhone sends dictation here too while it is connected.")
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            SettingsHeader(title: "Dictation", icon: "mic", color: .syViolet)
        }
        .confirmationDialog("Remove the Whisper model?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await whisper.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(WhisperEngine.sizeLabel). Dictation falls back to macOS dictation until you download it again.")
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        HStack(spacing: 10) {
            switch whisper.state {
            case .missing:
                Text("Whisper model not downloaded").foregroundStyle(Color.syMuted)
                Spacer()
                Button("Download (\(WhisperEngine.sizeLabel))") { whisper.download() }
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text(progress > 0 ? "\(Int(progress * 100))%" : "Starting…")
                    .font(.syCaption.monospacedDigit())
                    .foregroundStyle(Color.syMuted)
                Spacer()
                Button("Cancel") { whisper.cancelDownload() }
            case .ready:
                Label("Whisper model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.syGreen)
                Spacer()
                Button("Remove…") { confirmRemove = true }
            case .failed(let message):
                Text(message)
                    .font(.syCaption)
                    .foregroundStyle(Color.syRed)
                    .lineLimit(2)
                Spacer()
                Button("Try Again") { whisper.download() }
            }
        }
    }
}
