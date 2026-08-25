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
final class WebViewController: UIViewController, WKScriptMessageHandler {

    private var webView: WKWebView!
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

    private var webConsoleLogPath: String {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("dsh-web-console.log").path
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        // Build the webview with a content controller that mirrors JS console
        // output (and uncaught errors) back to Swift, so a dsh UI action that
        // silently fails is visible in the exported diagnostics.
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(self, name: "dshLog")
        let mirrorJS = """
        (function(){
          function send(t){ try{ window.webkit.messageHandlers.dshLog.postMessage(t) }catch(e){} }
          const origErr = console.error, origWarn = console.warn, origLog = console.log;
          console.error = function(){ send('error ' + Array.prototype.slice.call(arguments).join(' ')); origErr.apply(console, arguments) };
          console.warn  = function(){ send('warn '  + Array.prototype.slice.call(arguments).join(' ')); origWarn.apply(console, arguments) };
          console.log   = function(){ send('log '   + Array.prototype.slice.call(arguments).join(' ')); origLog.apply(console, arguments) };
          window.onerror = function(m, s, l, c, e){ send('onerror ' + m + ' @' + s + ':' + l) };
          window.addEventListener('unhandledrejection', function(ev){ send('unhandledrejection ' + (ev && ev.reason ? String(ev.reason) : '?')) });
        })();
        """
        userController.addUserScript(WKUserScript(source: mirrorJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = userController
        let mkWebView = WKWebView(frame: .zero, configuration: config)
        webView = mkWebView

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

    /// Mirror WKWebView JS console/error messages into a file so a dsh UI
    /// action that silently fails (workspace select / new session) is visible.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        let line = "[\(ISO8601())] \(text)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: webConsoleLogPath)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func ISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    /// Write the console log + probes to Documents and hand a share sheet so the
    /// log can be exported (AirDrop / Files / etc) without a device shell.
    @objc private func exportDiagnostics() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let export = base.appendingPathComponent("dsh-diagnostics.txt")
        var payload = ""
        for path in [consoleLogPath, webConsoleLogPath] {
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
