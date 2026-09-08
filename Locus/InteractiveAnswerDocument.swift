import AppKit
import Foundation

/// The sealed shell every interactive answer is rendered and exported in.
///
/// The model contributes a body fragment and nothing else. Locus authors the
/// document around it so the Content-Security-Policy `<meta>` is parsed before
/// any model content: a fragment that smuggles in `<!doctype>`, `<html>`,
/// `<head>` or a leading `<script>` lands inside `<body>`, where the HTML parser
/// treats the nested document tags as inert and the script already runs under
/// the policy. The compiled content rule list (`ruleListJSON`) is the second,
/// independent layer that stays in force even when a caller opts out of the
/// meta policy for an export that a browser will read without WebKit's help.
enum InteractiveAnswerDocument {
    /// Nothing may leave the page: no connections, no frames, no workers, no
    /// plug-ins, no form targets, no base override. Inline script and style
    /// are the whole point of the part, and `data:`/`blob:` pictures let a
    /// widget draw without a network.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'unsafe-inline'",
        "style-src 'unsafe-inline'",
        "img-src data: blob:",
        "media-src data: blob:",
        "font-src data:",
        "connect-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "worker-src 'none'",
        "object-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
        "manifest-src 'none'",
    ].joined(separator: "; ")

    /// The element the theme re-injection rewrites on an appearance change.
    static let themeStyleID = "locus-theme"

    /// Identifier of the compiled rule list; bump when the JSON changes so a
    /// stale compiled copy in the rule-list store is never reused.
    static let ruleListIdentifier = "locus.interactive.v1"

    /// Every subresource type WebKit's content-extension compiler knows. The
    /// store drops any token this OS rejects rather than losing the whole list.
    static let blockedResourceTypes = [
        "image", "style-sheet", "script", "font", "raw", "svg-document",
        "media", "popup", "ping", "fetch", "websocket", "other",
    ]

    /// Types an inline `data:` URL may still satisfy (pictures, fonts, sound).
    static let dataResourceTypes = ["image", "font", "media", "svg-document"]

    /// Types an in-page `blob:` URL may still satisfy.
    static let blobResourceTypes = ["image", "media"]

    static let cspMetaTag =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"

    /// Wraps a model fragment in the Locus document. `themeCSS` is the complete
    /// `:root{…}` rule from `LocusTheme.cssVariables(for:)`; `includeCSP`
    /// exists only so tests can prove the rule list holds on its own.
    static func wrap(html: String, themeCSS: String, includeCSP: Bool = true) -> String {
        var head = "<!doctype html><html><head><meta charset=\"utf-8\">"
        if includeCSP { head += cspMetaTag }
        head += "<meta name=\"viewport\" content=\"width=device-width\">"
        head += "<style id=\"\(themeStyleID)\">\(sanitizedStyleText(themeCSS))</style>"
        head += "<style>"
        head += "html,body{margin:0;background:transparent;color:var(--locus-ink);"
        head += "font:13px/1.45 var(--locus-font)}"
        head += ":focus-visible{outline:2px solid var(--locus-accent);outline-offset:2px}"
        head += "</style></head><body>"
        return head + html + "</body></html>"
    }

    /// The theme rule is Locus-authored, but it is still text pasted into a
    /// `<style>` element: a closing tag inside it would end the element early.
    static func sanitizedStyleText(_ css: String) -> String {
        css.replacingOccurrences(of: "</", with: "<\\/")
    }

    /// JSON for `WKContentRuleListStore`. Block every subresource and every
    /// child-frame document for any URL, then re-allow the inline schemes for
    /// the resource types a self-contained widget legitimately draws with.
    static func ruleListJSON(blockedTypes: [String] = blockedResourceTypes) -> String {
        let dataTypes = dataResourceTypes.filter(blockedTypes.contains)
        let blobTypes = blobResourceTypes.filter(blockedTypes.contains)
        var rules: [[String: Any]] = [
            [
                "trigger": ["url-filter": ".*", "resource-type": blockedTypes],
                "action": ["type": "block"],
            ],
            [
                "trigger": [
                    "url-filter": ".*",
                    "resource-type": ["document"],
                    "load-context": ["child-frame"],
                ],
                "action": ["type": "block"],
            ],
        ]
        if !dataTypes.isEmpty {
            rules.append([
                "trigger": ["url-filter": "^data:", "resource-type": dataTypes],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        if !blobTypes.isEmpty {
            rules.append([
                "trigger": ["url-filter": "^blob:", "resource-type": blobTypes],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The document Save As… and the chat export write: the fragment inside
    /// the same sealed shell the transcript renders, themed for `appearance`.
    static func savedDocument(html: String, appearance: NSAppearance) -> String {
        wrap(html: html, themeCSS: LocusTheme.cssVariables(for: appearance))
    }

    static func write(html: String, to url: URL, appearance: NSAppearance) throws {
        try Data(savedDocument(html: html, appearance: appearance).utf8)
            .write(to: url, options: .atomic)
    }

    /// A file name a save panel can propose for a titled answer.
    static func suggestedFileName(title: String) -> String {
        let slug = title.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let base = collapsed.isEmpty ? "interactive-answer" : String(collapsed.prefix(64))
        return base + ".html"
    }
}
