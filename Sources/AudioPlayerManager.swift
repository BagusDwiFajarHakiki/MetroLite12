import UIKit
import WebKit
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
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
        contentController.add(self, name: "playerState")
        config.userContentController = contentController

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"
    }

    // Tempelkan WebView ke window aktif agar WebKit iOS 12 tidak menangguhkan audio
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

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>body, html { margin: 0; padding: 0; background: #000; overflow: hidden; }</style>
        </head>
        <body>
            <div id="player"></div>
            <script>
                var tag = document.createElement('script');
                tag.src = "https://www.youtube.com/iframe_api";
                var firstScriptTag = document.getElementsByTagName('script')[0];
                firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);

                var player;
                function onYouTubeIframeAPIReady() {
                    player = new YT.Player('player', {
                        height: '100',
                        width: '100',
                        videoId: '\(song.videoId)',
                        playerVars: {
                            'playsinline': 1,
                            'autoplay': 1,
                            'controls': 0,
                            'rel': 0,
                            'origin': 'https://www.youtube.com'
                        },
                        events: {
                            'onReady': onPlayerReady,
                            'onStateChange': onPlayerStateChange,
                            'onError': onPlayerError
                        }
                    });
                }

                function onPlayerReady(event) {
                    event.target.setVolume(100);
                    event.target.playVideo();
                }

                function onPlayerStateChange(event) {
                    window.webkit.messageHandlers.playerState.postMessage({
                        type: 'state',
                        data: event.data
                    });
                }

                function onPlayerError(event) {
                    window.webkit.messageHandlers.playerState.postMessage({
                        type: 'error',
                        data: event.data
                    });
                }
            </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }

    func togglePlayPause() {
        if isPlaying {
            webView.evaluateJavaScript("if(player && player.pauseVideo) player.pauseVideo();", completionHandler: nil)
            isPlaying = false
        } else {
            webView.evaluateJavaScript("if(player && player.playVideo) player.playVideo();", completionHandler: nil)
            isPlaying = true
        }
        if let song = currentSong {
            onStateChanged?(isPlaying, "\(song.title) - \(song.artist)")
        }
    }

    // Menerima status dari JavaScript YouTube IFrame API
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "state", let state = body["data"] as? Int, let song = currentSong {
            // YT.PlayerState: 1 = PLAYING, 2 = PAUSED, 0 = ENDED
            if state == 1 {
                isPlaying = true
                onStateChanged?(true, "\(song.title) - \(song.artist)")
                updateNowPlayingInfo(song: song)
            } else if state == 2 {
                isPlaying = false
                onStateChanged?(false, "\(song.title) - \(song.artist)")
            } else if state == 0 {
                isPlaying = false
                onStateChanged?(false, "Selesai: \(song.title)")
            }
        } else if type == "error", let code = body["data"] as? Int {
            isPlaying = false
            onStateChanged?(false, "Error pemutar YouTube (Kode: \(code))")
        }
    }

    private func setupBackgroundObserver() {
        // Mencegah WKWebView menghentikan audio otomatis saat tombol power ditekan
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.webView.evaluateJavaScript("if(player && player.playVideo) player.playVideo();", completionHandler: nil)
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