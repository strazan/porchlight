import Foundation
import PorchlightCore

// The server list: editing, importing, testing, and keeping the router in step.
extension AppModel {
    func add(_ server: ServerConfig) {
        servers.append(server)
        serversChanged()
    }

    func update(_ server: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let oldName = servers[index].name
        servers[index] = server
        if oldName != server.name {
            // Apps limited to this server keep access under its new name.
            clientAccess = clientAccess.mapValues { names in
                names.contains(oldName) ? names.subtracting([oldName]).union([server.name]) : names
            }
        }
        serversChanged()
    }

    func remove(_ ids: Set<ServerConfig.ID>) {
        let removed = Set(servers.filter { ids.contains($0.id) }.map(\.name))
        servers.removeAll { ids.contains($0.id) }
        clientAccess = clientAccess.mapValues { $0.subtracting(removed) }
        serversChanged()
    }

    func setEnabled(_ enabled: Bool, for server: ServerConfig) {
        var changed = server
        changed.enabled = enabled
        update(changed)
    }

    /// Imports the chosen candidates, first copying any Claude Desktop extensions' files.
    func importServers(from candidates: [ImportCandidate]) {
        importServers(candidates.compactMap { candidate in
            guard !isSampleMode else { return candidate.config }
            do {
                try ConfigImporter.install(candidate)
                return candidate.config
            } catch {
                log("Couldn't copy \(candidate.originalName): \(error.localizedDescription)")
                return nil
            }
        })
    }

    /// Adds servers, renaming any whose name is taken.
    func importServers(_ configs: [ServerConfig]) {
        var taken = Set(servers.map(\.name))
        for var config in configs {
            config.name = ServerConfig.uniqueName(config.name, taken: taken)
            taken.insert(config.name)
            servers.append(config)
        }
        serversChanged()
    }

    /// Servers configured in Claude Desktop (and its extensions), Claude Code and Cursor.
    func importCandidates() -> [ImportCandidate] {
        #if DEBUG
        if isSampleMode { return sampleImportCandidates }
        #endif
        return ConfigImporter.candidates()
    }

    /// True if a server with the same command is already in the list.
    func hasServer(like config: ServerConfig) -> Bool {
        servers.contains { $0.sameServer(as: config) }
    }

    /// Tries a config the way an app would, for the editor's Test Connection.
    func probe(_ config: ServerConfig) async -> Result<ServerProbe.Report, ServerProbe.Failure> {
        #if DEBUG
        if let sampleProbe { return sampleProbe }
        #endif
        if shellEnvironment == nil, config.transport == .stdio { shellEnvironment = await ShellEnvironment.resolve() }
        return await ServerProbe.run(config, environment: shellEnvironment ?? ProcessInfo.processInfo.environment)
    }

    /// How many tools an app sees in one connector (nil: one that may use every server).
    /// Nil while Porchlight is off.
    func toolCount(for clientID: String?) async -> Int? {
        #if DEBUG
        if case .success(let report)? = sampleProbe {
            let allowed = clientID.flatMap { clientAccess[$0] }
            return servers.filter { $0.enabled && allowed?.contains($0.name) ?? true }.count * report.tools.count
        }
        #endif
        guard let router else { return nil }
        return await router.toolCount(for: clientID ?? "")
    }

    func loadServers() -> [ServerConfig] {
        do {
            return try store.load() ?? []
        } catch {
            setAsideUnreadableServerList(error)
            return []
        }
    }

    private func serversChanged() {
        do {
            try store.save(servers)
        } catch {
            log("Couldn't save the server list: \(error.localizedDescription)")
        }
        let names = Set(servers.filter(\.enabled).map(\.name))
        serverStatus = serverStatus.filter { names.contains($0.key) }
        syncRouter()
    }

    /// Brings the router up to date with the servers and access settings. Changes often come
    /// several in a row, so they're applied together, latest last.
    func syncRouter() {
        guard let router else { return }
        routerSync?.cancel()
        routerSync = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await router.apply(servers)
            await router.setClientAccess(clientAccess)
            await router.warmUp()
            scheduleCatalogPush()
            toolsRevision += 1
        }
    }

    /// Keeps a server list that can't be read (say, edited by hand into invalid JSON) next to
    /// where it was, rather than saving over it, and starts with an empty one.
    private func setAsideUnreadableServerList(_ error: Error) {
        let aside = store.url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: store.url, to: aside)
            log("Couldn't read the server list (\(error.localizedDescription)); it's kept as \(aside.lastPathComponent)")
        } catch {
            log("Couldn't read the server list or set it aside: \(error.localizedDescription)")
        }
    }
}
