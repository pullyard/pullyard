import AppKit
import SwiftUI

struct MonoOutputText: View {
    let text: String
    var color: NSColor = .syText
    var size: CGFloat = 11.5
    var maxHeight: CGFloat = 220

    var body: some View {
        let fontSize = TextZoom.shared.size(size)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lines = max(1, text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } })
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let natural = CGFloat(lines) * lineHeight + MonoOutputHost.inset * 2
        MonoOutputHost(text: text, color: color, font: font)
            .frame(height: min(natural, maxHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.syText.opacity(0.045)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.syLine))
    }
}

private struct MonoOutputHost: NSViewRepresentable {
    static let inset: CGFloat = 8
    let text: String
    let color: NSColor
    let font: NSFont

    func makeNSView(context: Context) -> PassthroughScrollView {
        let scroll = PassthroughScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.autoresizingMask = []
        scroll.documentView = tv
        apply(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: PassthroughScrollView, context: Context) {
        apply(to: scroll)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassthroughScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func apply(to scroll: PassthroughScrollView) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        guard scroll.shownText != text || scroll.shownFont != font || scroll.shownColor != color else { return }
        scroll.shownText = text
        scroll.shownFont = font
        scroll.shownColor = color
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        if let container = tv.textContainer, let layout = tv.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            tv.setFrameSize(NSSize(width: max(used.width + Self.inset * 2, scroll.contentSize.width), height: max(used.height + Self.inset * 2, scroll.contentSize.height)))
        }
    }
}

final class PassthroughScrollView: NSScrollView {
    var shownText: String?
    var shownFont: NSFont?
    var shownColor: NSColor?
    private var routeToParent = false

    override func scrollWheel(with event: NSEvent) {
        let beginning = event.phase == .began || (event.phase == [] && event.momentumPhase == [])
        if beginning {
            routeToParent = shouldPassToParent(event)
        }
        if routeToParent {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func shouldPassToParent(_ event: NSEvent) -> Bool {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard abs(dy) >= abs(dx) else { return false }
        guard let doc = documentView else { return true }
        let clip = contentView.bounds
        if doc.frame.height <= clip.height + 1 { return true }
        if dy > 0 { return clip.minY <= 0.5 }
        if dy < 0 { return clip.maxY >= doc.frame.height - 0.5 }
        return false
    }
}
