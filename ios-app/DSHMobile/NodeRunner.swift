import Foundation
import NodeMobile

/**
 * Thin wrapper around the nodejs-mobile engine.
 *
 * The engine runs on a private background thread and blocks it for the
 * lifetime of the process; all JavaScript land lives there. We hand it:
 *   argv[1] -> absolute path of nodejs-project/main.js in the app bundle
 *   argv[2] -> absolute path of the writable DSH_HOME (created in Application Support)
 *
 * stdout/stderr from the engine do not reach the Xcode console by default on
 * iOS, so main.js mirrors console output to a log file in the sandbox
 * (`node-console.log`) which ConsoleTailer tails into NSLog.
 */
final class NodeRunner {

    static let shared = NodeRunner()

    /// Absolute path of the writable DSH_HOME directory (inside the sandbox).
    static func dshHome() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let home = base.appendingPathComponent("dsh", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path
    }

    /// Absolute path of the mirror log main.js writes console output to.
    static func nodeConsoleLogPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("node-console.log").path
    }

    private let queue = DispatchQueue(label: "nodejs-mobile", qos: .userInitiated)
    private var engineThread: Thread?
    private var exitCode: Int32 = 0

    private init() {}

    func start() {
        // Tear down any stale mirror log before booting (fresh run).
        try? FileManager.default.removeItem(atPath: Self.nodeConsoleLogPath())

        let mainScript = Bundle.main.resourceURL!
            .appendingPathComponent("nodejs-project")
            .appendingPathComponent("main.js")
        precondition(FileManager.default.fileExists(atPath: mainScript.path),
                     "missing nodejs-project/main.js in app bundle")

        // Keep a strong reference so the tailer keeps reading while the app runs.
        ConsoleTailer.shared.start(logPath: Self.nodeConsoleLogPath())

        engineThread = Thread { [weak self] in
            guard let self else { return }
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("node"),
                // Expose Node internals so the vendored cordis loader can reach
                // internal/modules/esm/loader through the plain require path
                // (the node-addon-require-builtin shim cannot on its own).
                strdup("--expose-internals"),
                strdup(mainScript.path),
                strdup(Self.dshHome()),
                strdup(Self.nodeConsoleLogPath()),
                strdup(ProcessInfo.processInfo.environment["DSH_IOS_PHASE"] ?? "1"),
            ]
            argv.append(nil)
            self.exitCode = node_start(Int32(argv.count - 1), &argv)
            NSLog("[nodejs-mobile] node_start returned %d", self.exitCode)
        }
        engineThread?.name = "nodejs-mobile-engine"
        engineThread?.start()
    }

    func stop() {
        engineThread?.cancel()
    }
}
