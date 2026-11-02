import AppKit
import SwiftUI

/// Xcode's "Default" editor colours, light and dark.
enum EditorTheme {
    static let background = dynamic(0xffffff, 0x1f1f24)
    static let text = dynamic(0x000000, 0xffffff, darkAlpha: 0.85)
    static let currentLine = dynamic(0xe8f2ff, 0x23252b)
    static let lineNumber = dynamic(0xa6a6a6, 0x747478)
    static let currentLineNumber = dynamic(0x000000, 0xffffff)
    /// Bright yellow with dark text, like Xcode's bracket flash, so it stands out in both themes.
    static let matchingBracket = NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
    static let matchingBracketText = NSColor.black
    /// Light box behind other uses of the selected word.
    static let occurrence = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.16)
            : NSColor(white: 0, alpha: 0.1)
    }

    static func dynamic(_ light: Int, _ dark: Int, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: isDark ? darkAlpha : 1)
        }
    }
}

/// Where the cursor is, for the status bar. Separate from the tab so moving the cursor
/// doesn't redraw the whole editor area.
final class CursorPosition: ObservableObject {
    @Published var line = 1
    @Published var column = 1
}

/// Draws Xcode's current-line band behind the text.
final class EditorTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let layoutManager, let textContainer else { return }
        let ns = string as NSString
        let location = selectedRange().location
        var band: NSRect
        if location >= ns.length, ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            band = layoutManager.extraLineFragmentRect
        } else {
            // Cover every wrapped row of the cursor's line.
            let line = ns.lineRange(for: NSRange(location: min(location, ns.length - 1), length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
            band = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            band = band.union(layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil))
        }
        band.origin.x = 0
        band.origin.y += textContainerOrigin.y
        band.size.width = bounds.width
        EditorTheme.currentLine.setFill()
        band.intersection(rect).fill()
    }
}

