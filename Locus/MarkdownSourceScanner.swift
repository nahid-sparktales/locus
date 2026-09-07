import Foundation

/// Source-level rules shared by streaming boundaries and legacy reasoning tags.
/// The original strings are retained; this scanner never normalizes their bytes.
enum MarkdownSourceScanner {
    struct Fence: Equatable {
        let marker: Character
        let length: Int
        let quoteDepth: Int
        let listIndent: Int

        static func opening(in line: Substring) -> Self? {
            var context = BlockContext()
            return context.opening(in: line)
        }

        fileprivate static func opening(content: Substring, quoteDepth: Int, listIndent: Int) -> Self? {
            let indentation = content.prefix(while: { $0 == " " }).count
            guard indentation <= 3 else { return nil }
            let value = content.dropFirst(indentation)
            guard let marker = value.first, marker == "`" || marker == "~" else { return nil }
            let length = value.prefix(while: { $0 == marker }).count
            guard length >= 3 else { return nil }
            guard marker != "`" || !value.dropFirst(length).contains("`") else { return nil }
            return Self(marker: marker, length: length, quoteDepth: quoteDepth, listIndent: listIndent)
        }

        func closes(in line: Substring) -> Bool {
            let prefix = Prefix(line)
            guard prefix.quoteDepth == quoteDepth else { return false }
            let indentation = prefix.content.prefix(while: { $0 == " " }).count
            guard indentation >= listIndent, indentation - listIndent <= 3 else { return false }
            let value = prefix.content.dropFirst(indentation)
            let count = value.prefix(while: { $0 == marker }).count
            return count >= length && value.dropFirst(count).allSatisfy(\.isWhitespace)
        }

        func containerContinues(in line: Substring) -> Bool {
            let prefix = Prefix(line)
            guard prefix.quoteDepth >= quoteDepth else { return false }
            return listIndent == 0 || prefix.content.allSatisfy(\.isWhitespace)
                || prefix.content.prefix(while: { $0 == " " }).count >= listIndent
        }
    }

    /// Retains list indentation across a marker line and its continuations.
    /// Closing fences strip exactly their own containers, never arbitrary
    /// whitespace or a fresh list/blockquote marker from code content.
    struct BlockContext {
        private var listIndents: [Int] = []
        private var quoteDepth = 0

        mutating func opening(in line: Substring) -> Fence? {
            let prefix = Prefix(line)
            if prefix.quoteDepth != quoteDepth { listIndents = []; quoteDepth = prefix.quoteDepth }
            let indentation = prefix.content.prefix(while: { $0 == " " }).count
            let blank = prefix.content.allSatisfy(\.isWhitespace)
            if !blank {
                while let last = listIndents.last, indentation < last { listIndents.removeLast() }
            }
            let containerIndent = listIndents.last ?? 0
            let afterIndent = prefix.content.dropFirst(indentation)
            if indentation - containerIndent <= 3,
               let list = Self.listContent(afterIndent, markerColumn: indentation) {
                listIndents.append(list.indent)
                return Fence.opening(content: list.content, quoteDepth: quoteDepth, listIndent: list.indent)
            }
            guard indentation >= containerIndent else { return nil }
            return Fence.opening(content: prefix.content.dropFirst(containerIndent),
                                 quoteDepth: quoteDepth, listIndent: containerIndent)
        }

        private static func listContent(_ value: Substring, markerColumn: Int) -> (content: Substring, indent: Int)? {
            let width: Int
            if let first = value.first, "-*+".contains(first) {
                width = 1
            } else {
                let digits = value.prefix(while: { $0.isASCII && $0.isNumber })
                let suffix = value.dropFirst(digits.count)
                guard !digits.isEmpty, digits.count <= 9, let marker = suffix.first,
                      marker == "." || marker == ")" else { return nil }
                width = digits.count + 1
            }
            let remaining = value.dropFirst(width)
            let padding = remaining.prefix(while: { $0 == " " }).count
            guard padding > 0 else { return nil }
            // Five or more spaces mean one list separator followed by indented
            // content; they must not be swallowed to reveal a false fence.
            let consumed = padding <= 4 ? padding : 1
            return (remaining.dropFirst(consumed), markerColumn + width + consumed)
        }
    }

    private struct Prefix {
        let quoteDepth: Int
        let content: Substring

        init(_ source: Substring) {
            var expanded = ""
            var column = 0
            for character in source {
                if character == "\t" {
                    let spaces = 4 - column % 4
                    expanded += String(repeating: " ", count: spaces)
                    column += spaces
                } else { expanded.append(character); column += 1 }
            }
            var remaining = expanded[...]
            var depth = 0
            while true {
                let indent = remaining.prefix(while: { $0 == " " }).count
                guard indent <= 3, remaining.dropFirst(indent).first == ">" else { break }
                remaining = remaining.dropFirst(indent + 1)
                if remaining.first == " " { remaining = remaining.dropFirst() }
                depth += 1
            }
            quoteDepth = depth
            content = remaining
        }
    }

    static func protectedCodeRanges(in source: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var fence: Fence?
        var fenceStart: String.Index?
        var context = BlockContext()
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let end = source[cursor...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) ?? source.endIndex
            let next = end < source.endIndex ? source.index(after: end) : end
            let line = source[cursor..<end]
            if let active = fence, !active.containerContinues(in: line) {
                ranges.append((fenceStart ?? cursor)..<cursor)
                fence = nil
                fenceStart = nil
            }
            if let active = fence {
                if active.closes(in: line) {
                    ranges.append((fenceStart ?? cursor)..<next)
                    fence = nil
                    fenceStart = nil
                }
            } else if let opening = context.opening(in: line) {
                fence = opening
                fenceStart = cursor
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                ranges.append(cursor..<next)
            }
            cursor = next
        }
        if let fenceStart { ranges.append(fenceStart..<source.endIndex) }

        cursor = source.startIndex
        while cursor < source.endIndex {
            if let protected = ranges.first(where: { $0.contains(cursor) }) {
                cursor = protected.upperBound
                continue
            }
            if source[cursor] == "\\" {
                let escaped = source.index(after: cursor)
                cursor = escaped < source.endIndex ? source.index(after: escaped) : escaped
                continue
            }
            guard source[cursor] == "`" else { cursor = source.index(after: cursor); continue }
            let start = cursor
            while cursor < source.endIndex, source[cursor] == "`" { cursor = source.index(after: cursor) }
            let length = source.distance(from: start, to: cursor)
            var search = cursor
            var match: String.Index?
            while search < source.endIndex {
                if ranges.contains(where: { $0.contains(search) }) { break }
                guard source[search] == "`" else { search = source.index(after: search); continue }
                let closeStart = search
                while search < source.endIndex, source[search] == "`" { search = source.index(after: search) }
                if source.distance(from: closeStart, to: search) == length { match = search; break }
            }
            if let match { ranges.append(start..<match); cursor = match }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var count = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            count += 1
            cursor = previous
        }
        return !count.isMultiple(of: 2)
    }
}
