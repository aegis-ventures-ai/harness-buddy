import Foundation

/// A user-scope MCP server (C-3), in the shape common to all three harnesses.
public struct MCPServer: Equatable, Hashable, Sendable, Identifiable {
    public enum Transport: String, CaseIterable, Sendable, Hashable {
        case stdio, http, sse
    }

    public var name: String
    public var transport: Transport
    public var command: String
    public var args: [String]
    public var env: [KeyValue]
    public var url: String
    public var headers: [KeyValue]
    public var isEnabled: Bool
    /// Keys we don't edit (timeouts, cwd, …). Shown read-only and always preserved.
    public var otherKeys: [String]

    public var id: String { name }

    public init(
        name: String, transport: Transport = .stdio, command: String = "", args: [String] = [],
        env: [KeyValue] = [], url: String = "", headers: [KeyValue] = [], isEnabled: Bool = true, otherKeys: [String] = []
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.isEnabled = isEnabled
        self.otherKeys = otherKeys
    }

    /// `command args…` or the URL.
    public var summary: String {
        transport == .stdio ? ([command] + args).joined(separator: " ") : url
    }

    /// Problems that block saving.
    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Name is required") }
        if name.contains(".") || name.contains("/") { errors.append("Name can't contain '.' or '/'") }
        switch transport {
        case .stdio where command.trimmingCharacters(in: .whitespaces).isEmpty: errors.append("Command is required")
        case .http, .sse:
            if URL(string: url).flatMap(\.scheme).map({ ["http", "https"].contains($0) }) != true { errors.append("URL must start with http:// or https://") }
        default: break
        }
        if Set(env.map(\.key)).count != env.count { errors.append("Environment variable names must be unique") }
        if env.contains(where: { $0.key.isEmpty }) { errors.append("Environment variable names can't be empty") }
        return errors
    }
}

/// Where and how each harness stores MCP servers.
public struct MCPServerMapping: Sendable {
    public var harness: Harness
    public var file: ConfigFileKind
    /// `mcpServers` (Claude) or `mcp_servers` (Codex, Grok).
    public var tableKey: String
    public var headersKey: String
    /// Claude Code has no user-scope on/off switch.
    public var supportsDisabling: Bool
    public var transports: [MCPServer.Transport]

    public static func forHarness(_ harness: Harness) -> MCPServerMapping {
        switch harness {
        case .claude:
            MCPServerMapping(harness: harness, file: .claudeGlobal, tableKey: "mcpServers", headersKey: "headers",
                             supportsDisabling: false, transports: [.stdio, .http, .sse])
        case .codex:
            // Codex speaks stdio and streamable HTTP.
            MCPServerMapping(harness: harness, file: .codexConfig, tableKey: "mcp_servers", headersKey: "http_headers",
                             supportsDisabling: true, transports: [.stdio, .http])
        case .grok:
            MCPServerMapping(harness: harness, file: .grokConfig, tableKey: "mcp_servers", headersKey: "headers",
                             supportsDisabling: true, transports: [.stdio, .http, .sse])
        }
    }

    private static let knownKeys: Set<String> = ["type", "transport", "command", "args", "env", "url", "headers", "http_headers", "enabled"]

    // MARK: Reading

    public func servers(in document: ConfigDocument) -> [MCPServer] {
        guard let table = document.value(at: [tableKey])?.table else { return [] }
        let disabled = Set(harness == .grok ? document.value(at: ["disabled_mcp_servers"])?.stringArray ?? [] : [])
        return table.pairs.compactMap { pair in
            guard let entry = pair.value.table else { return nil }
            let value = ConfigValue.table(entry)
            let url = value["url"]?.string ?? ""
            let declared = (value["type"] ?? value["transport"])?.string.flatMap(MCPServer.Transport.init(rawValue:))
            let transport = declared ?? (url.isEmpty ? .stdio : .http)
            return MCPServer(
                name: pair.key,
                transport: transport,
                command: value["command"]?.string ?? "",
                args: value["args"]?.stringArray ?? [],
                env: value["env"]?.stringPairs ?? [],
                url: url,
                headers: value[headersKey]?.stringPairs ?? [],
                isEnabled: value["enabled"]?.bool != false && !disabled.contains(pair.key),
                otherKeys: entry.pairs.map(\.key).filter { !Self.knownKeys.contains($0) }
            )
        }
    }

    // MARK: Writing

