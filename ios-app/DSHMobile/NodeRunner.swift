import Foundation
import NodeMobile

/**
 * Thin wrapper around the nodejs-mobile engine.
 *
 * All runtime config is passed through ENVIRONMENT VARIABLES (not argv position)
 * because nodejs-mobile's `process.argv[0]` is the script path, not the "node"
 * binary, so positional argv assumptions are fragile. The engine runs on a
 * private background thread and blocks it for the lifetime of the process.
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

    /// Absolute path of the mirror log bootstrap/main.js write console output to.
    static func nodeConsoleLogPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("node-console.log").path
    }

    /// Versioned runtime destination for the extracted, re-creatable dsh payload.
    static func runtimePath(version: String) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtimeRoot = base.appendingPathComponent("dsh-runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = runtimeRoot
        try? mutableRoot.setResourceValues(values)
        return runtimeRoot.appendingPathComponent(version, isDirectory: true).path
    }

    private let queue = DispatchQueue(label: "nodejs-mobile", qos: .userInitiated)
    private var engineThread: Thread?
    private var exitCode: Int32 = 0

    private init() {}

    func start() {
        // Tear down any stale mirror log before booting (fresh run).
        try? FileManager.default.removeItem(atPath: Self.nodeConsoleLogPath())

        let resources = Bundle.main.resourceURL!
        let bootstrap = resources.appendingPathComponent("bootstrap.js")
        let archive = resources.appendingPathComponent("dsh_payload.bin")
        let versionURL = resources.appendingPathComponent("dsh-dist.version")

        precondition(FileManager.default.fileExists(atPath: bootstrap.path),
                     "missing bootstrap.js in app bundle")
        precondition(FileManager.default.fileExists(atPath: archive.path),
                     "missing dsh_payload.bin in app bundle")
        precondition(FileManager.default.fileExists(atPath: versionURL.path),
                     "missing dsh-dist.version in app bundle")
        let version = (try? String(contentsOf: versionURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        precondition(!version.isEmpty && version != "unknown", "invalid dsh-dist.version")
        let runtime = Self.runtimePath(version: version)

        // Inject config so bootstrap.js reads process.env.DSH_* — position-independent.
        setenv("DSH_ARCHIVE", archive.path, 1)
        setenv("DSH_RUNTIME", runtime, 1)
        setenv("DSH_VERSION", version, 1)
        setenv("DSH_HOME", Self.dshHome(), 1)
        setenv("DSH_CONSOLE_LOG", Self.nodeConsoleLogPath(), 1)
        setenv("DSH_PHASE", ProcessInfo.processInfo.environment["DSH_IOS_PHASE"] ?? "1", 1)

        // Keep a strong reference so the tailer keeps reading while the app runs.
        ConsoleTailer.shared.start(logPath: Self.nodeConsoleLogPath())

        engineThread = Thread { [weak self] in
            guard let self else { return }
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("node"),
                strdup(bootstrap.path),
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
