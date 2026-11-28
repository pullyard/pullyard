import SwiftUI

struct DictationWave: View {
    let level: Double
    var active = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let mid = size.height / 2
                let loud = active ? max(0.08, min(1, level)) : 0.02
                let layers: [(Color, Double, Double, Double)] = [
                    (.syViolet, 0.55, 1.7, 0.0),
                    (.sySky, 0.8, 2.3, 1.3),
                    (.syCoral, 1.0, 3.1, 2.6)
                ]
                for (color, weight, speed, offset) in layers {
                    var path = Path()
                    let steps = max(Int(size.width / 2), 2)
                    for step in 0...steps {
                        let progress: Double = Double(step) / Double(steps)
                        let x: Double = size.width * progress
                        let envelope: Double = sin(progress * Double.pi)
                        let cycles: Double = 2 * (1.6 + weight)
                        let angle: Double = progress * Double.pi * cycles + time * speed + offset
                        let height: Double = (mid - 2) * loud * weight
                        let y: Double = mid + sin(angle) * envelope * height
                        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    canvas.stroke(path, with: .color(color.opacity(active ? 0.9 : 0.4)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct DictationBar: View {
    let recorder: WhisperRecorder
    let onStop: () -> Void
    let onCancel: () -> Void
    @State private var started = Date()

    var body: some View {
        let recording = recorder.phase == .recording
        HStack(spacing: 10) {
            Circle()
                .fill(recording ? Color.syRed : Color.syMuted)
                .frame(width: 8, height: 8)
                .opacity(recording ? 1 : 0.6)
            Group {
                if recording {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                } else {
                    Text("Transcribing…")
                }
            }
            .font(.syCaption.weight(.medium))
            .foregroundStyle(Color.syMuted)
            .frame(width: 84, alignment: .leading)
            DictationWave(level: recorder.level, active: recording)
                .frame(height: 26)
                .frame(maxWidth: .infinity)
            if recording {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.syMuted)
                    .keyboardShortcut(.cancelAction)
                Button(action: onStop) {
                    Label("Done", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .pyGlassButton(prominent: true)
                .help("Stop and transcribe")
            } else {
                PYLoader(size: 12, label: "Transcribing")
            }
        }
        .font(.syCaption)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.syText.opacity(0.05)))
        .onAppear { started = Date() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recording ? "Recording your voice" : "Transcribing")
    }
}