/// One tab's source editor: a plain-text view with highlighting, line numbers and auto-indent.
final class EditorController: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView: EditorTextView
    let cursor = CursorPosition()
    private weak var tab: EditorTab?
    private let ruler: LineNumberRuler
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var fontSize: CGFloat = 0
    private var wrapsLines = true
    private var pendingHighlight: DispatchWorkItem?
    private let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        return style
    }()

    private var language: SyntaxLanguage { SyntaxLanguage(url: tab?.url) }

    init(tab: EditorTab) {
        self.tab = tab
        // A TextKit 1 stack, which the line-number ruler and current-line band measure with.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = EditorTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        ruler = LineNumberRuler(textView: textView)
        super.init()

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Code-like text: no smart quotes, dashes, replacements or spelling fixes.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = EditorTheme.background
        textView.insertionPointColor = EditorTheme.currentLineNumber
        textView.string = tab.text
        // Start at the top of the file, as Xcode does.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        ruler.textDidChange()

        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        setFontSize(13)
    }

    func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .foregroundColor: EditorTheme.text, .paragraphStyle: paragraph]
        ruler.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, size - 2), weight: .regular)
        highlight()
    }

    /// Wrapped lines fit the editor's width; unwrapped lines scroll sideways.
    func setWordWrap(_ wrap: Bool) {
        guard wrap != wrapsLines, let container = textView.textContainer else { return }
        wrapsLines = wrap
        if wrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        }
        scrollView.hasHorizontalScroller = !wrap
        scrollView.tile()
        ruler.needsDisplay = true
    }

    /// Selects a range (e.g. a search result), scrolls to it and flashes it, as Xcode does.
    func select(_ range: NSRange) {
        let length = (textView.string as NSString).length
        guard range.location <= length else { return }
        let target = NSRange(location: range.location, length: min(range.length, length - range.location))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        textView.showFindIndicator(for: target)
    }

    /// Replaces the whole text as one undoable edit (Replace All in Find in Folder).
    func replaceAllUndoably(with text: String) {
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.string != text, textView.shouldChangeText(in: full, replacementString: text) else { return }
        textView.replaceCharacters(in: full, with: text)
        textView.didChangeText()
    }

    // MARK: Selection highlights

    /// Xcode-style hints that follow the selection: other uses of a selected word,
    /// or the partner of a bracket next to the cursor.
    private func updateSelectionHighlights() {
        guard let layoutManager = textView.layoutManager else { return }
        let ns = textView.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        let selection = textView.selectedRange()
        if selection.length > 0 {
            highlightOccurrences(of: selection, in: ns, layoutManager: layoutManager)
        } else {
            highlightBracketPair(at: selection.location, in: ns, layoutManager: layoutManager)
        }
    }

    private static let wordCharacters = "\\p{L}\\p{N}_$"

    /// When a whole word is selected, lightly marks every other place it appears.
    private func highlightOccurrences(of selection: NSRange, in ns: NSString, layoutManager: NSLayoutManager) {
        guard selection.length <= 100, ns.length < 2_000_000 else { return }
        let word = ns.substring(with: selection)
        let chars = Self.wordCharacters
        guard word.range(of: "^[\(chars)]+$", options: .regularExpression) != nil else { return }
        // Only if the selection is the whole word, not part of one.
        let isWordChar = { (index: Int) -> Bool in
            guard index >= 0, index < ns.length else { return false }
            return ns.substring(with: NSRange(location: index, length: 1)).range(of: "^[\(chars)]$", options: .regularExpression) != nil
        }
        guard !isWordChar(selection.location - 1), !isWordChar(NSMaxRange(selection)) else { return }
        let pattern = "(?<![\(chars)])" + NSRegularExpression.escapedPattern(for: word) + "(?![\(chars)])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        var count = 0
        regex.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let range = match?.range, range != selection else { return }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: EditorTheme.occurrence, forCharacterRange: range)
            count += 1
            if count >= 2_000 { stop.pointee = true }
        }
    }

    /// Highlights a bracket next to the cursor and its partner, as Xcode does.
    private func highlightBracketPair(at location: Int, in ns: NSString, layoutManager: NSLayoutManager) {
        var bracketHighlights: [NSRange] = []
        // The bracket just before the cursor wins (the one just typed), then the one after it.
        for position in [location - 1, location] where position >= 0 && position < ns.length {
            if let partner = Self.partner(ofBracketAt: position, in: ns) {
                bracketHighlights = [NSRange(location: position, length: 1), NSRange(location: partner, length: 1)]
                break
            }
        }
        for range in bracketHighlights {
            layoutManager.addTemporaryAttributes([.backgroundColor: EditorTheme.matchingBracket,
                                                  .foregroundColor: EditorTheme.matchingBracketText],
                                                 forCharacterRange: range)
        }
    }

    private static let bracketPairs: [unichar: (partner: unichar, step: Int)] = [
        0x28: (0x29, 1), 0x5B: (0x5D, 1), 0x7B: (0x7D, 1),   // ( [ {
        0x29: (0x28, -1), 0x5D: (0x5B, -1), 0x7D: (0x7B, -1), // ) ] }
    ]

    /// Scans forward from an opening bracket (or back from a closing one), counting nesting.
    private static func partner(ofBracketAt index: Int, in ns: NSString) -> Int? {
        let bracket = ns.character(at: index)
        guard let pair = bracketPairs[bracket] else { return nil }
        var depth = 0
        var position = index
        var scanned = 0
        while position >= 0, position < ns.length, scanned < 200_000 {
            let character = ns.character(at: position)
            if character == bracket {
                depth += 1
            } else if character == pair.partner {
                depth -= 1
                if depth == 0 { return position }
            }
            position += pair.step
            scanned += 1
        }
        return nil
    }

    /// Text changed on disk: replace it without leaving undo steps that point at the old text.
    func replaceText(_ text: String) {
        let selection = textView.selectedRange()
        textView.string = text
        tab?.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        highlight()
        ruler.textDidChange()
    }

    private func highlight() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: EditorTheme.text, .paragraphStyle: paragraph], range: full)
        if storage.length < 2_000_000 {
            for match in SyntaxHighlighter.matches(in: storage.string, language: language) {
                storage.addAttribute(.foregroundColor, value: match.token.color, range: match.range)
                if match.token.isBold { storage.addAttribute(.font, value: boldFont, range: match.range) }
            }
        }
        storage.endEditing()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        tab?.text = textView.string
        ruler.textDidChange()
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateSelectionHighlights()
        ruler.needsDisplay = true
        textView.needsDisplay = true
        let location = textView.selectedRange().location
        let line = ruler.line(containing: location)
        cursor.line = line + 1
        cursor.column = location - ruler.start(ofLine: line) + 1
    }

    /// Each tab keeps its own undo history instead of sharing the window's.
    func undoManager(for view: NSTextView) -> UndoManager? {
        tab?.undoManager
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Keep the current line's indent, one level deeper after an opening bracket or colon.
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            var indent = String(before.prefix { $0 == " " || $0 == "\t" })
            if let last = before.trimmingCharacters(in: .whitespaces).last, language.indentOpeners.contains(last) {
                indent += language.indentUnit
            }
            textView.insertText("\n" + indent, replacementRange: selection)
            return true
        case #selector(NSResponder.insertTab(_:)):
            textView.insertText(language.indentUnit, replacementRange: textView.selectedRange())
            return true
        default:
            return false
        }
    }
}

