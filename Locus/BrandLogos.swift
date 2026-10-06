import AppKit
import ImageIO
import SwiftUI

enum ThirdPartyProviderID: String, Hashable, CaseIterable {
    case openAI, anthropic, claude, kimi, ollama, huggingFace, lmStudio, vLLM
    case google, metaMask, phantom, slush, context7, github, sentry, supabase
    case gmail, googleCalendar, telegram, jira
    case custom

    var assetName: String? { self == .custom ? nil : "Brand-" + rawValue }
}

/// Names, account pickers and MCP entries share one offline brand registry.
/// Explicit names win over a repository URL (a plugin hosted on GitHub need
/// not use GitHub's logo). Unknown providers keep a stable monogram.
struct ProviderBrandIdentity: Hashable {
    let id: ThirdPartyProviderID
    let displayName: String
    let aliases: [String]
    let fallbackMonogram: String

    static func resolve(name: String, url: String? = nil, presetID: String? = nil) -> Self {
        let known: [(ThirdPartyProviderID, String, [String], String)] = [
            (.claude, "Claude", ["claude"], "C"),
            (.openAI, "OpenAI", ["openai", "open ai", "chatgpt", "codex", "gpt-"], "AI"),
            (.anthropic, "Anthropic", ["anthropic"], "A"),
            (.kimi, "Kimi", ["moonshot", "kimi"], "K"),
            (.ollama, "Ollama", ["ollama"], "O"),
            (.huggingFace, "Hugging Face", ["huggingface", "hugging face", "hugging-face", "hf.co"], "HF"),
            (.lmStudio, "LM Studio", ["lm studio", "lmstudio", "lm-studio"], "LM"),
            (.vLLM, "vLLM", ["vllm"], "vL"),
            (.gmail, "Gmail", ["gmail"], "G"),
            (.googleCalendar, "Google Calendar", ["google calendar", "google-calendar", "google_calendar"], "GC"),
            (.telegram, "Telegram", ["telegram"], "T"),
            (.jira, "Jira", ["jira"], "J"),
            (.google, "Google", ["google", "gemini"], "G"),
            (.metaMask, "MetaMask", ["metamask"], "M"),
            (.phantom, "Phantom", ["phantom"], "P"),
            (.slush, "Slush", ["slush"], "S"),
            (.context7, "Context7", ["context7"], "7"),
            (.github, "GitHub", ["github", "githubcopilot"], "GH"),
            (.sentry, "Sentry", ["sentry"], "S"),
            (.supabase, "Supabase", ["supabase"], "S"),
        ]
        for identity in [presetID, name, URL(string: url ?? "")?.host].compactMap({ $0?.lowercased() }) {
            if let match = known.first(where: { candidate in
                candidate.2.contains { alias in
                    identity.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: alias)
                        + (alias.hasSuffix("-") ? "" : "(?![a-z0-9])"), options: .regularExpression) != nil
                }
            }) {
                return Self(id: match.0, displayName: match.1, aliases: match.2, fallbackMonogram: match.3)
            }
        }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return Self(id: .custom, displayName: name.isEmpty ? "Custom provider" : name,
                    aliases: [], fallbackMonogram: String(letters.isEmpty ? Array(name.prefix(2)) : letters).uppercased())
    }
}

struct ProviderLogo: View {
    let identity: ProviderBrandIdentity
    var size: CGFloat = 26

    init(name: String, url: String? = nil, presetID: String? = nil, size: CGFloat = 26) {
        identity = .resolve(name: name, url: url, presetID: presetID)
        self.size = size
    }

    init(kind: ProviderKind, name: String? = nil, url: String? = nil, size: CGFloat = 26) {
        identity = .resolve(name: name ?? kind.title, url: url ?? kind.defaultBaseURL, presetID: kind.rawValue)
        self.size = size
    }

    var body: some View {
        Group {
            if let asset = identity.id.assetName {
                BrandLogoTile(asset: asset, size: size)
            } else {
                LogoMonogram(name: identity.displayName, initials: identity.fallbackMonogram, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(identity.displayName) logo")
        .accessibilityIdentifier("provider.logo.\(identity.id.rawValue)")
    }
}

private struct BrandLogoTile: View {
    let asset: String
    let size: CGFloat
    var body: some View {
        Image(asset).renderingMode(.original).resizable().scaledToFit()
            .padding(size * 0.13).frame(width: size, height: size)
            .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.23))
            .overlay { RoundedRectangle(cornerRadius: size * 0.23).stroke(Color.black.opacity(0.10), lineWidth: 0.5) }
    }
}

private struct LogoMonogram: View {
    let name: String
    let initials: String
    let size: CGFloat
    private var hue: Double { Double(name.lowercased().utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360 }
    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.locus(size: size * 0.34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.50, brightness: 0.46),
                        in: RoundedRectangle(cornerRadius: size * 0.23))
    }
}

/// Plugin-owned artwork comes from a bounded, validated local manifest asset,
/// never a live favicon request. Built-in plugins also work with older backends.
struct PluginLogo: View {
    let name: String
    var displayName: String? = nil
    var iconData: String? = nil
    var size: CGFloat = 36

    static func bundledAsset(for name: String) -> String? {
        switch name.lowercased() {
        case "agent-world", "agent-worlds": "Plugin-agent-world"
        case "langgraph-workflow", "langgraph-workflows", "langgraph": "Plugin-langgraph-workflow"
        default: nil
        }
    }

    static func image(from encoded: String?) -> NSImage? {
        guard let encoded, encoded.utf8.count <= 350_000,
              let data = Data(base64Encoded: encoded), data.count <= 256 * 1024 else { return nil }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            return NSImage(cgImage: thumbnail, size: .zero)
        }
        // SVGs are sanitized to local shapes and paint by the extension parser.
        return NSImage(data: data)
    }

    var body: some View {
        Group {
            if let asset = Self.bundledAsset(for: name) {
                Image(asset).renderingMode(.original).resizable().scaledToFit().frame(width: size, height: size)
            } else if let image = Self.image(from: iconData) {
                Image(nsImage: image).resizable().scaledToFit().padding(size * 0.10)
                    .frame(width: size, height: size)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.23))
            } else {
                ProviderLogo(name: displayName ?? name, presetID: name, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName ?? name) plugin logo")
    }
}

struct MCPLogo: View {
    let name: String
    var url: String? = nil
    var presetID: String? = nil
    var pluginID: String? = nil
    var size: CGFloat = 26

    var body: some View {
        if let asset = PluginLogo.bundledAsset(for: pluginID?.split(separator: "/").last.map(String.init) ?? presetID ?? name) {
            Image(asset).renderingMode(.original).resizable().scaledToFit().frame(width: size, height: size)
                .accessibilityLabel("\(name) logo")
        } else {
            ProviderLogo(name: name, url: url, presetID: presetID, size: size)
        }
    }
}

struct ConnectorLogo: View {
    let kind: ConnectorKind
    var size: CGFloat = 26
    var body: some View {
        if kind == .gmail || kind == .telegram {
            ProviderLogo(name: kind.title, size: size)
        } else {
            Image(systemName: kind.symbol).frame(width: size, height: size)
        }
    }
}
