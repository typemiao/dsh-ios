import Foundation
import Darwin
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

    /// Writable dsh workspace: Documents/workspace, exposed to the Files app via
    /// UIFileSharingEnabled so the user can drop files into it.
    static func dshWorkspace() -> String {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace.path
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

        // Swift-side diagnostic: record resource presence + the paths node gets,
        // so if node never writes a log we can tell whether the app even reached
        // node_start and whether the bundle contained the resources.
        let bootstrapExists = FileManager.default.fileExists(atPath: bootstrap.path)
        let archiveExists = FileManager.default.fileExists(atPath: archive.path)
        let versionExists = FileManager.default.fileExists(atPath: versionURL.path)
        let swiftProbe = (Self.dshHome() as NSString).appendingPathComponent("dsh-swift-probe.txt")
        let swiftLog = "bootstrap=\(bootstrapExists) archive=\(archiveExists) version=\(versionExists)\n" +
            "bootstrapPath=\(bootstrap.path)\narchivePath=\(archive.path)\nversionPath=\(versionURL.path)\n" +
            "resources=\(resources.path)\n"
        try? swiftLog.write(toFile: swiftProbe, atomically: true, encoding: .utf8)

        precondition(bootstrapExists, "missing bootstrap.js in app bundle")
        precondition(archiveExists, "missing dsh_payload.bin in app bundle")
        precondition(versionExists, "missing dsh-dist.version in app bundle")
        let version = (try? String(contentsOf: versionURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        precondition(!version.isEmpty && version != "unknown", "invalid dsh-dist.version")
        let runtime = Self.runtimePath(version: version)

        // Pass config BOTH as env vars and as trailing argv (nodejs-mobile's
        // process.argv semantics are uncertain on device; the probe will confirm
        // which channel node actually sees). position independent.
        let dshHome = Self.dshHome()
        let consoleLog = Self.nodeConsoleLogPath()
        // This shell's only job is to boot the dsh web UI (phase 3). Real device
        // installs (Sideloadly) never inject DSH_IOS_PHASE (the simulator worked
        // only because run-simulator.sh passed SIMCTL_CHILD_DSH_IOS_PHASE), so
        // default to 3 and let the env var only override if explicitly set.
        let phase = ProcessInfo.processInfo.environment["DSH_IOS_PHASE"] ?? "3"
        let probeLog = (dshHome as NSString).appendingPathComponent("dsh-probe.txt")
        setenv("DSH_ARCHIVE", archive.path, 1)
        setenv("DSH_RUNTIME", runtime, 1)
        setenv("DSH_VERSION", version, 1)
        setenv("DSH_HOME", dshHome, 1)
        setenv("DSH_CONSOLE_LOG", consoleLog, 1)
        setenv("DSH_PHASE", phase, 1)
        setenv("DSH_PROBE", probeLog, 1)
        setenv("DSH_WORKSPACE", Self.dshWorkspace(), 1)

        // Keep a strong reference so the tailer keeps reading while the app runs.
        ConsoleTailer.shared.start(logPath: consoleLog)

        engineThread = Thread { [weak self] in
            guard let self else { return }
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("node"),
                strdup(bootstrap.path),
                strdup(archive.path),
                strdup(runtime),
                strdup(version),
                strdup(dshHome),
                strdup(consoleLog),
                strdup(phase),
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