struct CodeEditorView: NSViewRepresentable {
    let tab: EditorTab
    let fontSize: Double
    @AppStorage("wordWrap") private var wordWrap = true

    func makeNSView(context: Context) -> HostedViewContainer {
        let editor = tab.editor
        DispatchQueue.main.async { editor.textView.window?.makeFirstResponder(editor.textView) }
        return HostedViewContainer(editor.scrollView)
    }

    func updateNSView(_ view: HostedViewContainer, context: Context) {
        tab.editor.setFontSize(fontSize)
        tab.editor.setWordWrap(wordWrap)
    }
}

/// Line numbers beside the editor, with the cursor's line in bright text, as in Xcode.
final class LineNumberRuler: NSRulerView {
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { textDidChange() }
    }
    private weak var textView: NSTextView?
    /// UTF-16 offset where each line starts; the last entry may equal the text length (an empty final line).
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        clientView = textView
        let clipView = textView.enclosingScrollView!.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: clipView)
        textDidChange()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    @objc private func redraw() { needsDisplay = true }

    /// Only the numbers: skip NSRulerView's own background and edge line, which Xcode doesn't have.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    func textDidChange() {
        guard let textView else { return }
        let ns = textView.string as NSString
        var starts = [0]
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(of: "\n", options: .literal, range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard found.location != NSNotFound else { break }
            starts.append(found.location + 1)
            searchStart = found.location + 1
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        let width = ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width) + 24
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
            // The scroll view only makes room for the new width once it re-tiles.
            scrollView?.tile()
        }
        needsDisplay = true
    }

    /// Zero-based line holding a UTF-16 offset.
    func line(containing location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func start(ofLine line: Int) -> Int { lineStarts[min(line, lineStarts.count - 1)] }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.background.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let currentLine = line(containing: textView.selectedRange().location)
        let boldFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold)

        var index = line(containing: chars.location)
        while index < lineStarts.count {
            let start = lineStarts[index]
            if start > NSMaxRange(chars) && start < length { break }
            let fragment: NSRect
            if start < length {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start),
                                                          effectiveRange: nil)
            } else {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty && length > 0 { break }
            }
            let top = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            let isCurrent = index == currentLine
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isCurrent ? boldFont : font,
                .foregroundColor: isCurrent ? EditorTheme.currentLineNumber : EditorTheme.lineNumber,
            ]
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: top + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            if start >= length { break }
            index += 1
        }
    }
}
