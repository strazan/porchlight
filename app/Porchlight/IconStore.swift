import AppKit
import Observation
import PorchlightCore

/// Icons for apps and servers: taken from their websites (cached on disk), or a custom image.
///
/// Keys are `app:<client ID>` and `server:<server ID>`, so icons survive renames.
@MainActor @Observable
final class IconStore {
    enum Override: Codable, Equatable {
        /// Take the icon from this website instead of the default one.
        case website(String)
        /// A custom image, stored in Application Support.
        case image(String)
        /// No picture: the initial letter (apps) or a symbol (servers).
        case plain
    }

    /// Loaded icons by key.
    private(set) var images: [String: NSImage] = [:]
    /// Bumped when an override changes, so icon views reload.
    private(set) var revision = 0

    var fetchFromWebsites: Bool {
        didSet {
            defaults.set(fetchFromWebsites, forKey: "iconsFromWebsites")
            if !fetchFromWebsites { images = images.filter { overrides[$0.key].map(\.isImage) ?? false } }
            revision += 1
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var overrides: [String: Override]
    /// Websites learned from pairing (where an app's access goes), by key.
    @ObservationIgnored private var learnedWebsites: [String: String]
    /// Websites that had no usable icon, this session.
    @ObservationIgnored private var missing: Set<String> = []
    /// Downloads under way, by site, so one site is fetched once however many views ask.
    @ObservationIgnored private var inFlight: [String: Task<Data?, Never>] = [:]

    /// Snapshots stay offline unless PORCHLIGHT_SNAPSHOTS_ONLINE is set.
    private static let previewsMayFetch = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOTS_ONLINE"] != nil
    private static let cacheLifetime: TimeInterval = 30 * 24 * 3600
    private static let missingLifetime: TimeInterval = 24 * 3600

    init(defaults: UserDefaults, preview: Bool) {
        self.defaults = defaults
        isPreview = preview
        fetchFromWebsites = defaults.object(forKey: "iconsFromWebsites") as? Bool ?? true
        overrides = defaults.data(forKey: "iconOverrides").flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
        learnedWebsites = defaults.dictionary(forKey: "iconWebsites") as? [String: String] ?? [:]
    }

    static func key(app clientID: String) -> String { "app:\(clientID)" }
    static func key(server: ServerConfig) -> String { "server:\(server.id.uuidString)" }

    // MARK: Settings

    func override(for key: String) -> Override? {
        overrides[key]
    }

    func setOverride(_ override: Override?, for key: String) {
        if case .image(let old)? = overrides[key], override != overrides[key] {
            try? FileManager.default.removeItem(at: Self.customDirectory.appending(path: old))
        }
        overrides[key] = override
        defaults.set(try? JSONEncoder().encode(overrides), forKey: "iconOverrides")
        images[key] = nil
        revision += 1
    }

    /// Copies a picture the user chose, as a 256-point PNG, and uses it for `key`.
    func setCustomImage(from url: URL, for key: String) throws {
        guard let image = NSImage(contentsOf: url), let png = Self.normalizedPNG(image) else { throw IconError.notAnImage }
        try FileManager.default.createDirectory(at: Self.customDirectory, withIntermediateDirectories: true)
        let file = "\(UUID().uuidString).png"
        try png.write(to: Self.customDirectory.appending(path: file))
        setOverride(.image(file), for: key)
    }

    /// Remembers where an app lives (e.g. the host its access goes to), as its default icon source.
    func learnWebsite(_ website: String, for key: String) {
        guard learnedWebsites[key] != website else { return }
        learnedWebsites[key] = website
        defaults.set(learnedWebsites, forKey: "iconWebsites")
        revision += 1
    }

    /// The website the icon for `key` comes from, if any.
    func website(for key: String, default fallback: String?) -> String? {
        switch overrides[key] {
        case .website(let site)?: site
        case .image?, .plain?: nil
        case nil: learnedWebsites[key] ?? fallback
        }
    }

    // MARK: Loading

    /// Loads the icon for `key` (called from the icon views as they appear). `defaultApp` is
    /// the bundle ID of an app whose icon to use when it's installed, before any website.
    func load(key: String, defaultWebsite: String?, defaultApp: String? = nil) async {
        if case .image(let file)? = overrides[key] {
            images[key] = NSImage(contentsOf: Self.customDirectory.appending(path: file))
            return
        }
        if overrides[key] == nil, let defaultApp,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultApp) {
            images[key] = NSWorkspace.shared.icon(forFile: app.path)
            return
        }
        guard fetchFromWebsites, !isPreview || Self.previewsMayFetch, let site = website(for: key, default: defaultWebsite) else {
            images[key] = nil
            return
        }
        images[key] = await icon(for: site)
    }

    private func icon(for site: String) async -> NSImage? {
        let cacheKey = SiteIcon.hosts(for: site).first ?? site
        if missing.contains(cacheKey) { return nil }
        let cached = Self.cacheDirectory.appending(path: "\(cacheKey).png")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cached.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.cacheLifetime,
           let image = NSImage(contentsOf: cached) {
            return image
        }
        let marker = Self.cacheDirectory.appending(path: "\(cacheKey).missing")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.missingLifetime {
            missing.insert(cacheKey)
            return nil
        }

        if let running = inFlight[cacheKey] { return await running.value.flatMap(NSImage.init(data:)) }
        let task = Task { await Self.download(site: site) }
        inFlight[cacheKey] = task
        let png = await task.value
        inFlight[cacheKey] = nil

        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        guard let png, let image = NSImage(data: png) else {
            missing.insert(cacheKey)
            try? Data().write(to: marker)
            return nil
        }
        try? png.write(to: cached)
        return image
    }

    /// Finds a site's icon: the links its home page declares, then the conventional paths.
    /// Returns it as a normalized PNG, or nil.
    nonisolated private static func download(site: String) async -> Data? {
        for host in SiteIcon.hosts(for: site) {
            guard let origin = URL(string: "https://\(host)/") else { continue }
            var candidates: [URL] = []
            if let (html, base) = await fetchPage(origin) { candidates += SiteIcon.candidates(html: html, base: base) }
            candidates += SiteIcon.fallbacks(for: origin)
            var seen = Set<URL>()
            for url in candidates where seen.insert(url).inserted {
                if let data = await fetch(url), let image = NSImage(data: data), image.isValid,
                   let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
                   rep.pixelsWide >= 16 || rep.pixelsWide == 0 /* vector */,
                   let png = await MainActor.run(body: { normalizedPNG(image) }) {
                    return png
                }
            }
        }
        return nil
    }

    nonisolated private static func fetchPage(_ url: URL) async -> (String, URL)? {
        guard let (data, response) = try? await session.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (response.mimeType ?? "").contains("html")
        else { return nil }
        return (String(decoding: data.prefix(512 * 1024), as: UTF8.self), response.url ?? url)
    }

    nonisolated private static func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              // Some sites answer any path with their HTML page.
              !(response.mimeType ?? "").contains("html"),
              data.count < 2 * 1024 * 1024
        else { return nil }
        return data
    }

    nonisolated private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Porchlight/\(Porchlight.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: PublicRedirectsOnly(), delegateQueue: nil)
    }()

    /// Square, 256 points, PNG: the same shape whatever the source.
    static func normalizedPNG(_ image: NSImage) -> Data? {
        let side: CGFloat = 256
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let size = image.size.width > 0 ? image.size : CGSize(width: side, height: side)
        let scale = min(side / size.width, side / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "Porchlight/icons")
    private static let customDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Porchlight/icons")
}

extension IconStore.Override {
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

enum IconError: LocalizedError {
    case notAnImage

    var errorDescription: String? { "That file isn't an image Porchlight can use." }
}

/// Icon fetches follow redirects only to public HTTPS hosts (see `SiteIcon.isPublic`).
private final class PublicRedirectsOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url.map(SiteIcon.isPublic) == true ? request : nil
    }
}
