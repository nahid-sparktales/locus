import Foundation

/// How agent names are cleaned before they are stored with a board entry.
/// `board_read` prints an author as `“Name” (agent)` between entries joined
/// by middle dots, so a name never carries those separators, the quotes, or
/// a "(user)"/"(agent)" marker, and never reads as the user's own "You".
extension BoardAuthor {
    /// A displayable agent name, or nil when no letter or digit is left or
    /// the name would read as the user's own. Invisible format characters
    /// (such as zero-width spaces) are removed, so "Y\u{200B}ou" cannot slip
    /// through; joiners stay, because emoji sequences and Persian or Indic
    /// names need them. Markers are found however they are styled, spaced,
    /// bracketed, or split by joiners, and a cleaned name comes out of this
    /// function unchanged.
    static func agentName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var visible: [Unicode.Scalar] = []
        for scalar in BoardText.singleLine(raw).unicodeScalars {
            if middleDots.contains(scalar.value) {
                visible.append(" ")
            } else if BoardText.curlyQuotes.contains(scalar.value) {
                visible.append("\"")
            } else if scalar.properties.generalCategory != .format || joiners.contains(scalar.value) {
                visible.append(scalar)
            }
        }
        let unmarked = BoardAuthorMarkers.removing(from: visible)
        let name = clamped(unmarked.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        let key = comparisonKey(name)
        guard !key.isEmpty, !reservedKeys.contains(key) else { return nil }
        return name
    }

    /// True for names that read as the user once styling, invisible
    /// characters, spacing, punctuation, case, accents, and width are
    /// ignored: "You", "y o u", "ＹＯＵ", "𝐘𝐨𝐮", "Ⓨⓞⓤ", "ʏᴏᴜ", "🅨🅞🅤",
    /// "🇾🇴🇺", "You\u{3164}", "You (user)".
    static func isReservedForUser(_ name: String) -> Bool {
        reservedKeys.contains(comparisonKey(name))
    }

    /// Letters and digits only, after compatibility mapping (styled,
    /// circled, and fullwidth letters become plain ones) and the letter
    /// look-alikes it leaves alone (`plainLetter`), without invisible
    /// characters, folded for case, accents, and width.
    static func comparisonKey(_ name: String) -> String {
        var visible = String.UnicodeScalarView()
        for scalar in name.precomposedStringWithCompatibilityMapping.unicodeScalars {
            if let letter = plainLetter(scalar) {
                visible.append(letter)
            } else if !isInvisible(scalar),
                      scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                visible.append(scalar)
            }
        }
        return fold(String(visible))
    }

    /// The name clipped to its limits in characters and code points.
    static func clamped(_ value: String) -> String {
        let characters = String(value.prefix(maximumNameLength))
        return BoardText.clipped(characters[...], toScalars: maximumNameScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Latin small capitals and the negative circled, negative squared, and
    /// regional-indicator letters as plain a-z. Compatibility mapping leaves
    /// all of them as they are.
    static func plainLetter(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value
        let offset: UInt32
        switch value {
        case 0x1F150...0x1F169: offset = value - 0x1F150
        case 0x1F170...0x1F189: offset = value - 0x1F170
        case 0x1F1E6...0x1F1FF: offset = value - 0x1F1E6
        default: return smallCapitals[value]
        }
        return Unicode.Scalar(UInt8(0x61 + offset))
    }

    /// Characters that draw nothing: format characters (joiners included),
    /// other default-ignorable code points, and blank Hangul letters.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.generalCategory == .format
            || properties.isDefaultIgnorableCodePoint
            || hangulFillers.contains(scalar.value)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    private static let reservedKeys: Set<String> = ["you", "youuser"]
    /// Zero-width non-joiner and joiner.
    private static let joiners: Set<UInt32> = [0x200C, 0x200D]
    /// Blank Hangul letters, which render as nothing.
    private static let hangulFillers: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0]
    /// `·` and characters that look like it.
    private static let middleDots: Set<UInt32> = [
        0x00B7, 0x02D1, 0x0387, 0x0F0B, 0x0F0C, 0x1427, 0x16EB, 0x2022, 0x2027, 0x2219, 0x22C5,
        0x2981, 0x2E30, 0x2E31, 0x2E33, 0x30FB, 0x318D, 0xA78F, 0xFF65, 0x10101, 0x1F784,
    ]
    private static let smallCapitals: [UInt32: Unicode.Scalar] = [
        0x1D00: "a", 0x0299: "b", 0x1D04: "c", 0x1D05: "d", 0x1D07: "e", 0xA730: "f", 0x0262: "g",
        0x029C: "h", 0x026A: "i", 0x1D0A: "j", 0x1D0B: "k", 0x029F: "l", 0x1D0D: "m", 0x0274: "n",
        0x1D0F: "o", 0x1D18: "p", 0xA7AF: "q", 0x0280: "r", 0xA731: "s", 0x1D1B: "t", 0x1D1C: "u",
        0x1D20: "v", 0x1D21: "w", 0x028F: "y", 0x1D22: "z",
    ]
}

