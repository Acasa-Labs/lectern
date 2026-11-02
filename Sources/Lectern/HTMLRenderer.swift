import Foundation
import Markdown

/// Markdown → HTML. Escapes text, drops `<p>` inside tight lists and gives headings
/// GitHub-style ids so `[link](#some-heading)` works.
struct HTMLRenderer: MarkupWalker {
    private(set) var result = ""
    private var tightList = false
    private var inTableHead = false
    private var alignments: [Table.ColumnAlignment?] = []
    private var column = 0
    private var usedSlugs: [String: Int] = [:]
    private var baseURL: URL?

    static func render(_ markdown: String, baseURL: URL?) -> String {
        var renderer = HTMLRenderer()
        renderer.baseURL = baseURL
        renderer.visit(Document(parsing: markdown))
        return renderer.result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Relative paths point next to the markdown file, not at the temp page it's shown from.
    private func resolve(_ destination: String?) -> String {
        guard let destination, !destination.hasPrefix("#"), let baseURL,
              URL(string: destination)?.scheme == nil,
              let url = URL(string: destination, relativeTo: baseURL)
                ?? URL(string: destination.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "", relativeTo: baseURL)
        else { return destination ?? "" }
        return url.absoluteString
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) {
        if tightList {
            descendInto(paragraph)
            result += "\n"
        } else {
            result += "<p>"
            descendInto(paragraph)
            result += "</p>\n"
        }
    }

    mutating func visitHeading(_ heading: Heading) {
        var slug = heading.plainText.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N} _-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
        let count = usedSlugs[slug, default: 0]
        usedSlugs[slug] = count + 1
        if count > 0 { slug += "-\(count)" }
        result += "<h\(heading.level) id=\"\(Self.escape(slug))\">"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let wasTight = tightList
        tightList = false
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
        tightList = wasTight
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        if codeBlock.language?.lowercased() == "mermaid" {
            // Mermaid only breaks lines on <br>; many docs write a literal \n in labels.
            let code = codeBlock.code.replacingOccurrences(of: "\\n", with: "<br>")
            result += "<pre class=\"mermaid\">\(Self.escape(code))</pre>\n"
            return
        }
        let lang = codeBlock.language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
        result += "<pre><code\(lang)>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) { result += html.rawHTML }
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) { result += "<hr>\n" }

    mutating func visitOrderedList(_ list: OrderedList) {
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        renderList(list, open: "<ol\(start)>", close: "</ol>")
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        renderList(list, open: "<ul>", close: "</ul>")
    }

    /// A list is tight when no blank line separates its items.
    private mutating func renderList(_ list: ListItemContainer, open: String, close: String) {
        let items = Array(list.listItems)
        let loose = zip(items, items.dropFirst()).contains { a, b in
            guard let end = a.range?.upperBound.line, let start = b.range?.lowerBound.line else { return false }
            return start > end + 1
        }
        let wasTight = tightList
        tightList = !loose
        result += open + "\n"
        descendInto(list)
        result += close + "\n"
        tightList = wasTight
    }

    mutating func visitListItem(_ item: ListItem) {
        if let checkbox = item.checkbox {
            result += "<li class=\"task\"><input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")> "
        } else {
            result += "<li>"
        }
        descendInto(item)
        result += "</li>\n"
    }

    mutating func visitTable(_ table: Table) {
        alignments = table.columnAlignments
        result += "<table>\n"
        descendInto(table)
        result += "</table>\n"
    }

    mutating func visitTableHead(_ head: Table.Head) {
        inTableHead = true
        column = 0
        result += "<thead><tr>"
        descendInto(head)
        result += "</tr></thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ body: Table.Body) {
        result += "<tbody>\n"
        descendInto(body)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ row: Table.Row) {
        column = 0
        result += "<tr>"
        descendInto(row)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ cell: Table.Cell) {
        guard cell.colspan > 0, cell.rowspan > 0 else { return }
        let tag = inTableHead ? "th" : "td"
        var attrs = ""
        if column < alignments.count, let align = alignments[column] { attrs += " align=\"\(align)\"" }
        if cell.colspan > 1 { attrs += " colspan=\"\(cell.colspan)\"" }
        if cell.rowspan > 1 { attrs += " rowspan=\"\(cell.rowspan)\"" }
        column += Int(cell.colspan)
        result += "<\(tag)\(attrs)>"
        descendInto(cell)
        result += "</\(tag)>"
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) { result += Self.escape(text.string) }
    mutating func visitInlineCode(_ code: InlineCode) { result += "<code>\(Self.escape(code.code))</code>" }
    mutating func visitInlineHTML(_ html: InlineHTML) { result += html.rawHTML }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) { result += "\n" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) { result += "<br>\n" }

    mutating func visitEmphasis(_ emphasis: Emphasis) { wrap("em", emphasis) }
    mutating func visitStrong(_ strong: Strong) { wrap("strong", strong) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap("del", strikethrough) }

    mutating func visitLink(_ link: Link) {
        result += "<a href=\"\(Self.escape(resolve(link.destination)))\""
        if let title = link.title { result += " title=\"\(Self.escape(title))\"" }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        result += "<img src=\"\(Self.escape(resolve(image.source)))\" alt=\"\(Self.escape(image.plainText))\""
        if let title = image.title { result += " title=\"\(Self.escape(title))\"" }
        result += ">"
    }

    private mutating func wrap(_ tag: String, _ markup: Markup) {
        result += "<\(tag)>"
        descendInto(markup)
        result += "</\(tag)>"
    }
}
