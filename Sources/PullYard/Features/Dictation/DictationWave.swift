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

struct DictationLevels: View {
    let levels: [Double]
    var active = true

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let gap: CGFloat = 3
            let width = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, value in
                    let age = Double(index) / Double(count)
                    Capsule()
                        .fill(LinearGradient(colors: [.syViolet, .sySky, .syCoral], startPoint: .bottom, endPoint: .top))
                        .frame(width: width, height: max(3, geo.size.height * (active ? value : 0.06)))
                        .opacity(active ? 0.35 + 0.65 * age : 0.4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: levels)
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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.syRed.opacity(recording ? 0.18 : 0))
                    .frame(width: 30, height: 30)
                    .scaleEffect(recording ? 1 + recorder.level * 0.55 : 1)
                    .animation(.easeOut(duration: 0.12), value: recorder.level)
                Image(systemName: recording ? "mic.fill" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(recording ? Color.syRed : Color.syMuted)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(recording ? (recorder.level > 0.25 ? "Listening…" : "Speak now") : "Transcribing…")
                    .font(.syCallout.weight(.semibold))
                    .foregroundStyle(Color.syText)
                Group {
                    if recording {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false).monospacedDigit()
                    } else {
                        Text("Turning speech into text")
                    }
                }
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
            }
            .frame(width: 110, alignment: .leading)
            DictationLevels(levels: recorder.levels, active: recording)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
            if recording {
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                }
                .pyGlassButton()
                .keyboardShortcut(.cancelAction)
                    .help("Discard the recording (Esc)")
                Button(action: onStop) {
                    Label("Done", systemImage: "return")
                        .labelStyle(.titleAndIcon)
                }
                .pyGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .help("Stop and transcribe (↩)")
            } else {
                PYLoader(size: 14, label: "Transcribing")
            }
        }
        .font(.syCaption)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.syRed.opacity(recording ? 0.06 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(recording ? Color.syRed.opacity(0.25) : Color.syLine))
        .onAppear { started = Date() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recording ? "Recording your voice" : "Transcribing")
    }
}
