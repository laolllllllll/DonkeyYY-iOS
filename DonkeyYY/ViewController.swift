import UIKit
import WebKit
import Photos

class ViewController: UIViewController, WKNavigationDelegate {

    var webView: WKWebView!
    var floatButton: UIButton!
    var floatStartPoint: CGPoint = .zero
    var floatBeginPoint: CGPoint = .zero
    var didMoveFloat = false

    let homeURL = "https://duys.k2sw9ni.live/"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        setupFloatButton()
        loadHome()
    }

    func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

        // 允许非HTTPS
        if #available(iOS 14.0, *) {
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            config.defaultWebpagePreferences = preferences
        } else {
            config.preferences.javaScriptEnabled = true
        }

        view.addSubview(webView)
    }

    func setupFloatButton() {
        floatButton = UIButton(type: .custom)
        floatButton.frame = CGRect(x: 20, y: 200, width: 56, height: 56)
        floatButton.backgroundColor = UIColor.white
        floatButton.layer.cornerRadius = 28
        floatButton.clipsToBounds = true
        if let logoImage = UIImage(named: "logo") {
            floatButton.setImage(logoImage, for: .normal)
            floatButton.imageView?.contentMode = .scaleAspectFit
        } else {
            floatButton.setTitle("驴", for: .normal)
            floatButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 24)
            floatButton.setTitleColor(.white, for: .normal)
            floatButton.backgroundColor = UIColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9)
        }
        floatButton.layer.shadowColor = UIColor.black.cgColor
        floatButton.layer.shadowOpacity = 0.5
        floatButton.layer.shadowOffset = CGSize(width: 2, height: 2)
        floatButton.layer.shadowRadius = 4

        floatButton.addTarget(self, action: #selector(floatButtonTapped), for: .touchUpInside)
        floatButton.addTarget(self, action: #selector(floatButtonDrag(_:with:)), for: .touchDragInside)
        floatButton.addTarget(self, action: #selector(floatButtonDrag(_:with:)), for: .touchDragOutside)

        view.addSubview(floatButton)
        view.bringSubviewToFront(floatButton)
    }

    @objc func floatButtonTapped() {
        if didMoveFloat {
            didMoveFloat = false
            return
        }
        findM3U8()
    }

    @objc func floatButtonDrag(_ button: UIButton, with event: UIEvent) {
        guard let touch = event.allTouches?.first else { return }
        let point = touch.location(in: view)

        switch touch.phase {
        case .began:
            floatBeginPoint = button.center
            floatStartPoint = point
            didMoveFloat = false
        case .moved:
            let dx = point.x - floatStartPoint.x
            let dy = point.y - floatStartPoint.y
            if abs(dx) > 5 || abs(dy) > 5 {
                didMoveFloat = true
            }
            button.center = CGPoint(x: floatBeginPoint.x + dx, y: floatBeginPoint.y + dy)
        default:
            break
        }
    }

    func loadHome() {
        if let url = URL(string: homeURL) {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - 查找m3u8
    func findM3U8() {
        showToast("正在查找m3u8...")

        // 直接读取HTML源码
        let js = "document.documentElement.outerHTML"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                print("JS error: \(error)")
                self.showToast("查找失败")
                return
            }

            guard let html = result as? String else {
                self.showToast("未找到m3u8")
                return
            }

            print("HTML length: \(html.count)")

            // 方法1：提取 src="...m3u8..."
            var m3u8Src: String? = nil

            let srcPattern = "src\\s*=\\s*[\"']([^\"']*\\.m3u8[^\"']*)[\"']"
            if let regex = try? NSRegularExpression(pattern: srcPattern, options: []) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        m3u8Src = String(html[range])
                        print("Found src m3u8: \(m3u8Src!)")
                        break
                    }
                }
            }

            // 方法2：宽泛匹配
            if m3u8Src == nil {
                let broadPattern = "[\"']([^\"']*\\.m3u8[^\"']*)[\"']"
                if let regex = try? NSRegularExpression(pattern: broadPattern, options: []) {
                    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                    for match in matches {
                        if let range = Range(match.range(at: 1), in: html) {
                            m3u8Src = String(html[range])
                            print("Found broad m3u8: \(m3u8Src!)")
                            break
                        }
                    }
                }
            }

            guard let src = m3u8Src else {
                self.showToast("未找到m3u8，请确保视频已加载")
                return
            }

            self.processM3U8(src: src)
        }
    }

    func processM3U8(src: String) {
        print("processM3U8: \(src)")

        // 提取cdn参数
        var cdn: String? = nil
        let cdnPattern = "cdn=([^&\"']+)"
        if let regex = try? NSRegularExpression(pattern: cdnPattern, options: []) {
            let matches = regex.matches(in: src, range: NSRange(src.startIndex..., in: src))
            for match in matches {
                if let range = Range(match.range(at: 1), in: src) {
                    cdn = String(src[range])
                    print("cdn: \(cdn!)")
                    break
                }
            }
        }

        var realURL = src

        // 处理 /api/app/vid/m3u8/ 格式
        if src.contains("/api/app/vid/m3u8/") {
            if let range = src.range(of: "/api/app/vid/m3u8/") {
                var realPath = String(src[range.upperBound...])
                if let qRange = realPath.range(of: "?") {
                    realPath = String(realPath[..<qRange.lowerBound])
                }
                print("realPath: \(realPath)")

                if let cdn = cdn, !cdn.isEmpty {
                    var c = cdn
                    if c.hasSuffix("/") { c.removeLast() }
                    realURL = "\(c)/\(realPath)"
                } else if let currentURL = webView.url {
                    realURL = "\(currentURL.scheme)://\(currentURL.host!)/\(realPath)"
                }
            }
        } else if src.hasPrefix("/") {
            // 相对路径
            if let currentURL = webView.url {
                realURL = "\(currentURL.scheme)://\(currentURL.host!)\(src)"
            }
        }

        print("Final m3u8 URL: \(realURL)")

        showDownloadDialog(m3u8URL: realURL)
    }

    func showDownloadDialog(m3u8URL: String) {
        let alert = UIAlertController(title: "找到m3u8文件", message: "是否下载并转换为MP4？\n\n\(m3u8URL)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "是", style: .default) { _ in
            M3U8Manager.shared.downloadAndConvert(m3u8URL: m3u8URL, from: self) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let videoURL):
                        self?.showSaveDialog(videoURL: videoURL)
                    case .failure(let error):
                        self?.showError(error: error)
                    }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "否", style: .cancel))
        present(alert, animated: true)
    }

    func showSaveDialog(videoURL: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        let sizeMB = Double(size) / 1024.0 / 1024.0

        let alert = UIAlertController(title: "转换完成", message: String(format: "文件大小: %.1f MB\n\n是否保存到相册？", sizeMB), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "是", style: .default) { _ in
            self.saveToGallery(videoURL: videoURL)
        })
        alert.addAction(UIAlertAction(title: "否", style: .cancel))
        present(alert, animated: true)
    }

    func saveToGallery(videoURL: URL) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            self.performSaveVideo(videoURL: videoURL)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self?.performSaveVideo(videoURL: videoURL)
                    } else {
                        self?.showToast("保存失败：未获得相册权限")
                    }
                }
            }
        case .denied, .restricted:
            showToast("保存失败：请在设置中开启相册权限")
        @unknown default:
            showToast("保存失败：未知权限状态")
        }
    }

    func performSaveVideo(videoURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.showToast("已保存到相册")
                } else if let error = error {
                    self?.showToast("保存失败: \(error.localizedDescription)")
                } else {
                    self?.showToast("保存失败")
                }
            }
        }
    }

    func showError(error: Error) {
        let alert = UIAlertController(title: "失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    func showToast(_ message: String) {
        let toast = UILabel(frame: CGRect(x: 0, y: 0, width: 250, height: 40))
        toast.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toast.textColor = .white
        toast.textAlignment = .center
        toast.font = UIFont.systemFont(ofSize: 14)
        toast.text = message
        toast.layer.cornerRadius = 20
        toast.clipsToBounds = true
        toast.alpha = 0
        view.addSubview(toast)

        UIView.animate(withDuration: 0.3, animations: { toast.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 1.5, options: [], animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("页面加载完成: \(webView.url?.absoluteString ?? "")")
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }
}
