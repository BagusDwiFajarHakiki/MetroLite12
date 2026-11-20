import UIKit
import WebKit
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AudioPlayerManager()
    
    private var webView: WKWebView!
    private(set) var isPlaying = false
    private(set) var currentSong: SongItem?
    
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
        config.userContentController = contentController

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
        webView.navigationDelegate = self
        // Gunakan User-Agent Safari iOS 12 standar agar YouTube Mobile melayani stream HTML5 langsung
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"
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

        // Muat halaman watch langsung (bukan /embed) untuk menghindari blokir hak cipta Error 150/152
        if let watchURL = URL(string: "https://m.youtube.com/watch?v=\(song.videoId)") {
            var request = URLRequest(url: watchURL)
            request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
            webView.load(request)
        }
    }

    func togglePlayPause() {
        guard let song = currentSong else { return }
        if isPlaying {
            webView.evaluateJavaScript("var v = document.querySelector('video'); if(v) v.pause();", completionHandler: nil)
            isPlaying = false
        } else {
            // Cek apakah elemen video sudah siap; jika belum, muat ulang lagunya
            webView.evaluateJavaScript("var v = document.querySelector('video'); if(v) { v.play(); 'ok'; } else { 'reload'; }") { [weak self] result, _ in
                if let res = result as? String, res == "reload" {
                    self?.play(song: song)
                }
            }
            isPlaying = true
        }
        updateNowPlayingInfo(song: song)
        onStateChanged?(isPlaying, "\(song.title) - \(song.artist)")
    }

    // Setelah halaman m.youtube.com selesai dimuat, paksa elemen <video> berputar dan pantau event-nya
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let jsHook = """
        (function() {
            var attempts = 0;
            var timer = setInterval(function() {
                attempts++;
                var video = document.querySelector('video');
                if (video) {
                    clearInterval(timer);
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
                } else if (attempts > 30) {
                    clearInterval(timer);
                    window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'timeout' });
                }
            }, 300);
        })();
        """
        webView.evaluateJavaScript(jsHook, completionHandler: nil)
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
        case "timeout":
            isPlaying = false
            onStateChanged?(false, "Gagal memuat pemutar halaman")
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