    /// Operations that turn `old` into `new`. Only changed fields are written, so keys we don't
    /// model (timeouts, `cwd`, comments in TOML) survive an edit.
    /// - `old == nil`: add. `new == nil`: remove. A rename removes and re-adds.
    public func operations(from old: MCPServer?, to new: MCPServer?, document: ConfigDocument) -> [ConfigOperation] {
        switch (old, new) {
        case (nil, nil):
            return []
        case (let old?, nil):
            return [.remove([tableKey, old.name])] + disabledListOperations(removing: old.name, document: document)
        case (nil, let new?):
            return [.set([tableKey, new.name], fullValue(new))] + enabledOperations(for: new, document: document, isNew: true)
        case (let old?, let new?) where old.name != new.name:
            return operations(from: old, to: nil, document: document) + operations(from: nil, to: new, document: document)
        case (let old?, let new?):
            let base = [tableKey, new.name]
            var ops: [ConfigOperation] = []
            func field(_ key: String, _ value: ConfigValue?, changed: Bool) {
                guard changed else { return }
                ops.append(value.map { .set(base + [key], $0) } ?? .remove(base + [key]))
            }
            field(typeKey, typeValue(new.transport), changed: old.transport != new.transport)
            let stdio = new.transport == .stdio
            field("command", stdio ? .string(new.command) : nil, changed: old.command != new.command || old.transport != new.transport)
            field("args", stdio && !(new.args.isEmpty && old.args.isEmpty) ? .strings(new.args) : nil,
                  changed: old.args != new.args || old.transport != new.transport)
            field("env", new.env.isEmpty ? nil : .pairs(new.env), changed: old.env != new.env)
            field("url", stdio ? nil : .string(new.url), changed: old.url != new.url || old.transport != new.transport)
            field(headersKey, stdio || new.headers.isEmpty ? nil : .pairs(new.headers),
                  changed: old.headers != new.headers || old.transport != new.transport)
            if old.isEnabled != new.isEnabled { ops += enabledOperations(for: new, document: document, isNew: false) }
            return ops
        }
    }

    private var typeKey: String { harness == .grok ? "transport" : "type" }

    /// Claude always writes `type`; Codex infers it from `url`; Grok only needs it for SSE.
    private func typeValue(_ transport: MCPServer.Transport) -> ConfigValue? {
        switch harness {
        case .claude: .string(transport.rawValue)
        case .codex: nil
        case .grok: transport == .sse ? .string("sse") : nil
        }
    }

    private func fullValue(_ server: MCPServer) -> ConfigValue {
        var pairs: [(String, ConfigValue)] = []
        if let type = typeValue(server.transport) { pairs.append((typeKey, type)) }
        if server.transport == .stdio {
            pairs.append(("command", .string(server.command)))
            pairs.append(("args", .strings(server.args)))
        } else {
            pairs.append(("url", .string(server.url)))
            if !server.headers.isEmpty { pairs.append((headersKey, .pairs(server.headers))) }
        }
        if !server.env.isEmpty { pairs.append(("env", .pairs(server.env))) }
        return .table(OrderedPairs(pairs))
    }

    private func enabledOperations(for server: MCPServer, document: ConfigDocument, isNew: Bool) -> [ConfigOperation] {
        guard supportsDisabling else { return [] }
        let path = [tableKey, server.name, "enabled"]
        var ops: [ConfigOperation] = []
        if server.isEnabled {
            if !isNew { ops.append(.remove(path)) } // the default is enabled
            ops += disabledListOperations(removing: server.name, document: document)
        } else {
            ops.append(.set(path, .bool(false)))
        }
        return ops
    }

    /// Grok also keeps `disabled_mcp_servers = [...]`; take the name out when enabling or removing.
    private func disabledListOperations(removing name: String, document: ConfigDocument) -> [ConfigOperation] {
        guard harness == .grok, let list = document.value(at: ["disabled_mcp_servers"])?.stringArray, list.contains(name) else { return [] }
        return [.set(["disabled_mcp_servers"], .strings(list.filter { $0 != name }))]
    }
}

// MARK: - Copying between harnesses (C-9)

/// What copying a server into another profile would stage.
public struct MCPCopyPlan: Sendable {
    /// The server as it will be written.
    public var server: MCPServer
    public var operations: [ConfigOperation]
    /// What doesn't carry over, in plain words.
    public var notes: [String]
}

extension MCPServerMapping {
    /// Plan copying `server` (read from any harness) into `document`, this mapping's file.
    /// Throws when the target can't hold it: an unsupported transport or a name that's taken.
    public func copyPlan(_ server: MCPServer, into document: ConfigDocument, as name: String? = nil) throws -> MCPCopyPlan {
        var copy = server
        copy.name = (name ?? server.name).trimmingCharacters(in: .whitespaces)
        copy.otherKeys = []
        guard transports.contains(copy.transport) else {
            throw ConfigEditError("\(harness.displayName) doesn't support \(copy.transport.rawValue.uppercased()) servers.")
        }
        if let error = copy.validationErrors.first { throw ConfigEditError(error + ".") }
        if servers(in: document).contains(where: { $0.name == copy.name }) {
            throw ConfigEditError("\(harness.displayName) already has a server named \(copy.name). Choose another name.")
        }
        var notes: [String] = []
        if !server.otherKeys.isEmpty {
            notes.append("Not copied: \(server.otherKeys.joined(separator: ", ")). These settings are specific to the source harness.")
        }
        if !server.isEnabled, !supportsDisabling {
            copy.isEnabled = true
            notes.append("\(harness.displayName) has no off switch for user servers, so the copy is on.")
        }
        return MCPCopyPlan(server: copy, operations: operations(from: nil, to: copy, document: document), notes: notes)
    }
}
