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
    
    private(set) var queue: [SongItem] = []
    private(set) var currentIndex: Int = -1
    private var playedHistory = Set<String>()
    
    private var isPlayerPageLoaded = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    var onStateChanged: ((Bool, String, UIImage?) -> Void)?
    var onQueueUpdated: (([SongItem]) -> Void)?
    private var currentArtworkImage: UIImage?
    private var currentPlaybackTime: Double = 0
    private var currentDuration: Double = 0

    private override init() {
        super.init()
        setupAudioSession()
        setupAnchorAudioPlayer()
        setupWebView()
        setupRemoteCommands()
        setupLifecycleObservers()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Wajib tanpa .mixWithOthers agar Lock Screen iOS 12 mengaktifkan Next/Previous & Artwork
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    private func setupAnchorAudioPlayer() {
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
            player.volume = 0.02
            player.prepareToPlay()
            silentPlayer = player
        }
    }

    private func maintainNativeSession() {
        guard isPlaying else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        if silentPlayer?.isPlaying == false {
            silentPlayer?.play()
        }
        if let song = currentSong {
            updateNowPlayingInfo(song: song, image: currentArtworkImage)
        }
    }

    private func updateAnchorState() {
        if isPlaying {
            maintainNativeSession()
            nowPlayingTimer?.invalidate()
            nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.maintainNativeSession()
            }
        } else {
            silentPlayer?.pause()
            nowPlayingTimer?.invalidate()
            nowPlayingTimer = nil
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
                if (type === 'visibilitychange' || type === 'webkitvisibilitychange' || type === 'pagehide' || type === 'blur' || type === 'focusout') {
                    return;
                }
                return origAddEventListener.call(document, type, listener, options);
            };
            window.addEventListener('pagehide', function(e) { e.stopImmediatePropagation(); }, true);
            window.addEventListener('blur', function(e) { e.stopImmediatePropagation(); }, true);
        })();
        """
        let startScript = WKUserScript(source: startJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(startScript)

        let endJS = """
        (function() {
            window.__userPaused = false;
            window.__reportedPlayingForSrc = "";
            window.__reportedEndedForSrc = "";
            window.__qualitySetForSrc = "";
            window.__savedTime = 0;
            
            setInterval(function() {
                var video = document.querySelector('video');
                if (!video) return;

                if (video.src && window.__qualitySetForSrc !== video.src) {
                    var player = document.getElementById('movie_player');
                    if (player && player.setPlaybackQualityRange) {
                        try {
                            player.setPlaybackQualityRange('tiny', 'tiny');
                            window.__qualitySetForSrc = video.src;
                        } catch(e) {}
                    }
                }

                var isAd = document.querySelector('.ad-showing, .ad-interrupting') !== null;
                if (isAd) {
                    video.muted = true;
                    if (isFinite(video.duration) && video.duration > 0) {
                        video.currentTime = video.duration;
                    }
                    var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern');
                    if (skipBtn) skipBtn.click();
                    return;
                }

                if (!window.__userPaused) {
                    if (video.muted) video.muted = false;
                    if (video.volume < 1.0) video.volume = 1.0;

                    if (window.__savedTime > 3.0 && video.currentTime < 1.5 && video.readyState >= 2) {
                        try {
                            video.currentTime = window.__savedTime;
                        } catch(e) {}
                    }

                    if (video.paused && !video.ended && video.readyState >= 2) {
                        video.play().catch(function(e) {});
                    }

                    if (!video.paused && video.readyState >= 3 && video.currentTime > 0.25) {
                        if (video.currentTime >= window.__savedTime || (window.__savedTime - video.currentTime) < 2.0) {
                            window.__savedTime = video.currentTime;
                        }

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

                    if ((video.ended || (isFinite(video.duration) && video.duration > 10 && (video.duration - video.currentTime) <= 0.4)) && window.__reportedEndedForSrc !== video.src) {
                        window.__savedTime = 0;
                        window.__reportedEndedForSrc = video.src;
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'ended' });
                    }
                }

                if (!video.__hooked) {
                    video.__hooked = true;
                    video.addEventListener('pause', function() {
                        if (!window.__userPaused && !video.ended) {
                            setTimeout(function() {
                                if (!window.__userPaused && video.paused) {
                                    if (window.__savedTime > 3.0 && video.currentTime < 1.5) {
                                        try { video.currentTime = window.__savedTime; } catch(e) {}
                                    }
                                    video.play().catch(function(e) {});
                                }
                            }, 30);
                        } else if (window.__userPaused) {
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'paused' });
                        }
                    });
                    video.addEventListener('ended', function() {
                        if (window.__reportedEndedForSrc !== video.src) {
                            window.__savedTime = 0;
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

    func startRadioWithSong(_ song: SongItem) {
        playedHistory = [song.videoId]
        queue = [song]
        currentIndex = 0
        play(song: song)

        InnerTubeService.shared.fetchRelatedSongs(videoId: song.videoId) { [weak self] related in
            guard let self = self, self.currentSong?.videoId == song.videoId else { return }
            let filtered = related.filter { !self.playedHistory.contains($0.videoId) }
            if !filtered.isEmpty {
                self.queue = [song] + filtered
                self.currentIndex = 0
                self.onQueueUpdated?(self.queue)
            }
        }
    }

    func playFromQueue(songs: [SongItem], at index: Int) {
        guard songs.indices.contains(index) else { return }
        self.queue = songs
        self.currentIndex = index
        let selected = songs[index]
        playedHistory.insert(selected.videoId)
        play(song: selected)
    }

    func playNext() {
        guard !queue.isEmpty else { return }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            currentIndex = nextIndex
            let nextSong = queue[nextIndex]
            playedHistory.insert(nextSong.videoId)
            play(song: nextSong)

            if queue.count - nextIndex <= 2 {
                fetchMoreRelated(basedOn: nextSong)
            }
        } else if let lastSong = currentSong {
            onStateChanged?(true, "Mencari lagu sejenis...", currentArtworkImage)
            InnerTubeService.shared.fetchRelatedSongs(videoId: lastSong.videoId) { [weak self] related in
                guard let self = self else { return }
                let fresh = related.filter { !self.playedHistory.contains($0.videoId) }
                let candidates = fresh.isEmpty ? related : fresh
                guard let firstNext = candidates.first else { return }
                self.queue.append(contentsOf: candidates)
                self.currentIndex += 1
                self.playedHistory.insert(firstNext.videoId)
                self.onQueueUpdated?(self.queue)
                self.play(song: firstNext)
            }
        }
    }

    private func fetchMoreRelated(basedOn song: SongItem) {
        InnerTubeService.shared.fetchRelatedSongs(videoId: song.videoId) { [weak self] related in
            guard let self = self else { return }
            let existingIds = Set(self.queue.map { $0.videoId })
            let newItems = related.filter { !existingIds.contains($0.videoId) }
            if !newItems.isEmpty {
                self.queue.append(contentsOf: newItems)
                self.onQueueUpdated?(self.queue)
            }
        }
    }

    func playPrevious() {
        guard !queue.isEmpty else { return }
        if currentPlaybackTime > 4.0, let song = currentSong {
            play(song: song)
            return
        }
        let prevIndex = (currentIndex - 1) >= 0 ? (currentIndex - 1) : 0
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
        onStateChanged?(true, "Memuat: \(song.title)...", nil)
        
        let resetJS = "window.__userPaused = false; window.__reportedPlayingForSrc = ''; window.__reportedEndedForSrc = ''; window.__qualitySetForSrc = ''; window.__savedTime = 0;"
        webView.evaluateJavaScript(resetJS, completionHandler: nil)

        ImageLoader.shared.loadImage(from: song.thumbnailURL) { [weak self] image in
            guard let self = self, self.currentSong?.videoId == song.videoId else { return }
            let squareArt = self.makeSquareArtwork(from: image)
            self.currentArtworkImage = squareArt
            self.updateNowPlayingInfo(song: song, image: squareArt)
            let statusText = self.isPlaying ? "\(song.title) - \(song.artist)" : "\(song.title)"
            self.onStateChanged?(self.isPlaying, statusText, squareArt)
        }

        if isPlayerPageLoaded {
            let spaNavigateJS = """
            (function() {
                window.__userPaused = false;
                window.__reportedPlayingForSrc = '';
                window.__reportedEndedForSrc = '';
                window.__qualitySetForSrc = '';
                window.__savedTime = 0;
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

    private func makeSquareArtwork(from image: UIImage?) -> UIImage? {
        guard let image = image else { return nil }
        let targetSize = CGSize(width: 300, height: 300)
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        let aspect = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let drawWidth = image.size.width * aspect
        let drawHeight = image.size.height * aspect
        let drawRect = CGRect(
            x: (targetSize.width - drawWidth) / 2.0,
            y: (targetSize.height - drawHeight) / 2.0,
            width: drawWidth,
            height: drawHeight
        )
        image.draw(in: drawRect)
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
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
        case "playing":
            isPlaying = true
            // Segera pulihkan sesi native setelah WebKit mulai bersuara agar Next/Prev & Artwork tidak abu-abu
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.maintainNativeSession()
            }
            onStateChanged?(true, "\(song.title) - \(song.artist)", currentArtworkImage)
        case "paused":
            isPlaying = false
            updateAnchorState()
            onStateChanged?(false, "\(song.title) - \(song.artist)", currentArtworkImage)
            updateNowPlayingInfo(song: song, image: currentArtworkImage)
        case "ended":
            playNext()
        default:
            break
        }
    }

    private func setupLifecycleObservers() {
        // Pulihkan sesi audio native dan HTML5 video secara otomatis setiap kali terjadi interupsi audio di iOS 12
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, self.isPlaying else { return }
            if let info = notification.userInfo,
               let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
               let type = AVAudioSession.InterruptionType(rawValue: typeValue),
               type == .ended {
                self.maintainNativeSession()
                self.webView.evaluateJavaScript("window.__userPaused = false; var v = document.querySelector('video'); if(v && v.paused) v.play();", completionHandler: nil)
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.beginBackgroundTaskIfNeeded()
            self.maintainNativeSession()
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.maintainNativeSession()
            let resumeJS = """
            (function() {
                window.__userPaused = false;
                var v = document.querySelector('video');
                if (v) {
                    if (window.__savedTime > 3.0 && v.currentTime < 1.5) {
                        try { v.currentTime = window.__savedTime; } catch(e) {}
                    }
                    if (v.paused) v.play().catch(function(e) {});
                }
            })();
            """
            self.webView.evaluateJavaScript(resumeJS, completionHandler: nil)
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
        info[MPMediaItemPropertyAlbumTitle] = "MetroLite 12"
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

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

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