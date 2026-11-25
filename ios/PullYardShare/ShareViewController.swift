import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareCard(model: model, open: { [weak self] in self?.openInApp() }, cancel: { [weak self] in self?.close() }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await loadInput() }
    }

    private func loadInput() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                model.setLink(url); return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = ShareModel.firstURL(in: text) {
                model.setLink(url); return
            }
        }
        model.setLink(nil)
    }

    private func openInApp() {
        guard let link = model.link else { return }
        PendingLink.set(link)
        _ = openHostApp(URL(string: "pullyard://pending")!)
        model.saved = true
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            close()
        }
    }

    private func openHostApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let function = unsafeBitCast(application.method(for: selector), to: OpenFunction.self)
                function(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Kind { case pull, issue, project, other }
    @Published var link: URL?
    @Published var kind: Kind = .other
    @Published var label = ""
    @Published var loaded = false
    @Published var saved = false

    func setLink(_ url: URL?) {
        link = url
        loaded = true
        guard let url, let host = url.host?.lowercased(), host.hasSuffix("github.com") else { kind = .other; return }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 4, parts[2] == "pull" { kind = .pull; label = "\(parts[0])/\(parts[1]) #\(parts[3])" }
        else if parts.count >= 4, parts[2] == "issues" { kind = .issue; label = "\(parts[0])/\(parts[1]) #\(parts[3])" }
        else if parts.count >= 2 { kind = .project; label = "\(parts[0])/\(parts[1])" }
        else { kind = .other }
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }
}

private struct ShareCard: View {
    @ObservedObject var model: ShareModel
    let open: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "sailboat.fill").foregroundStyle(Color(red: 0.94, green: 0.46, blue: 0.39))
                    Text("PullYard").font(.headline)
                    Spacer()
                    Button("Cancel", action: cancel)
                }
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.kind == .other {
                    Text("Share a GitHub pull request, issue or repository link to open it in PullYard.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: model.kind == .pull ? "arrow.triangle.pull" : model.kind == .issue ? "smallcircle.filled.circle" : "folder.fill")
                            .font(.title3)
                            .foregroundStyle(Color(red: 0.36, green: 0.72, blue: 0.93))
                            .frame(width: 44, height: 44)
                            .background(Color(red: 0.36, green: 0.72, blue: 0.93).opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.kind == .pull ? "Pull request" : model.kind == .issue ? "Issue" : "Project").font(.caption).foregroundStyle(.secondary)
                            Text(model.label).font(.body.weight(.semibold)).lineLimit(1)
                        }
                    }
                    Button(action: open) {
                        Label(model.saved ? "Opening PullYard…" : "Open in PullYard", systemImage: model.saved ? "checkmark" : "arrow.up.forward.app")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color(red: 0.11, green: 0.44, blue: 0.65), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.saved)
                    if model.saved {
                        Text("If PullYard doesn't open by itself, open it from the Home Screen — the link will be waiting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(12)
        }
    }
}
