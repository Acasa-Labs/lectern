import AppKit

/// Xcode-style minimap: the whole file in tiny coloured bars, with a box for the visible part.
/// Click or drag to scroll.
final class MinimapView: NSView {
    static let width: CGFloat = 110
    /// The view's width: the miniature plus a little margin.
    static let viewWidth: CGFloat = width + 8
    private static let lineHeight: CGFloat = 2
    private static let charWidth: CGFloat = 1.2
    private static let maxLines = 20_000

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var image: CGImage?
    private var lineCount = 0
    private var pendingRebuild: DispatchWorkItem?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        // Views don't clip by default since macOS 14; the scrolled miniature would spill over the bars above.
        clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification,
                                               object: textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    @objc private func redraw() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    /// Re-renders the miniature, a moment after the text and its colours settle.
    func scheduleRebuild() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func rebuild() {
        guard let storage = textView?.textStorage else { return }
        let ns = storage.string as NSString
        let scale = window?.backingScaleFactor ?? 2
        let columns = Int(Self.width / Self.charWidth)

        // Line starts, capped so huge files stay quick.
        var starts = [0]
        var search = 0
        while search < ns.length, starts.count < Self.maxLines {
            let found = ns.range(of: "\n", options: .literal, range: NSRange(location: search, length: ns.length - search))
            guard found.location != NSNotFound else { break }
            starts.append(found.location + 1)
            search = found.location + 1
        }
        lineCount = starts.count
        let height = CGFloat(lineCount) * Self.lineHeight
        guard let context = CGContext(data: nil, width: Int(Self.width * scale), height: max(1, Int(height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        // Draw top-down like the text.
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)

        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] - 1 : ns.length
                guard end > start else { continue }
                let y = CGFloat(index) * Self.lineHeight
                var column = 0
                storage.enumerateAttribute(.foregroundColor, in: NSRange(location: start, length: end - start)) { value, range, stop in
                    let color = ((value as? NSColor) ?? .textColor).withAlphaComponent(0.75).cgColor
                    context.setFillColor(color)
                    // One bar per run of non-space characters.
                    var runStart: Int?
                    for offset in 0...range.length {
                        let character: unichar = offset < range.length ? ns.character(at: range.location + offset) : 0x20
                        let isSpace = character == 0x20 || character == 0x09
                        if isSpace, let begin = runStart {
                            context.fill(CGRect(x: CGFloat(begin) * Self.charWidth, y: y,
                                                width: CGFloat(column - begin) * Self.charWidth, height: Self.lineHeight * 0.7))
                            runStart = nil
                        } else if !isSpace, runStart == nil {
                            runStart = column
                        }
                        if offset < range.length { column += character == 0x09 ? 4 : 1 }
                        if column >= columns { stop.pointee = true; break }
                    }
                }
            }
        }
        image = context.makeImage()
        needsDisplay = true
    }

    // MARK: Drawing and scrolling

    private struct Geometry {
        let mapHeight: CGFloat      // whole miniature
        let offset: CGFloat         // how far the miniature is scrolled
        let viewport: CGRect        // the visible part of the text, in minimap coordinates
    }

    /// Long files scroll the miniature too, in step with the editor, like VS Code and Xcode.
    private func geometry() -> Geometry? {
        guard let textView, let scrollView, lineCount > 0 else { return nil }
        let mapHeight = CGFloat(lineCount) * Self.lineHeight
        let contentHeight = max(textView.frame.height, 1)
        let visible = scrollView.contentView.bounds
        let maxScroll = max(contentHeight - visible.height, 1)
        let fraction = min(max(visible.minY / maxScroll, 0), 1)
        let offset = max(mapHeight - bounds.height, 0) * fraction
        let viewport = CGRect(x: 0, y: visible.minY / contentHeight * mapHeight - offset,
                              width: bounds.width, height: max(visible.height / contentHeight * mapHeight, 8))
        return Geometry(mapHeight: mapHeight, offset: offset, viewport: viewport)
    }

    override func draw(_ dirtyRect: NSRect) {
        EditorTheme.background.setFill()
        bounds.fill()
        guard let image, let geometry = geometry(), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // The bitmap is drawn upright in this flipped view.
        context.translateBy(x: 0, y: geometry.mapHeight - geometry.offset)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 4, y: 0, width: Self.width, height: geometry.mapHeight))
        context.restoreGState()

        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        geometry.viewport.fill()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        NSBezierPath(rect: geometry.viewport.insetBy(dx: 0.5, dy: 0.5)).stroke()
        // A hairline between the editor and the minimap.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { scroll(to: event) }
    override func mouseDragged(with event: NSEvent) { scroll(to: event) }

    /// Centres the editor on the clicked spot.
    private func scroll(to event: NSEvent) {
        guard let textView, let scrollView, let geometry = geometry() else { return }
        let y = convert(event.locationInWindow, from: nil).y + geometry.offset
        let fraction = min(max(y / geometry.mapHeight, 0), 1)
        let visibleHeight = scrollView.contentView.bounds.height
        let target = fraction * textView.frame.height - visibleHeight / 2
        let maxY = max(textView.frame.height - visibleHeight, 0)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: min(max(target, 0), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