/// Removes "(user)" and "(agent)" from a name as a reader would see them:
/// bracket look-alikes count as parentheses, styled, small-capital, and
/// fullwidth letters as plain ones, and joiners, accents, and other
/// invisible characters as nothing. Each marker leaves one space. The scan
/// removes a marker as soon as its closing bracket arrives, so markers
/// nested inside one another all go in one pass, and what is left holds
/// none.
private enum BoardAuthorMarkers {
    /// One character of a name's comparison form. `source` is the index of
    /// the name's code point it came from, or nil for a removed marker's space.
    private struct Token {
        let character: Character
        let source: Int?
    }

    private static let words: [[Character]] = [Array("user"), Array("agent")]
    private static let openBrackets: Set<UInt32> = [
        0x0028, 0x207D, 0x208D, 0x2768, 0x276A, 0x27EE, 0x2985, 0x2E28, 0xFD3E, 0xFE59, 0xFF08, 0xFF5F,
    ]
    private static let closeBrackets: Set<UInt32> = [
        0x0029, 0x207E, 0x208E, 0x2769, 0x276B, 0x27EF, 0x2986, 0x2E29, 0xFD3F, 0xFE5A, 0xFF09, 0xFF60,
    ]

    static func removing(from scalars: [Unicode.Scalar]) -> String {
        var stack: [Token] = []
        var removed: [ClosedRange<Int>] = []
        for (index, scalar) in scalars.enumerated() {
            for character in comparisonForm(of: scalar) {
                if character == ")", let start = markerStart(in: stack), let open = stack[start].source {
                    removed.append(open...index)
                    stack.removeSubrange(start...)
                    stack.append(Token(character: " ", source: nil))
                } else {
                    stack.append(Token(character: character, source: index))
                }
            }
        }
        // A marker removed later that starts earlier contains the earlier ones.
        var output = String.UnicodeScalarView()
        var next = 0
        for range in removed.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= next {
            output.append(contentsOf: scalars[next..<range.lowerBound])
            output.append(" ")
            next = range.upperBound + 1
        }
        output.append(contentsOf: scalars[next...])
        return String(output)
    }

    /// Where the marker ending at a closing bracket pushed now would start:
    /// an opening bracket, spaces, "user" or "agent", spaces.
    private static func markerStart(in stack: [Token]) -> Int? {
        var index = stack.endIndex
        func skipSpaces() {
            while index > stack.startIndex, stack[index - 1].character.isWhitespace { index -= 1 }
        }
        skipSpaces()
        let word = words.first { word in
            index >= word.count
                && zip(stack[(index - word.count)..<index], word).allSatisfy { $0.character == $1 }
        }
        guard let word else { return nil }
        index -= word.count
        skipSpaces()
        guard index > stack.startIndex, stack[index - 1].character == "(" else { return nil }
        return index - 1
    }

    /// What one code point reads as: "(" or ")", nothing for an invisible
    /// character or an accent, otherwise its folded compatibility form.
    private static func comparisonForm(of scalar: Unicode.Scalar) -> String {
        if openBrackets.contains(scalar.value) { return "(" }
        if closeBrackets.contains(scalar.value) { return ")" }
        guard !isMark(scalar), !BoardAuthor.isInvisible(scalar) else { return "" }
        var mapped = String.UnicodeScalarView()
        for part in String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars where !isMark(part) {
            mapped.append(BoardAuthor.plainLetter(part) ?? part)
        }
        return BoardAuthor.fold(String(mapped))
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: true
        default: false
        }
    }
}
