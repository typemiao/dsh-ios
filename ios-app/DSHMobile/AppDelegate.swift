import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 1. Start the nodejs-mobile engine (background thread, owns its own run loop).
        NodeRunner.shared.start()

        // 2. Build the UI: a single full-screen WKWebView pointed at the dsh web service.
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = WebViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NodeRunner.shared.stop()
    }
}
