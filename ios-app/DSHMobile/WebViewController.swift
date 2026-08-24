import UIKit
import WebKit

/**
 * Phase 3 surface: a full-screen WKWebView pointed at the dsh web service.
 *
 * Polls http://127.0.0.1:3080 until the Node server answers, then loads it.
 * Shows a simple placeholder with the boot log until then.
 */
final class WebViewController: UIViewController {

    private let webView = WKWebView(frame: .zero)
    private let statusLabel = UILabel()
    private let url = URL(string: "http://127.0.0.1:3080")!
    private var pollTimer: Timer?
    private var attempts = 0

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "starting dsh…"

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true

        view.addSubview(statusLabel)
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    private func poll() {
        attempts += 1
        let request = URLRequest(url: url, timeoutInterval: 2)
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                    self.statusLabel.isHidden = true
                    self.webView.isHidden = false
                    self.pollTimer?.invalidate()
                    self.webView.load(URLRequest(url: self.url))
                } else if self.attempts > 1200 {
                    self.statusLabel.text = "dsh did not come up on \(self.url.absoluteString)\n(\(error?.localizedDescription ?? "no response"))"
                    self.pollTimer?.invalidate()
                } else {
                    self.statusLabel.text = "waiting for dsh… (attempt \(self.attempts))"
                }
            }
        }.resume()
    }
}
