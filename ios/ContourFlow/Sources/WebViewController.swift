import AVFoundation
import UIKit
import WebKit

final class WebViewController: UIViewController {

    private let configuration = WKWebViewConfiguration()
    private lazy var webView = WKWebView(frame: .zero, configuration: configuration)
    private var server: LocalServer?
    private var overlay: UIStackView?
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private var audioSessionActive = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureAudioSession()
        setUpWebView()
        setUpOverlay()
        startServer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: - Setup

    private func setUpWebView() {
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // Keep the web content edge to edge so env(safe-area-inset-*) resolves.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setUpOverlay() {
        spinner.color = .white
        spinner.hidesWhenStopped = true

        statusLabel.text = "Starting Contour Flow…"
        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        overlay = stack
        spinner.startAnimating()
    }

    private func startServer() {
        guard let root = Bundle.main.resourceURL else {
            showFailure("The app bundle is missing its web resources.")
            return
        }

        let server = LocalServer(root: root)
        self.server = server
        server.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.webView.load(URLRequest(url: url))
                case .failure(let error):
                    self.showFailure("The local server could not start: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Audio

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.measurement` skips the voice-processing chain, which otherwise
            // high-passes the microphone and removes the low end that the
            // patterns react to.
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            // Only re-activate once capture has been requested at least once,
            // so simply opening the app does not interrupt other audio.
            if audioSessionActive {
                try session.setActive(true)
            }
        } catch {
            NSLog("[ContourFlow] Audio session setup failed: %@", error.localizedDescription)
        }
    }

    private func activateAudioSessionForCapture() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActive = true
        } catch {
            NSLog("[ContourFlow] Activating audio session failed: %@", error.localizedDescription)
        }
    }

    @objc private func applicationDidBecomeActive() {
        configureAudioSession()
    }

    // MARK: - UI

    private func showFailure(_ message: String) {
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            self.statusLabel.text = message
        }
    }

    private func hideOverlay() {
        overlay?.isHidden = true
    }

    // MARK: - Capture permission

    private func requestCaptureAccess(for type: WKMediaCaptureType,
                                      completion: @escaping (Bool) -> Void) {
        activateAudioSessionForCapture()

        switch type {
        case .camera:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        case .cameraAndMicrophone:
            AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    completion(videoGranted && audioGranted)
                }
            }
        @unknown default:
            completion(true)
        }
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {

    /// Without this, WKWebView silently denies getUserMedia and the page only
    /// sees a NotAllowedError that looks like a user refusal.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        requestCaptureAccess(for: type) { granted in
            DispatchQueue.main.async {
                decisionHandler(granted ? .grant : .deny)
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideOverlay()
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        showFailure("The page could not be loaded: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showFailure("The page could not be loaded: \(error.localizedDescription)")
    }

    /// Keep navigation inside the app; nothing here should open Safari.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
}
