import UIKit
import WebKit
import CoreLocation

/// The whole app: one full-screen web view showing alpineops.eu/apps/oneturn, plus the native help the page
/// needs inside an app: location from the phone's GPS (CoreLocation), keeping the screen on while driving,
/// saving the backup file through the share sheet, and opening other websites in Safari.
final class WebViewController: UIViewController {
    private static let home = URL(string: "https://alpineops.eu/apps/oneturn/")!
    private static let site = "alpineops.eu"

    private var web: WKWebView!
    private let location = CLLocationManager()
    private var wantsLocation = false
    private var offline: UIView?
    private var downloads: [ObjectIdentifier: URL] = [:]
    private let guide = FloatingGuide()       // floating window with the next turn while you are in another app
    private var tracker: GuideTracker?        // set while driving
    private var lastFix: CLLocation?
    private var guideTimer: Timer?

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.limitsNavigationsToAppBoundDomains = true   // see WKAppBoundDomains in Info.plist
        config.websiteDataStore = .default()                // settings, learning and prices are kept between launches
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: Bridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let handler = WeakHandler(self)
        scripts.add(handler, name: "geo")
        scripts.add(handler, name: "wake")
        scripts.add(handler, name: "nav")
        config.userContentController = scripts

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .white
        if #available(iOS 16.4, *) { web.isInspectable = true }   // lets Safari on a Mac look inside, for fixing problems

        let root = UIView()
        root.backgroundColor = .white
        web.frame = root.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(web)
        guide.attach(to: root)
        view = root

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.distanceFilter = kCLDistanceFilterNone
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        web.load(URLRequest(url: Self.home))
        NotificationCenter.default.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appActive() { guide.appBecameActive() }

    // MARK: - Driving: the route from the page, followed here so the floating window keeps up in the background

    private func navStart(_ route: GuideRoute) {
        tracker = GuideTracker(route)
        location.allowsBackgroundLocationUpdates = true      // keep following the car when you leave the app
        location.showsBackgroundLocationIndicator = true
        if location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways { location.startUpdatingLocation() }
        guide.start(guideState())
        guideTimer?.invalidate()
        guideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshGuide() }   // arrival time moves on even when standing still
    }

    private func navEnd() {
        tracker = nil
        guideTimer?.invalidate(); guideTimer = nil
        guide.stop()
        location.allowsBackgroundLocationUpdates = false
        if !wantsLocation { location.stopUpdatingLocation() }
    }

    private func guideState() -> GuideState {
        guard let t = tracker, let fix = lastFix ?? location.location else { return GuideState() }
        return t.state(at: fix)
    }

    private func refreshGuide() {
        guard tracker != nil else { return }
        guide.show(guideState())
    }

    // MARK: - No connection at launch (and no saved copy yet)

    private func showOffline(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        guard offline == nil else { return }
        let box = UIView(frame: view.bounds)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.backgroundColor = .white
        let label = UILabel()
        label.text = "OneTurn could not load.\nCheck your connection and try again."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .darkGray
        label.font = .preferredFont(forTextStyle: .body)
        let button = UIButton(type: .system)
        button.setTitle("Try again", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(retry), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 24),
        ])
        view.addSubview(box)
        offline = box
    }

    private func hideOffline() {
        offline?.removeFromSuperview()
        offline = nil
    }

    @objc private func retry() {
        hideOffline()
        web.load(URLRequest(url: Self.home))
    }

    private func isOurSite(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == Self.site || host.hasSuffix("." + Self.site)
    }
}

// MARK: - Messages from the page (see Bridge.script)

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        switch message.name {
        case "geo":
            if (body["op"] as? String) == "start" { startLocation() } else { stopLocation() }
        case "wake":
            UIApplication.shared.isIdleTimerDisabled = (body["on"] as? Bool) ?? false
        case "nav":
            switch body["op"] as? String {
            case "route": if let r = GuideRoute(body) { navStart(r) }
            case "status": tracker?.update(extra: body["extra"] as? Double, arr: body["arr"] as? Int); refreshGuide()
            case "end": navEnd()
            default: break
            }
        default:
            break
        }
    }
}

/// Holds the page's message handlers without keeping the view controller alive forever.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Location from the phone's GPS, handed to the page as navigator.geolocation

extension WebViewController: CLLocationManagerDelegate {
    private static let deniedText = "Location is off for OneTurn. Turn it on in Settings > OneTurn > Location."

    private func startLocation() {
        wantsLocation = true
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            sendError(1, Self.deniedText)
        default:
            location.startUpdatingLocation()
            if let last = location.location, -last.timestamp.timeIntervalSinceNow < 10 { send(last) }
        }
    }

    private func stopLocation() {
        wantsLocation = false
        if tracker == nil { location.stopUpdatingLocation() }   // still driving: the floating window needs it
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsLocation else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            sendError(1, Self.deniedText)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        lastFix = last
        if UIApplication.shared.applicationState != .background { send(last) }   // the page is paused in the background
        refreshGuide()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        if code == .locationUnknown { return }   // temporary: the phone keeps trying
        sendError(code == .denied ? 1 : 2, error.localizedDescription)
    }

    private func send(_ l: CLLocation) {
        var p: [String: Any] = [
            "lat": l.coordinate.latitude, "lon": l.coordinate.longitude,
            "acc": l.horizontalAccuracy, "t": l.timestamp.timeIntervalSince1970 * 1000,
        ]
        if l.verticalAccuracy >= 0 { p["alt"] = l.altitude; p["altAcc"] = l.verticalAccuracy }
        if l.course >= 0 { p["hdg"] = l.course }
        if l.speed >= 0 { p["spd"] = l.speed }
        callPage("pos", p)
    }

    private func sendError(_ code: Int, _ message: String) {
        callPage("err", ["code": code, "message": message])
    }

    private func callPage(_ kind: String, _ data: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: data),
              let text = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.__oneturnGeo && window.__oneturnGeo('\(kind)', \(text))", completionHandler: nil)
    }
}

// MARK: - Page loading, other websites, downloads

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["blob", "data", "about"].contains(scheme) { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame != false && !isOurSite(url) {
            UIApplication.shared.open(url)   // other websites, phone numbers, maps: outside the app
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideOffline()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOffline(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()   // iOS ended the page to free memory: start it again (a drive in progress resumes by itself)
    }
}

/// The backup file from Settings > Export: offered in the share sheet (Save to Files, AirDrop, Mail...).
extension WebViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedFilename.isEmpty ? "oneturn-backup.json" : suggestedFilename)
        downloads[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }
}

// MARK: - New windows, and the page's alert / confirm / prompt boxes

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isOurSite(url) { webView.load(navigationAction.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard presentedViewController == nil else { completionHandler(); return }
        let box = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        box.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(box, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else { completionHandler(false); return }
        let box = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        box.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        box.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(box, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard presentedViewController == nil else { completionHandler(nil); return }
        let box = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        box.addTextField { $0.text = defaultText }
        box.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        box.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(box.textFields?.first?.text) })
        present(box, animated: true)
    }
}
