import Foundation
import NodeMobile

/**
 * Thin wrapper around the nodejs-mobile engine.
 *
 * The engine runs on a private background thread and blocks it for the
 * lifetime of the process; all JavaScript land lives there. We hand it:
 *   argv[1] -> tiny bootstrap.js in the signed app bundle
 *   argv[2] -> single dsh payload archive in the signed app bundle
 *   argv[3] -> versioned runtime directory below Application Support
 *   argv[-3...] -> writable DSH_HOME, console mirror path, milestone phase
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
        let archive = resources.appendingPathComponent("dsh-dist.tar.gz")
        let versionURL = resources.appendingPathComponent("dsh-dist.version")
        precondition(FileManager.default.fileExists(atPath: bootstrap.path),
                     "missing bootstrap.js in app bundle")
        precondition(FileManager.default.fileExists(atPath: archive.path),
                     "missing dsh-dist.tar.gz in app bundle")
        precondition(FileManager.default.fileExists(atPath: versionURL.path),
                     "missing dsh-dist.version in app bundle")
        let version = (try? String(contentsOf: versionURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        precondition(!version.isEmpty && version != "unknown", "invalid dsh-dist.version")
        let runtime = Self.runtimePath(version: version)

        // Keep a strong reference so the tailer keeps reading while the app runs.
        ConsoleTailer.shared.start(logPath: Self.nodeConsoleLogPath())

        engineThread = Thread { [weak self] in
            guard let self else { return }
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("node"),
                // NOTE: do NOT pass --expose-internals here. With it, the cordis
                // loader switches to the direct require('internal/modules/esm/loader')
                // path, which fails on nodejs-mobile (Node 22.9 + jitless) with
                // "loader entries failed to apply". The pure-JS
                // node-addon-require-builtin shim (process.getBuiltinModule)
                // reaches the internal loader and boots the tree — the exact path
                // the Linux smoke test validates. bootstrap imports the
                // extracted main.js in this same engine (never call node_start twice).
                strdup(bootstrap.path),
                strdup(archive.path),
                strdup(runtime),
                strdup(version),
                // Keep these LAST: main.js deliberately parses rest.slice(-3).
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
