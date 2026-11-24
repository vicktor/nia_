// SPDX-License-Identifier: MPL-2.0
import Foundation

// The model is untrusted: only a deliberately small grammar may run automatically.
// No shell syntax, substitutions, pipelines, redirects or command chaining.
// Everything else stays in an editable review dialog.
enum NiaAIExecutionPolicy {
    private static let tokenCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./+@%:=-")

    private static func tokens(_ command: String) -> [String]? {
        guard command.utf8.count <= 1024, !command.isEmpty else { return nil }
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, tokens.count <= 32, tokens.allSatisfy({ !$0.isEmpty &&
            $0.unicodeScalars.allSatisfy { tokenCharacters.contains($0) } }) else { return nil }
        return tokens
    }
    private static func safePath(_ item: String) -> Bool {
        !item.isEmpty && !item.hasPrefix("-") && item != "/dev" && !item.hasPrefix("/dev/")
    }
    private static func safeFind(_ args: [String]) -> Bool {
        guard !args.isEmpty, safePath(args[0]) else { return false }
        var index = 1
        while index < args.count {
            let value = args[index]
            switch value {
            case "-type":
                index += 1
                guard index < args.count, ["f", "d", "l"].contains(args[index]) else { return false }
            case "-size":
                index += 1
                guard index < args.count,
                      args[index].range(of: "^[+-]?[0-9]{1,12}[ckMGTP]?$", options: .regularExpression) != nil else { return false }
            case "-print": break
            default: return false // No -exec, -delete, -ok, -prune, -name etc.
            }
            index += 1
        }
        return true
    }
    private static func safeLS(_ args: [String]) -> Bool {
        args.allSatisfy { arg in
            if arg.hasPrefix("-") {
                return arg.range(of: "^-[alhAtrS1F]+$", options: .regularExpression) != nil
            }
            return safePath(arg)
        }
    }
    private static func safeDu(_ args: [String]) -> Bool {
        args.allSatisfy { arg in
            if arg.hasPrefix("-") { return arg.range(of: "^-[ahsk]+$", options: .regularExpression) != nil }
            return safePath(arg)
        }
    }
    static func automaticCommand(_ generated: String) -> String? {
        guard let parts = tokens(generated) else { return nil }
        let args = Array(parts.dropFirst())
        switch parts[0] {
        case "pwd": return args.isEmpty ? "/bin/pwd" : nil
        case "whoami": return args.isEmpty ? "/usr/bin/whoami" : nil
        case "date": return args.isEmpty ? "/bin/date" : nil
        case "uptime": return args.isEmpty ? "/usr/bin/uptime" : nil
        case "ls": return safeLS(args) ? (["/bin/ls"] + args).joined(separator: " ") : nil
        case "du": return safeDu(args) ? (["/usr/bin/du"] + args).joined(separator: " ") : nil
        case "df": return args.isEmpty || args == ["-h"] ? (["/bin/df"] + args).joined(separator: " ") : nil
        case "find": return safeFind(args) ? (["/usr/bin/find"] + args).joined(separator: " ") : nil
        case "python3":
            guard args.count == 3 || args.count == 5,
                  args[0] == "-m", args[1] == "http.server",
                  let port = Int(args[2]), (1024...65535).contains(port) else { return nil }
            if args.count == 5 && (args[3] != "--bind" || args[4] != "127.0.0.1") { return nil }
            // Restrict the web server to loopback, never expose local files to LAN.
            return "python3 -m http.server \(port) --bind 127.0.0.1"
        default: return nil
        }
    }
}
