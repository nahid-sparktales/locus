import AppKit

extension MarkdownColumnAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self { case .left: .left; case .center: .center; case .right: .right }
    }
}

/// Copies the complete logical table, including rows hidden by its preview.
enum MarkdownTableExport {
    enum Format { case tsv, csv }

    static func render(headers: [[MarkdownInlineRun]], rows: [[[MarkdownInlineRun]]], format: Format) -> String {
        let delimiter = format == .tsv ? "\t" : ","
        let width = max(headers.count, rows.map(\.count).max() ?? 0)
        guard width > 0 else { return "" }
        return ([headers] + rows).map { row in
            (0..<width).map { index in
                let value = index < row.count ? row[index].map(\.text).joined() : ""
                if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: delimiter)
        }.joined(separator: format == .csv ? "\r\n" : "\n")
    }
}
