import Foundation

/// Entry point: MCP stdio server (default) or `--cli <command>` debug mode.
enum EntryPoint {
    static let usage = """
    macos-ax-mcp \(ServerInfo.version) — native macOS Accessibility MCP server

    USAGE:
      macos-ax-mcp [--verbose]                      Run as MCP stdio server (newline-delimited JSON-RPC)
      macos-ax-mcp --cli <command> [options]        Run one tool and print JSON

    COMMANDS:
      check-health  [--prompt]
      list-windows  [--app NAME]
      snapshot      --app NAME [--scope dialog|front_window|all_windows] [--max-depth N] [--max-nodes N] [--include-web]
      handle-dialog --file PATH [--app NAME] [--timeout-ms N] [--no-restore-focus]
      list-tools
      call          TOOL_NAME ['{"json":"arguments"}']

    OPTIONS:
      --verbose     Mirror diagnostics to stderr (always appended to /tmp/macos-ax-mcp.log)
      --version     Print version
    """

    static func run(_ argv: [String]) -> Int32 {
        var args = argv
        if let i = args.firstIndex(of: "--verbose") { Log.verbose = true; args.remove(at: i) }
        if args.contains("--version") { print(ServerInfo.version); return 0 }
        if args.contains("--help") || args.contains("-h") { print(usage); return 0 }

        if let i = args.firstIndex(of: "--cli") {
            args.remove(at: i)
            return CLI.run(args)
        }
        if !args.isEmpty {
            FDWriter.writeLine("unknown arguments: \(args.joined(separator: " "))\n\n\(usage)", fd: STDERR_FILENO)
            return 2
        }

        // Protect protocol purity: protocol frames go to a private dup of fd 1, and fd 1 itself is pointed at
        // stderr so that any stray print()/framework output can never corrupt the JSON-RPC stream.
        let protocolFD = dup(STDOUT_FILENO)
        if protocolFD >= 0 { dup2(STDERR_FILENO, STDOUT_FILENO) }
        MCPServer(registry: .makeDefault()).runStdio(outputFD: protocolFD >= 0 ? protocolFD : STDOUT_FILENO)
        return 0
    }
}

enum CLI {
    struct UsageError: Error { let message: String }

    static func run(_ argv: [String]) -> Int32 {
        guard let command = argv.first else {
            FDWriter.writeLine(EntryPoint.usage, fd: STDERR_FILENO)
            return 2
        }
        let rest = Array(argv.dropFirst())
        let registry = ToolRegistry.makeDefault()
        do {
            let (tool, arguments): (String, [String: JSONValue])
            switch command {
            case "check-health":
                tool = "os_check_health"
                arguments = ["prompt_permission": .bool(rest.contains("--prompt"))]
            case "list-windows":
                tool = "os_list_windows"
                arguments = try options(rest, strings: ["--app": "app_name"])
            case "snapshot":
                tool = "os_ax_snapshot"
                arguments = try options(rest, strings: ["--app": "app_name", "--scope": "scope"],
                                        ints: ["--max-depth": "max_depth", "--max-nodes": "max_nodes"],
                                        flags: ["--include-web": ("include_web_content", true)])
            case "handle-dialog":
                tool = "os_handle_file_dialog"
                arguments = try options(rest, strings: ["--file": "file_path", "--app": "app_name"],
                                        ints: ["--timeout-ms": "timeout_ms"],
                                        flags: ["--no-restore-focus": ("restore_focus", false)])
            case "list-tools":
                print(JSONValue.object(["tools": registry.listJSON()]).prettyString())
                return 0
            case "call":
                guard let name = rest.first else { throw UsageError(message: "call requires a tool name") }
                tool = name
                if rest.count > 1 {
                    guard case .object(let o) = try JSONValue.parse(rest[1]) else {
                        throw UsageError(message: "arguments must be a JSON object")
                    }
                    arguments = o
                } else {
                    arguments = [:]
                }
            default:
                throw UsageError(message: "unknown command '\(command)'")
            }
            guard let outcome = registry.call(name: tool, arguments: arguments) else {
                throw UsageError(message: "unknown tool '\(tool)'")
            }
            print(outcome.payload.prettyString())
            return outcome.isError ? 1 : 0
        } catch let e as UsageError {
            FDWriter.writeLine("error: \(e.message)\n\n\(EntryPoint.usage)", fd: STDERR_FILENO)
            return 2
        } catch {
            FDWriter.writeLine("error: \(error)", fd: STDERR_FILENO)
            return 2
        }
    }

    private static func options(_ argv: [String], strings: [String: String] = [:], ints: [String: String] = [:],
                                flags: [String: (String, Bool)] = [:]) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if let (key, v) = flags[a] {
                out[key] = .bool(v)
                i += 1
                continue
            }
            guard strings[a] != nil || ints[a] != nil else { throw UsageError(message: "unknown option '\(a)'") }
            guard i + 1 < argv.count else { throw UsageError(message: "option '\(a)' needs a value") }
            let v = argv[i + 1]
            if let key = strings[a] {
                out[key] = .string(v)
            } else if let key = ints[a] {
                guard let n = Int(v) else { throw UsageError(message: "option '\(a)' needs an integer") }
                out[key] = .int(n)
            }
            i += 2
        }
        return out
    }
}

signal(SIGPIPE, SIG_IGN)
exit(EntryPoint.run(Array(CommandLine.arguments.dropFirst())))
