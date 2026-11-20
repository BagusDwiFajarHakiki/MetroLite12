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
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    var onStateChanged: ((Bool, String, UIImage?) -> Void)?
    private var currentArtworkImage: UIImage?

    private override init() {
        super.init()
        setupAudioSession()
        setupWebView()
        setupRemoteCommands()
        setupLifecycleObservers()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
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

        // 1. Kunci kualitas video ke 144p ('tiny') untuk hemat kuota & palsukan Visibility API agar jalan di background
        let startJS = """
        (function() {
            try {
                var exp = Date.now() + 2592000000;
                localStorage.setItem('yt-player-quality', JSON.stringify({ data: 'tiny', expiration: exp, creation: Date.now() }));
                localStorage.setItem('yt-player-av1-pref', '144');
            } catch(e) {}

            Object.defineProperty(document, 'hidden', { get: function() { return false; } });
            Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; } });
            Object.defineProperty(document, 'webkitHidden', { get: function() { return false; } });
            Object.defineProperty(document, 'webkitVisibilityState', { get: function() { return 'visible'; } });
            
            var origAddEventListener = document.addEventListener;
            document.addEventListener = function(type, listener, options) {
                if (type === 'visibilitychange' || type === 'webkitvisibilitychange' || type === 'pagehide') {
                    return;
                }
                return origAddEventListener.call(document, type, listener, options);
            };
            window.addEventListener('pagehide', function(e) { e.stopImmediatePropagation(); }, true);
        })();
        """
        let startScript = WKUserScript(source: startJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(startScript)

        // 2. Paksa resolusi terendah pada player internal YouTube & sinkronkan status audio berjalan
        let endJS = """
        (function() {
            window.__userPaused = false;
            window.__reportedPlayingForSrc = "";
            
            setInterval(function() {
                var player = document.getElementById('movie_player');
                if (player && player.setPlaybackQualityRange) {
                    try { player.setPlaybackQualityRange('tiny', 'tiny'); } catch(e) {}
                }

                var video = document.querySelector('video');
                if (!video) return;

                if (!window.__userPaused) {
                    if (video.muted) video.muted = false;
                    if (video.volume < 1.0) video.volume = 1.0;
                    if (video.paused && !video.ended && video.readyState >= 2) {
                        video.play().catch(function(e) {});
                    }
                    if (!video.paused && video.readyState >= 3 && video.currentTime > 0.05) {
                        var sig = video.src + "_" + Math.floor(video.duration || 0);
                        if (window.__reportedPlayingForSrc !== sig) {
                            window.__reportedPlayingForSrc = sig;
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'playing' });
                        }
                    }
                }

                if (!video.__hooked) {
                    video.__hooked = true;
                    video.addEventListener('pause', function() {
                        if (!window.__userPaused && !video.ended) {
                            setTimeout(function() {
                                if (!window.__userPaused) video.play().catch(function(e) {});
                            }, 50);
                        } else if (window.__userPaused) {
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'paused' });
                        }
                    });
                    video.addEventListener('ended', function() {
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'ended' });
                    });
                }
            }, 150);
        })();
        """
        let endScript = WKUserScript(source: endJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(endScript)
        config.userContentController = contentController

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"

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
        webView.alpha = 1.0
        webView.isUserInteractionEnabled = false
        window.addSubview(webView)
    }

    func play(song: SongItem) {
        currentSong = song
        isPlaying = true
        currentArtworkImage = nil
        updateNowPlayingInfo(song: song, image: nil)
        onStateChanged?(true, "Memuat: \(song.title)...", nil)
        webView.evaluateJavaScript("window.__userPaused = false; window.__reportedPlayingForSrc = '';", completionHandler: nil)

        // Unduh thumbnail untuk mini-player dan Lock Screen
        ImageLoader.shared.loadImage(from: song.thumbnailURL) { [weak self] image in
            guard let self = self, self.currentSong?.videoId == song.videoId else { return }
            self.currentArtworkImage = image
            self.updateNowPlayingInfo(song: song, image: image)
            let statusText = self.isPlaying ? "\(song.title) - \(song.artist)" : "\(song.title)"
            self.onStateChanged?(self.isPlaying, statusText, image)
        }

        if isPlayerPageLoaded {
            let spaNavigateJS = """
            (function() {
                window.__userPaused = false;
                window.__reportedPlayingForSrc = '';
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
            webView.evaluateJavaScript("window.__userPaused = true; var v = document.querySelector('video'); if(v) v.pause();", completionHandler: nil)
            isPlaying = false
        } else {
            webView.evaluateJavaScript("window.__userPaused = false; var v = document.querySelector('video'); if(v) { v.muted = false; v.volume = 1.0; v.play(); 'ok'; } else { 'reload'; }") { [weak self] result, _ in
                if let res = result as? String, res == "reload" {
                    self?.loadWatchURL(videoId: song.videoId)
                }
            }
            isPlaying = true
        }
        updateNowPlayingInfo(song: song, image: currentArtworkImage)
        onStateChanged?(isPlaying, "\(song.title) - \(song.artist)", currentArtworkImage)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let status = body["status"] as? String,
              let song = currentSong else { return }

        switch status {
        case "playing":
            isPlaying = true
            onStateChanged?(true, "\(song.title) - \(song.artist)", currentArtworkImage)
            updateNowPlayingInfo(song: song, image: currentArtworkImage)
        case "paused":
            isPlaying = false
            onStateChanged?(false, "\(song.title) - \(song.artist)", currentArtworkImage)
        case "ended":
            isPlaying = false
            onStateChanged?(false, "Selesai: \(song.title)", currentArtworkImage)
        default:
            break
        }
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.beginBackgroundTaskIfNeeded()
            self.webView.evaluateJavaScript("window.__userPaused = false; var v = document.querySelector('video'); if(v && v.paused) v.play();", completionHandler: nil)
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.webView.evaluateJavaScript("window.__userPaused = false; var v = document.querySelector('video'); if(v && v.paused) v.play();", completionHandler: nil)
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MetroLiteBackgroundAudio") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func updateNowPlayingInfo(song: SongItem, image: UIImage?) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let image = image {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in return image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
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