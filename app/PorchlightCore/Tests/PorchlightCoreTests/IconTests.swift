import Foundation
import Testing
@testable import PorchlightCore

@Suite struct IconTests {
    @Test func prefersAppleTouchIconsThenLargerBitmapsThenSVG() {
        let html = """
            <head>
              <link rel="icon" href="/favicon.ico" sizes="32x32">
              <link rel="icon" type="image/svg+xml" href="/favicon.svg">
              <LINK href='/static/icon-192.png' rel='icon' sizes='192x192'>
              <link rel="apple-touch-icon" href="/apple-touch-icon.png?v=2" sizes="180x180"/>
              <link rel="stylesheet" href="/style.css">
            </head>
            """
        let urls = SiteIcon.candidates(html: html, base: URL(string: "https://linear.app/")!).map(\.absoluteString)
        #expect(urls == [
            "https://linear.app/apple-touch-icon.png?v=2",
            "https://linear.app/static/icon-192.png",
            "https://linear.app/favicon.ico",
            "https://linear.app/favicon.svg",
        ])
    }

    @Test func resolvesAbsoluteAndProtocolRelativeLinks() {
        let html = #"<link rel="shortcut icon" href="https://cdn.example.com/f.png"><link rel="apple-touch-icon" href="//cdn.example.com/t.png">"#
        let urls = SiteIcon.candidates(html: html, base: URL(string: "https://example.com/page")!).map(\.absoluteString)
        #expect(urls == ["https://cdn.example.com/t.png", "https://cdn.example.com/f.png"])
    }

    @Test func fallsBackToConventionalPathsAndParentDomains() {
        #expect(SiteIcon.fallbacks(for: URL(string: "https://claude.ai/")!).map(\.absoluteString)
            == ["https://claude.ai/apple-touch-icon.png", "https://claude.ai/favicon.ico"])
        #expect(SiteIcon.hosts(for: "mcp.notion.com") == ["mcp.notion.com", "notion.com"])
        #expect(SiteIcon.hosts(for: "www.github.com") == ["github.com"])
        #expect(SiteIcon.hosts(for: "https://obsidian.md/download") == ["obsidian.md"])
        #expect(SiteIcon.hosts(for: "") == [])
    }

    @Test func guessesServerIcons() {
        let obsidian = ServerConfig(name: "notes", url: "http://127.0.0.1:27123/mcp/")
        #expect(ServerIconHint.domain(for: obsidian) == nil)
        #expect(ServerIconHint.symbol(for: obsidian) == "link")
        #expect(ServerIconHint.domain(for: ServerConfig(name: "obsidian", url: "http://127.0.0.1:27123/mcp/")) == "obsidian.md")
        let github = ServerConfig(name: "gh", command: "docker", args: ["run", "ghcr.io/github/github-mcp-server"])
        #expect(ServerIconHint.domain(for: github) == "github.com")
        let files = ServerConfig(name: "filesystem", command: "npx", args: ["@modelcontextprotocol/server-filesystem"])
        #expect(ServerIconHint.domain(for: files) == nil)
        #expect(ServerIconHint.symbol(for: files) == "folder")
        #expect(ServerIconHint.symbol(for: ServerConfig(name: "custom", command: "./run.sh")) == "terminal")
    }
}
