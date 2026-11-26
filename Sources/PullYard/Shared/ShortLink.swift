import SwiftUI

enum ShortLink {
    static func make(_ ref: ItemRef) -> String {
        "\(ref.repo.owner)/\(ref.repo.name)#\(ref.number)"
    }

    static func make(url: String) -> String? {
        ref(url: url).map(make)
    }

    static func ref(url: String) -> ItemRef? {
        switch GitHubURL.parse(url, allowShort: false) {
        case .pr(let ref), .issue(let ref): return ref
        default: return nil
        }
    }

    static func ref(route: Route?) -> ItemRef? {
        switch route {
        case .pr(let ref), .issue(let ref): return ref
        default: return nil
        }
    }
}

struct ShortLinkButton: View {
    let ref: ItemRef
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { app.copyShortLink(ref) } label: {
            Image(systemName: "link").font(.syCallout.weight(.semibold)).foregroundStyle(Color.syMuted)
        }
        .buttonStyle(.borderless)
        .help("Copy short link \(ShortLink.make(ref)) (⇧⌘C)")
        .accessibilityLabel("Copy short link")
    }
}

struct ToastBanner: View {
    var bottomInset: CGFloat?
    @Environment(AppModel.self) private var app

    var body: some View {
        if let text = app.toast {
            HStack(spacing: 8) {
                ToastGlyph(kind: app.toastKind, serial: app.toastSerial)
                Text(text).foregroundStyle(Color.syText).lineLimit(app.toastIsError ? 6 : 2)
                if let action = app.toastAction {
                    Rectangle().fill(Color.syLineStrong).frame(width: 1, height: 14)
                    Button(action.title) { app.runToastAction() }
                        .buttonStyle(.borderless)
                        .font(.syCallout.weight(.semibold))
                        .foregroundStyle(Color.syLink)
                }
                if app.toastIsError {
                    Button {
                        copyToPasteboard(text, announce: false)
                        app.dismissToast()
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy the message and dismiss")
                        .accessibilityLabel("Copy the message and dismiss")
                }
                if app.toastIsError || app.toastAction != nil {
                    Button { app.dismissToast() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss")
                }
            }
            .frame(maxWidth: 560)
            .font(.syCallout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .pyGlass(in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous), tint: app.toastIsError ? Color.syRed.opacity(0.12) : nil)
            .elevation(.floating)
            .padding(.bottom, bottomInset ?? (app.clipboardRoute == nil && app.rateLimitedUntil == nil ? 16 : 0))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(app.toastSerial)
        }
    }
}

private struct ToastGlyph: View {
    let kind: ToastKind
    let serial: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sailed = false

    var body: some View {
        switch kind {
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.syRed)
        case .info:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.syGreen)
        case .approved:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.syGreen)
                .scaleEffect(sailed || reduceMotion ? 1 : 1.6)
                .opacity(sailed || reduceMotion ? 1 : 0)
                .onAppear { withAnimation(Motion.bouncy) { sailed = true } }
        case .merged:
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [Color.syWake.opacity(0), Color.syWake], startPoint: .leading, endPoint: .trailing))
                    .frame(width: sailed ? 18 : 0, height: 2)
                    .offset(y: 7)
                    .opacity(sailed ? 0 : 1)
                PullYardLogoMark(progress: 1, size: 26)
                    .offset(x: sailed || reduceMotion ? 0 : -16)
            }
            .frame(width: 30, height: 18, alignment: .trailing)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Motion.Dur.story)) { sailed = true }
            }
        }
    }
}
