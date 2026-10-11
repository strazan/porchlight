import Foundation

/// Where a website keeps its icon.
public enum SiteIcon {
    /// Icon URLs declared in a page's `<link rel=…>` tags, best first: Apple touch icons,
    /// then bitmap icons by declared size, then SVG.
    public static func candidates(html: String, base: URL) -> [URL] {
        var scored: [(score: Int, url: URL)] = []
        for tag in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let attributes = Self.attributes(String(tag.output))
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"],
                  rel.contains("icon"), let url = URL(string: href, relativeTo: base)?.absoluteURL
            else { continue }
            let size = attributes["sizes"].flatMap { sizes in
                sizes.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max()
            } ?? 0
            let isSVG = attributes["type"]?.contains("svg") == true || url.pathExtension.lowercased() == "svg"
            let score =
                if rel.contains("apple-touch-icon") { 10_000 + max(size, 180) }
                else if isSVG { 1 }
                else { 100 + size }
            scored.append((score, url))
        }
        var seen = Set<URL>()
        return scored.sorted { $0.score > $1.score }.map(\.url).filter { seen.insert($0).inserted }
    }

    /// The conventional locations, for sites whose page can't be read.
    public static func fallbacks(for origin: URL) -> [URL] {
        ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: origin)?.absoluteURL }
    }

    /// The host itself, then its parent domain: `mcp.notion.com` → `mcp.notion.com`, `notion.com`.
    public static func hosts(for domain: String) -> [String] {
        var host = domain.lowercased().trimmingCharacters(in: .whitespaces)
        if let url = URL(string: host), let parsed = url.host() { host = parsed }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host.isEmpty ? [] : [host] }
        return [host, labels.suffix(2).joined(separator: ".")]
    }

    private static func attributes(_ tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in tag.matches(of: /([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) {
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            attributes[String(match.output.1).lowercased()] = String(value)
        }
        return attributes
    }
}

/// A best guess at an icon for a server: a website for well-known ones, a symbol otherwise.
public enum ServerIconHint {
    /// Keyword (found in the name, command or URL) → the project's website.
    static let websites: [(keyword: String, domain: String)] = [
        ("obsidian", "obsidian.md"), ("github", "github.com"), ("gitlab", "gitlab.com"),
        ("notion", "notion.so"), ("linear", "linear.app"), ("slack", "slack.com"),
        ("playwright", "playwright.dev"), ("puppeteer", "pptr.dev"), ("figma", "figma.com"),
        ("sentry", "sentry.io"), ("stripe", "stripe.com"), ("supabase", "supabase.com"),
        ("cloudflare", "cloudflare.com"), ("vercel", "vercel.com"), ("atlassian", "atlassian.com"),
        ("jira", "atlassian.com"), ("confluence", "atlassian.com"), ("todoist", "todoist.com"),
        ("asana", "asana.com"), ("airtable", "airtable.com"), ("hubspot", "hubspot.com"),
        ("brave", "brave.com"), ("exa", "exa.ai"), ("perplexity", "perplexity.ai"),
        ("spotify", "spotify.com"), ("discord", "discord.com"), ("zapier", "zapier.com"),
        ("google-drive", "drive.google.com"), ("gdrive", "drive.google.com"), ("gmail", "mail.google.com"),
        ("postgres", "postgresql.org"), ("mongodb", "mongodb.com"), ("redis", "redis.io"),
        ("docker", "docker.com"), ("kubernetes", "kubernetes.io"), ("aws", "aws.amazon.com"),
        ("raycast", "raycast.com"), ("things", "culturedcode.com"), ("bear", "bear.app"),
    ]

    /// Keyword → SF Symbol, for servers without a website to take an icon from.
    static let symbols: [(keyword: String, symbol: String)] = [
        ("filesystem", "folder"), ("files", "folder"), ("memory", "brain"), ("fetch", "globe"),
        ("browser", "globe"), ("git", "arrow.triangle.branch"), ("time", "clock"), ("sqlite", "cylinder"),
        ("sql", "cylinder"), ("database", "cylinder"), ("everything", "sparkles"), ("search", "magnifyingglass"),
        ("calendar", "calendar"), ("mail", "envelope"), ("shell", "terminal"), ("terminal", "terminal"),
    ]

    public static func domain(for config: ServerConfig) -> String? {
        let text = haystack(config)
        return websites.first { text.contains($0.keyword) }?.domain
    }

    public static func symbol(for config: ServerConfig) -> String {
        let text = haystack(config)
        if let match = symbols.first(where: { text.contains($0.keyword) }) { return match.symbol }
        return config.transport == .http ? "link" : "terminal"
    }

    private static func haystack(_ config: ServerConfig) -> String {
        ([config.name, config.url] + config.commandLine).joined(separator: " ").lowercased()
    }
}
