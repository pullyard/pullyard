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
            HStack(spacing: 6) {
                Image(systemName: app.toastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(app.toastIsError ? Color.syRed : Color.syGreen)
                Text(text).foregroundStyle(Color.syText).lineLimit(app.toastIsError ? 3 : 1)
            }
            .frame(maxWidth: 520)
            .font(.syCallout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).stroke(app.toastIsError ? Color.syRed.opacity(Tint.strong) : Color.syLineStrong))
            .elevation(.floating)
            .padding(.bottom, bottomInset ?? (app.clipboardRoute == nil && app.rateLimitedUntil == nil ? 16 : 0))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(text)
        }
    }
}
