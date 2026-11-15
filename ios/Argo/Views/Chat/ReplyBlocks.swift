// Adapted from nwverse/persona apple/Persona/Views/Chat/ReplyBlocks.swift @ 3002eb3 (MIT).
// Foundation supplies Markdown parsing in place of Persona's MarkdownUI package.
import Foundation
import SwiftUI

struct ReplyText: View {
    let text: String

    var body: some View {
        if let markdown = try? AttributedString(markdown: text) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(Array(ReplyMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                    self.block(block.text, intent: block.intent)
                }
            }
            .textSelection(.enabled)
        } else {
            // Preserve the exact message if Foundation cannot interpret its Markdown.
            Text(verbatim: text).textSelection(.enabled)
        }
    }

    @ViewBuilder private func block(_ text: AttributedString, intent: PresentationIntent?) -> some View {
        if ReplyMarkdown.tableID(intent) != nil {
            ReplyTableBlock(text: text)
        } else if let language = codeLanguage(intent) {
            ReplyCodeBlock(text: String(text.characters), language: language)
        } else if let level = heading(intent) {
            Text(text).font(level == 1 ? Theme.Font.title : Theme.Font.heading)
                .accessibilityAddTraits(.isHeader)
        } else if intent?.components.contains(where: { $0.kind == .blockQuote }) == true {
            Text(text)
                .foregroundStyle(.secondary)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.08))
                .overlay(alignment: .leading) { Theme.accent.frame(width: Theme.Size.rule) }
                .clipShape(.rect(cornerRadius: Theme.Radius.badge))
        } else if let marker = listMarker(intent) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(verbatim: marker).foregroundStyle(.secondary)
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// An empty language distinguishes an unlabelled code fence from other blocks.
    private func codeLanguage(_ intent: PresentationIntent?) -> String? {
        for component in intent?.components ?? [] {
            if case .codeBlock(let language) = component.kind { return language ?? "" }
        }
        return nil
    }
    private func heading(_ intent: PresentationIntent?) -> Int? {
        for component in intent?.components ?? [] {
            if case .header(let level) = component.kind { return level }
        }
        return nil
    }
    private func listMarker(_ intent: PresentationIntent?) -> String? {
        var ordinal: Int?
        var ordered = false
        for component in intent?.components ?? [] {
            if case .listItem(let value) = component.kind { ordinal = value }
            if component.kind == .orderedList { ordered = true }
        }
        return ordinal.map { ordered ? "\($0)." : "•" }
    }
}

// Foundation's runs are cells, not table blocks. Keep their row/column identities
// together so an empty cell cannot shift another value under the wrong header.
enum ReplyMarkdown {
    struct Block {
        var text: AttributedString
        let intent: PresentationIntent?
    }

    struct TableRow {
        let id: Int
        let header: Bool
        var cells: [AttributedString]
    }

    static func tableID(_ intent: PresentationIntent?) -> Int? {
        intent?.components.first { if case .table = $0.kind { true } else { false } }?.identity
    }

    static func blocks(_ markdown: AttributedString) -> [Block] {
        var spans: [(intent: PresentationIntent?, range: Range<AttributedString.Index>)] = []
        for (intent, range) in markdown.runs[\.presentationIntent] {
            if let table = tableID(intent), let last = spans.last, tableID(last.intent) == table {
                spans[spans.count - 1].range = last.range.lowerBound..<range.upperBound
            } else {
                spans.append((intent, range))
            }
        }
        return spans.map { Block(text: AttributedString(markdown[$0.range]), intent: $0.intent) }
    }

    static func tableRows(_ text: AttributedString) -> [TableRow] {
        var rows: [TableRow] = []
        for (intent, range) in text.runs[\.presentationIntent] {
            var row: (id: Int, header: Bool)?
            var column: Int?
            var columns = 0
            for component in intent?.components ?? [] {
                switch component.kind {
                case .table(let definitions): columns = definitions.count
                case .tableHeaderRow: row = (component.identity, true)
                case .tableRow: row = (component.identity, false)
                case .tableCell(let index): column = index
                default: break
                }
            }
            if let row, let column {
                if rows.last?.id != row.id {
                    rows.append(TableRow(id: row.id, header: row.header,
                                         cells: Array(repeating: AttributedString(), count: columns)))
                }
                rows[rows.count - 1].cells[column].append(AttributedString(text[range]))
            }
        }
        return rows
    }
}

private struct ReplyTableBlock: View {
    let text: AttributedString

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                ForEach(ReplyMarkdown.tableRows(text), id: \.id) { row in
                    GridRow {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell).fontWeight(row.header ? .semibold : .regular)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Persona's fenced code surface and Copy bar, fed by native Markdown block intents.
struct ReplyCodeBlock: View {
    let text: String
    var language = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(verbatim: language).font(Theme.Font.label).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                CopyMessageButton(text: text)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .tapTargetHeight()
                    .accessibilityLabel("Copy Code")
            }
            .padding(.horizontal, Theme.Space.m)
            .background(Theme.codeBar)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(Theme.Font.code)
                    .lineHeight(.code)
                    .readingContent()
                    .textSelection(.enabled)
                    .padding(Theme.Space.m)
            }
            .clipped()
            .background(Theme.codeBackground)
        }
        .clipShape(.rect(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
