import Foundation

/// GitHub-flavored Markdown table, as pasted into Linear, GitHub or Notion.
enum MarkdownTable {
    static func make(headers: [String], rows: [[String]]) -> String {
        func line(_ cells: [String]) -> String { "| " + cells.map(escape).joined(separator: " | ") + " |" }
        let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([line(headers), separator] + rows.map(line)).joined(separator: "\n")
    }

    /// `|` would split the cell and a newline would end the row.
    private static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
