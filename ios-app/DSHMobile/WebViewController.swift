import UIKit
import WebKit

/**
 * Phase 3 surface: a full-screen WKWebView pointed at the dsh web service.
 *
 * While dsh is coming up it shows the live node-console.log tail (so the user
 * sees unpack/boot progress) plus an "Export diagnostics" button that writes the
 * log (and probes) to Documents and opens a share sheet, so the log can be sent
 * back to the developer without any device-side shell.
 */
final class WebViewController: UIViewController {

    private let webView = WKWebView(frame: .zero)
    private let statusLabel = UILabel()
    private let progressLabel = UILabel()
    private let exportButton = UIButton(type: .system)
    private let url = URL(string: "http://127.0.0.1:3080")!
    private var pollTimer: Timer?
    private var attempts = 0

    private var consoleLogPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("node-console.log").path
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "starting dsh…"

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.numberOfLines = 0
        progressLabel.textAlignment = .center
        progressLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .tertiaryLabel
        progressLabel.text = ""

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.setTitle("导出诊断日志", for: .normal)
        exportButton.addTarget(self, action: #selector(exportDiagnostics), for: .touchUpInside)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true

        view.addSubview(webView)
        view.addSubview(statusLabel)
        view.addSubview(progressLabel)
        view.addSubview(exportButton)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            // Floating export button pinned to the top-right so it is reachable
            // even after dsh loads (over the webview), not just during startup.
            exportButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            exportButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        view.bringSubviewToFront(exportButton)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    private func poll() {
        attempts += 1
        updateProgressLabel()
        let request = URLRequest(url: url, timeoutInterval: 2)
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                    self.statusLabel.isHidden = true
                    self.progressLabel.isHidden = true
                    self.exportButton.isHidden = false   // keep reachable; dsh boot errors land in the log
                    self.webView.isHidden = false
                    self.pollTimer?.invalidate()
                    self.webView.load(URLRequest(url: self.url))
                } else {
                    self.statusLabel.text = "waiting for dsh… (attempt \(self.attempts))"
                    self.updateProgressLabel()
                }
            }
        }.resume()
    }

    /// Show the newest lines of node-console.log so unpack/boot progress is
    /// visible on device without any shell access.
    private func updateProgressLabel() {
        guard let text = try? String(contentsOfFile: consoleLogPath, encoding: .utf8) else {
            progressLabel.text = "(no log yet)"
            return
        }
        let lines = text.split(separator: "\n")
        let tail = lines.suffix(10).joined(separator: "\n")
        progressLabel.text = tail.isEmpty ? "(log empty)" : tail
    }

    /// Write the console log + probes to Documents and hand a share sheet so the
    /// log can be exported (AirDrop / Files / etc) without a device shell.
    @objc private func exportDiagnostics() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let export = base.appendingPathComponent("dsh-diagnostics.txt")
        var payload = ""
        for path in [consoleLogPath] {
            if let log = try? String(contentsOfFile: path, encoding: .utf8) {
                payload += "===== \(path) =====\n\(log)\n\n"
            } else {
                payload += "===== \(path) ===== (unreadable)\n\n"
            }
        }
        // Probes written next to the console log.
        let appSupport = base.deletingLastPathComponent().appendingPathComponent("Library/Application Support", isDirectory: true)
        for probe in ["dsh-probe.txt", "dsh-swift-probe.txt"] {
            let url = appSupport.appendingPathComponent("dsh").appendingPathComponent(probe)
            if let log = try? String(contentsOf: url, encoding: .utf8) {
                payload += "===== \(probe) =====\n\(log)\n\n"
            }
        }
        try? payload.write(to: export, atomically: true, encoding: .utf8)

        let activity = UIActivityViewController(activityItems: [export], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = exportButton
            popover.sourceRect = exportButton.bounds
        }
        present(activity, animated: true)
    }
}
