import Foundation

/**
 * Tails the `node-console.log` mirror file that main.js writes, forwarding
 * every new line to NSLog so it shows up in the Xcode console.
 */
final class ConsoleTailer {

    static let shared = ConsoleTailer()

    private var handle: FileHandle?
    private var timer: Timer?
    private var buffer = Data()

    private init() {}

    func start(logPath: String) {
        // Ensure the file exists (main.js creates it on boot).
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return }
        self.handle = handle
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.drain()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func drain() {
        guard let handle else { return }
        let data = handle.readDataToEndOfFile()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(data: buffer[..<newline], encoding: .utf8) ?? "<non-utf8>"
            NSLog("[node] %@", line)
            buffer.removeSubrange(...newline)
        }
    }

    deinit {
        timer?.invalidate()
        try? handle?.close()
    }
}
