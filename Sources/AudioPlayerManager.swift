import UIKit
import WebKit
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AudioPlayerManager()
    
    private var webView: WKWebView!
    private(set) var isPlaying = false
    private(set) var currentSong: SongItem?
    private var isPlayerPageLoaded = false
    
    var onStateChanged: ((Bool, String) -> Void)?

    private override init() {
        super.init()
        setupAudioSession()
        setupWebView()
        setupRemoteCommands()
        setupBackgroundObserver()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        
        let contentController = WKUserContentController()
        contentController.add(self, name: "nativeBridge")

        // 1. Suntikkan pemantau video lebih awal (atDocumentEnd) tanpa menunggu seluruh gambar halaman selesai
        let earlyHookJS = """
        (function() {
            if (window.__metroHookInstalled) return;
            window.__metroHookInstalled = true;
            setInterval(function() {
                var video = document.querySelector('video');
                if (video && !video.__hooked) {
                    video.__hooked = true;
                    video.muted = false;
                    video.volume = 1.0;
                    video.play().catch(function(e) {});
                    
                    video.addEventListener('playing', function() {
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'playing' });
                    });
                    video.addEventListener('pause', function() {
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'paused' });
                    });
                    video.addEventListener('ended', function() {
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'ended' });
                    });
                }
            }, 150);
        })();
        """
        let userScript = WKUserScript(source: earlyHookJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        config.userContentController = contentController

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"

        // 2. Blokir gambar & font di halaman web YouTube agar loading audio jauh lebih ringan & cepat
        let blockRules = """
        [
            {
                "trigger": { "url-filter": ".*", "resource-type": ["image", "font"] },
                "action": { "type": "block" }
            }
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BlockHeavyAssets", encodedContentRuleList: blockRules) { [weak self] ruleList, _ in
            if let ruleList = ruleList {
                self?.webView.configuration.userContentController.add(ruleList)
            }
        }
    }

    func attachToWindow(_ window: UIWindow?) {
        guard let window = window, webView.superview == nil else { return }
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        window.addSubview(webView)
    }

    func play(song: SongItem) {
        currentSong = song
        isPlaying = true
        updateNowPlayingInfo(song: song)
        onStateChanged?(true, "Memuat: \(song.title)...")

        // 3. Jika halaman YouTube sudah terbuka sebelumnya, pindah lagu secara internal (SPA) tanpa reload halaman
        if isPlayerPageLoaded {
            let spaNavigateJS = """
            (function() {
                var a = document.createElement('a');
                a.href = '/watch?v=\(song.videoId)';
                document.body.appendChild(a);
                a.click();
                a.remove();
            })();
            """
            webView.evaluateJavaScript(spaNavigateJS) { [weak self] _, error in
                if error != nil {
                    self?.loadWatchURL(videoId: song.videoId)
                }
            }
        } else {
            loadWatchURL(videoId: song.videoId)
        }
    }

    private func loadWatchURL(videoId: String) {
        if let watchURL = URL(string: "https://m.youtube.com/watch?v=\(videoId)") {
            var request = URLRequest(url: watchURL)
            request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
            webView.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPlayerPageLoaded = true
    }

    func togglePlayPause() {
        guard let song = currentSong else { return }
        if isPlaying {
            webView.evaluateJavaScript("var v = document.querySelector('video'); if(v) v.pause();", completionHandler: nil)
            isPlaying = false
        } else {
            webView.evaluateJavaScript("var v = document.querySelector('video'); if(v) { v.play(); 'ok'; } else { 'reload'; }") { [weak self] result, _ in
                if let res = result as? String, res == "reload" {
                    self?.loadWatchURL(videoId: song.videoId)
                }
            }
            isPlaying = true
        }
        updateNowPlayingInfo(song: song)
        onStateChanged?(isPlaying, "\(song.title) - \(song.artist)")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let status = body["status"] as? String,
              let song = currentSong else { return }

        switch status {
        case "playing":
            isPlaying = true
            onStateChanged?(true, "\(song.title) - \(song.artist)")
            updateNowPlayingInfo(song: song)
        case "paused":
            isPlaying = false
            onStateChanged?(false, "\(song.title) - \(song.artist)")
        case "ended":
            isPlaying = false
            onStateChanged?(false, "Selesai: \(song.title)")
        default:
            break
        }
    }

    private func setupBackgroundObserver() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.webView.evaluateJavaScript("var v = document.querySelector('video'); if(v && v.paused) v.play();", completionHandler: nil)
            }
        }
    }

    private func updateNowPlayingInfo(song: SongItem) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
    }
}