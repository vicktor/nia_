// SPDX-License-Identifier: MPL-2.0
import Foundation
import AppKit

@main struct NiaUpdateInstaller {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
              let job = try? JSONDecoder().decode(NiaUpdateJob.self, from: data),
              (try? job.validatePaths()) != nil else { exit(1) }
        func running() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.nia.terminal").contains {
                $0.processIdentifier == job.parentPID ||
                $0.bundleURL?.resolvingSymlinksInPath() == job.destination.resolvingSymlinksInPath()
            }
        }
        func result(_ success: Bool, _ message: String? = nil) {
            if let data = try? JSONEncoder().encode(NiaUpdateResult(success: success, message: message)) {
                try? data.write(to: job.resultURL, options: .atomic)
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while running() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard !running() else { result(false, NiaUpdateError.timeout.rawValue); exit(1) }
        do {
            try NiaUpdateInstallation.install(job, isRunning: running) { app in
                // Persist before opening: the new process consumes this result.
                result(true)
                try NiaUpdateInstallation.run("/usr/bin/open", ["-n", app.path])
            }
        } catch {
            result(false, (error as? NiaUpdateError)?.rawValue ?? NiaUpdateError.install.rawValue)
            if !running() { try? NiaUpdateInstallation.run("/usr/bin/open", ["-n", job.destination.path]) }
            exit(1)
        }
    }
}
