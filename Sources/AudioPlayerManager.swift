import UIKit
import WebKit
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AudioPlayerManager()
    
    private var webView: WKWebView!
    private var silentPlayer: AVAudioPlayer?
    private var nowPlayingTimer: Timer?
    private(set) var isPlaying = false
    private(set) var currentSong: SongItem?
    
    // Antrean (Queue) lagu untuk fitur Next, Previous, dan Auto-Play
    private(set) var queue: [SongItem] = []
    private(set) var currentIndex: Int = -1
    
    private var isPlayerPageLoaded = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    var onStateChanged: ((Bool, String, UIImage?) -> Void)?
    private var currentArtworkImage: UIImage?
    private var currentPlaybackTime: Double = 0
    private var currentDuration: Double = 0

    private override init() {
        super.init()
        setupAudioSession()
        setupSilentAnchorPlayer()
        setupWebView()
        setupRemoteCommands()
        setupLifecycleObservers()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    private func setupSilentAnchorPlayer() {
        let sampleRate: Int32 = 8000
        let numSamples: Int32 = 8000
        let dataSize = numSamples * 2
        let fileSize = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append("WAVEfmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: Int32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: Int16(2).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: Int16(16).littleEndian) { Data($0) })
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        header.append(Data(count: Int(dataSize)))

        if let player = try? AVAudioPlayer(data: header) {
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            silentPlayer = player
        }
    }

    private func updateAnchorState() {
        if isPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
            if silentPlayer?.isPlaying == false {
                silentPlayer?.play()
            }
            startNowPlayingKeepAlive()
        } else {
            silentPlayer?.pause()
            nowPlayingTimer?.invalidate()
            nowPlayingTimer = nil
        }
    }

    private func startNowPlayingKeepAlive() {
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, let song = self.currentSong else { return }
            self.updateNowPlayingInfo(song: song, image: self.currentArtworkImage)
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

        let endJS = """
        (function() {
            window.__userPaused = false;
            window.__reportedPlayingForSrc = "";
            window.__reportedEndedForSrc = "";
            window.__songMeta = { title: "MetroLite 12", artist: "YouTube Music", artwork: "" };

            window.__applyWebMediaSession = function() {
                if ('mediaSession' in navigator) {
                    try {
                        navigator.mediaSession.metadata = new MediaMetadata({
                            title: window.__songMeta.title,
                            artist: window.__songMeta.artist,
                            album: 'MetroLite 12',
                            artwork: window.__songMeta.artwork ? [{ src: window.__songMeta.artwork, sizes: '320x180', type: 'image/jpeg' }] : []
                        });
                        navigator.mediaSession.playbackState = window.__userPaused ? 'paused' : 'playing';
                        navigator.mediaSession.setActionHandler('play', function() {
                            window.__userPaused = false;
                            var v = document.querySelector('video');
                            if (v) v.play();
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'remotePlay' });
                        });
                        navigator.mediaSession.setActionHandler('pause', function() {
                            window.__userPaused = true;
                            var v = document.querySelector('video');
                            if (v) v.pause();
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'remotePause' });
                        });
                        navigator.mediaSession.setActionHandler('nexttrack', function() {
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'remoteNext' });
                        });
                        navigator.mediaSession.setActionHandler('previoustrack', function() {
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'remotePrev' });
                        });
                    } catch(e) {}
                }
            };
            
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
                        window.__applyWebMediaSession();
                        window.webkit.messageHandlers.nativeBridge.postMessage({
                            status: 'progress',
                            currentTime: video.currentTime || 0,
                            duration: isFinite(video.duration) ? video.duration : 0
                        });
                        var sig = video.src + "_" + Math.floor(video.duration || 0);
                        if (window.__reportedPlayingForSrc !== sig) {
                            window.__reportedPlayingForSrc = sig;
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'playing' });
                        }
                    }
                    // Deteksi akhir lagu secara akurat (baik lewat event ended maupun sisa durasi < 0.4 detik)
                    if ((video.ended || (isFinite(video.duration) && video.duration > 5 && (video.duration - video.currentTime) <= 0.4)) && window.__reportedEndedForSrc !== video.src) {
                        window.__reportedEndedForSrc = video.src;
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'ended' });
                    }
                }

                if (!video.__hooked) {
                    video.__hooked = true;
                    video.addEventListener('pause', function() {
                        if (!window.__userPaused && !video.ended) {
                            video.play().catch(function(e) {});
                        } else if (window.__userPaused) {
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'paused' });
                        }
                    });
                    video.addEventListener('ended', function() {
                        if (window.__reportedEndedForSrc !== video.src) {
                            window.__reportedEndedForSrc = video.src;
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'ended' });
                        }
                    });
                }
            }, 200);
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

    private func syncWebMetadata(song: SongItem) {
        let safeTitle = song.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let safeArtist = song.artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let artURL = song.thumbnailURL?.absoluteString ?? ""
        let js = """
        window.__songMeta = { title: '\(safeTitle)', artist: '\(safeArtist)', artwork: '\(artURL)' };
        if (window.__applyWebMediaSession) window.__applyWebMediaSession();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // Memutar lagu sekaligus menyimpan daftar antrean aktif
    func playFromQueue(songs: [SongItem], at index: Int) {
        guard songs.indices.contains(index) else { return }
        self.queue = songs
        self.currentIndex = index
        play(song: songs[index])
    }

    func playNext() {
        guard !queue.isEmpty else { return }
        let nextIndex = (currentIndex + 1) < queue.count ? (currentIndex + 1) : 0
        currentIndex = nextIndex
        play(song: queue[nextIndex])
    }

    func playPrevious() {
        guard !queue.isEmpty else { return }
        // Jika lagu sudah berjalan lebih dari 4 detik, tombol Previous mengulang dari awal lagu
        if currentPlaybackTime > 4.0, let song = currentSong {
            play(song: song)
            return
        }
        let prevIndex = (currentIndex - 1) >= 0 ? (currentIndex - 1) : (queue.count - 1)
        currentIndex = prevIndex
        play(song: queue[prevIndex])
    }

    func play(song: SongItem) {
        currentSong = song
        isPlaying = true
        currentArtworkImage = nil
        currentPlaybackTime = 0
        currentDuration = 0
        updateAnchorState()
        updateNowPlayingInfo(song: song, image: nil)
        syncWebMetadata(song: song)
        onStateChanged?(true, "Memuat: \(song.title)...", nil)
        webView.evaluateJavaScript("window.__userPaused = false; window.__reportedPlayingForSrc = ''; window.__reportedEndedForSrc = '';", completionHandler: nil)

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
                window.__reportedEndedForSrc = '';
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
        if let song = currentSong {
            syncWebMetadata(song: song)
        }
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
        syncWebMetadata(song: song)
        updateAnchorState()
        updateNowPlayingInfo(song: song, image: currentArtworkImage)
        onStateChanged?(isPlaying, "\(song.title) - \(song.artist)", currentArtworkImage)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let status = body["status"] as? String,
              let song = currentSong else { return }

        switch status {
        case "progress":
            if let ct = body["currentTime"] as? Double { currentPlaybackTime = ct }
            if let dur = body["duration"] as? Double { currentDuration = dur }
        case "playing", "remotePlay":
            isPlaying = true
            updateAnchorState()
            onStateChanged?(true, "\(song.title) - \(song.artist)", currentArtworkImage)
            updateNowPlayingInfo(song: song, image: currentArtworkImage)
        case "paused", "remotePause":
            isPlaying = false
            updateAnchorState()
            onStateChanged?(false, "\(song.title) - \(song.artist)", currentArtworkImage)
            updateNowPlayingInfo(song: song, image: currentArtworkImage)
        case "ended":
            // Otomatis lanjut ke lagu berikutnya saat lagu selesai diputar
            playNext()
        case "remoteNext":
            playNext()
        case "remotePrev":
            playPrevious()
        default:
            break
        }
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.silentPlayer?.play()
            self.beginBackgroundTaskIfNeeded()
            if let song = self.currentSong {
                self.syncWebMetadata(song: song)
                self.updateNowPlayingInfo(song: song, image: self.currentArtworkImage)
            }
            self.webView.evaluateJavaScript("window.__userPaused = false; var v = document.querySelector('video'); if(v && v.paused) v.play();", completionHandler: nil)
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.silentPlayer?.play()
            if let song = self.currentSong {
                self.syncWebMetadata(song: song)
                self.updateNowPlayingInfo(song: song, image: self.currentArtworkImage)
            }
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
        info[MPMediaItemPropertyPlaybackDuration] = currentDuration > 0 ? currentDuration : 180.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPlaybackTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let image = image {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in return image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
    }
}