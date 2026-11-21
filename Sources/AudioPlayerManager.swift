import UIKit
import WebKit
import AVFoundation
import MediaPlayer

class AudioPlayerManager: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AudioPlayerManager()
    
    private var webView: WKWebView!
    private var silentPlayer: AVAudioPlayer?
    private var nativeAutoNextTimer: Timer?
    private(set) var isPlaying = false
    private(set) var currentSong: SongItem?
    
    private(set) var queue: [SongItem] = []
    private(set) var currentIndex: Int = -1
    private var playedHistory = Set<String>()
    
    private var isPlayerPageLoaded = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastUserPauseTimestamp: Date?
    private var isTransitioningTrack = false
    
    var onStateChanged: ((Bool, String, UIImage?) -> Void)?
    var onQueueUpdated: (([SongItem]) -> Void)?
    var onOpenQueueRequested: (([SongItem]) -> Void)?
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
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
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
            player.volume = 0.01
            player.prepareToPlay()
            silentPlayer = player
            silentPlayer?.play()
        }
    }

    private func startNativeAutoNextWatchdog() {
        nativeAutoNextTimer?.invalidate()
        nativeAutoNextTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isPlaying && self.silentPlayer?.isPlaying == false {
                self.silentPlayer?.play()
            }

            if let song = self.currentSong {
                self.updateNowPlayingInfo(song: song, image: self.currentArtworkImage)
            }

            let probeJS = """
            (function() {
                var v = document.querySelector('video');
                var player = document.getElementById('movie_player');
                if (window.__userPaused) {
                    if (v && !v.paused && window.__origMediaPause) window.__origMediaPause.call(v);
                    return 'user_paused';
                }
                if (!v) return 'no_video';

                // Paksa play baik melalui API movie_player maupun elemen <video> jika lagu baru belum berputar
                if (v.paused && !v.ended) {
                    if (player && typeof player.playVideo === 'function') {
                        try { player.playVideo(); } catch(e) {}
                    }
                    if (v.readyState >= 2) {
                        v.muted = false;
                        v.volume = 1.0;
                        v.play().catch(function(e){});
                    }
                }

                var dur = isFinite(v.duration) ? v.duration : 0;
                var ct = v.currentTime || 0;
                var isAd = document.querySelector('.ad-showing, .ad-interrupting') !== null;
                if (isAd && window.__savedTime > 15.0) return 'ended';
                if (v.ended || (dur > 10 && ct >= (dur - 0.8))) return 'ended';
                return (v.paused ? 'paused' : 'playing') + '|' + ct + '|' + dur;
            })();
            """
            self.webView.evaluateJavaScript(probeJS) { [weak self] result, _ in
                guard let self = self,
                      let statusStr = result as? String else { return }

                if statusStr == "user_paused" {
                    if self.isPlaying {
                        self.syncUIState(playing: false)
                    }
                } else if statusStr == "ended" && self.isPlaying && !self.isTransitioningTrack {
                    self.isTransitioningTrack = true
                    self.playNext()
                } else if statusStr.contains("|") {
                    let parts = statusStr.split(separator: "|")
                    if parts.count == 3,
                       let ct = Double(parts[1]),
                       let dur = Double(parts[2]) {
                        let webIsPlaying = (parts[0] == "playing")
                        if ct > 0.2 { self.currentPlaybackTime = ct }
                        if dur > 5.0 { self.currentDuration = dur }
                        // Sinkronkan status tombol mini-player jika WebKit berubah status dari Control Center
                        if webIsPlaying != self.isPlaying && !self.isTransitioningTrack {
                            self.syncUIState(playing: webIsPlaying)
                        }
                    }
                }
            }
        }
    }

    private func syncUIState(playing: Bool) {
        guard let song = currentSong else { return }
        isPlaying = playing
        if playing {
            lastUserPauseTimestamp = nil
            if silentPlayer?.isPlaying == false { silentPlayer?.play() }
        } else {
            lastUserPauseTimestamp = Date()
        }
        updateNowPlayingInfo(song: song, image: currentArtworkImage)
        onStateChanged?(playing, "\(song.title) - \(song.artist)", currentArtworkImage)
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
            window.__userPaused = false;
            window.__autoPlayGraceUntil = 0;

            try {
                var exp = Date.now() + 2592000000;
                localStorage.setItem('yt-player-quality', JSON.stringify({ data: 'tiny', expiration: exp, creation: Date.now() }));
                localStorage.setItem('yt-player-av1-pref', '144');
            } catch(e) {}

            var origPause = HTMLMediaElement.prototype.pause;
            window.__origMediaPause = origPause;
            HTMLMediaElement.prototype.pause = function() {
                if (Date.now() > window.__autoPlayGraceUntil || window.__userPaused || this.ended) {
                    return origPause.apply(this, arguments);
                }
            };

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
            window.__reportedPlayingForSig = "";
            window.__endedTriggered = false;
            window.__savedTime = 0;
            window.__mainDuration = 0;
            window.__targetVideoId = "";
            window.__loadingNewTrack = false;

            function triggerSongEnded() {
                if (window.__endedTriggered) return;
                window.__endedTriggered = true;
                window.__savedTime = 0;
                window.__mainDuration = 0;
                window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'ended' });
            }
            
            setInterval(function() {
                var video = document.querySelector('video');
                if (!video) return;

                if (window.__userPaused) {
                    if (!video.paused && window.__origMediaPause) {
                        window.__origMediaPause.call(video);
                    }
                    return;
                }

                var isAd = document.querySelector('.ad-showing, .ad-interrupting') !== null;
                if (isAd) {
                    if (window.__savedTime > 15.0) {
                        triggerSongEnded();
                        return;
                    }
                    video.muted = true;
                    if (isFinite(video.duration) && video.duration > 0) {
                        video.currentTime = video.duration;
                    }
                    var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern');
                    if (skipBtn) skipBtn.click();
                    return;
                }

                if (video.muted) video.muted = false;
                if (video.volume < 1.0) video.volume = 1.0;

                if (window.__savedTime > 3.0 && video.currentTime < 1.5 && video.readyState >= 2 && !window.__endedTriggered) {
                    try {
                        video.currentTime = window.__savedTime;
                    } catch(e) {}
                }

                // Saat memuat lagu baru atau dalam jendela kunci layar, terus dorong pemutaran sampai audio jalan
                if (video.paused && !video.ended && !window.__endedTriggered && (window.__loadingNewTrack || Date.now() <= window.__autoPlayGraceUntil)) {
                    var player = document.getElementById('movie_player');
                    if (player && typeof player.playVideo === 'function') {
                        try { player.playVideo(); } catch(e) {}
                    }
                    if (video.readyState >= 2) {
                        video.play().catch(function(e) {});
                    }
                }

                if (!video.paused && video.readyState >= 3 && video.currentTime > 0.35) {
                    window.__loadingNewTrack = false;
                    if (video.currentTime >= window.__savedTime || (window.__savedTime - video.currentTime) < 2.0) {
                        window.__savedTime = video.currentTime;
                    }
                    if (isFinite(video.duration) && video.duration > 15) {
                        window.__mainDuration = video.duration;
                    }

                    window.webkit.messageHandlers.nativeBridge.postMessage({
                        status: 'progress',
                        currentTime: video.currentTime || 0,
                        duration: isFinite(video.duration) ? video.duration : 0
                    });
                    var sig = window.__targetVideoId + "_" + video.src + "_" + Math.floor(video.duration || 0);
                    if (window.__reportedPlayingForSig !== sig) {
                        window.__reportedPlayingForSig = sig;
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'playing' });
                    }
                }

                var dur = window.__mainDuration > 0 ? window.__mainDuration : (isFinite(video.duration) ? video.duration : 0);
                if (video.ended || (dur > 10 && video.currentTime >= (dur - 0.8))) {
                    triggerSongEnded();
                }

                if (!video.__hooked) {
                    video.__hooked = true;
                    video.addEventListener('play', function() {
                        window.__userPaused = false;
                        // Segera beri tahu Swift agar ikon mini-player berubah ke Pause saat Play ditekan dari Control Center/Lock Screen
                        window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'playing' });
                    });
                    video.addEventListener('pause', function() {
                        if (video.ended) {
                            triggerSongEnded();
                        } else if ((window.__loadingNewTrack || Date.now() <= window.__autoPlayGraceUntil) && !window.__userPaused) {
                            video.play().catch(function(e) {});
                        } else if (!window.__endedTriggered) {
                            window.__userPaused = true;
                            window.webkit.messageHandlers.nativeBridge.postMessage({ status: 'paused' });
                        }
                    });
                    video.addEventListener('ended', function() {
                        triggerSongEnded();
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

    func reopenCurrentQueue() {
        if !queue.isEmpty {
            onOpenQueueRequested?(queue)
        } else if let song = currentSong {
            startRadioWithSong(song)
        }
    }

    func startRadioWithSong(_ song: SongItem) {
        playedHistory = [song.videoId]
        queue = [song]
        currentIndex = 0
        onQueueUpdated?(queue)
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
        guard !queue.isEmpty else {
            if let current = currentSong {
                startRadioWithSong(current)
            }
            return
        }
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
        isTransitioningTrack = true
        lastUserPauseTimestamp = nil
        currentArtworkImage = nil
        currentPlaybackTime = 0
        currentDuration = 0
        
        beginBackgroundTaskIfNeeded()
        if silentPlayer?.isPlaying == false {
            silentPlayer?.play()
        }
        startNativeAutoNextWatchdog()
        updateNowPlayingInfo(song: song, image: nil)
        onStateChanged?(true, "Memuat: \(song.title)...", nil)

        ImageLoader.shared.loadImage(from: song.thumbnailURL) { [weak self] image in
            guard let self = self, self.currentSong?.videoId == song.videoId else { return }
            let squareArt = self.makeSquareArtwork(from: image)
            self.currentArtworkImage = squareArt
            self.updateNowPlayingInfo(song: song, image: squareArt)
            let statusText = self.isPlaying ? "\(song.title) - \(song.artist)" : "\(song.title)"
            self.onStateChanged?(self.isPlaying, statusText, squareArt)
        }

        if isPlayerPageLoaded {
            let loadByIdJS = """
            (function() {
                window.__userPaused = false;
                window.__loadingNewTrack = true;
                window.__autoPlayGraceUntil = Date.now() + 8000;
                window.__reportedPlayingForSig = '';
                window.__endedTriggered = false;
                window.__savedTime = 0;
                window.__mainDuration = 0;
                window.__targetVideoId = '\(song.videoId)';

                var player = document.getElementById('movie_player');
                if (player && typeof player.loadVideoById === 'function') {
                    player.loadVideoById('\(song.videoId)');
                    if (typeof player.playVideo === 'function') player.playVideo();
                    var v = document.querySelector('video');
                    if (v) { v.muted = false; v.volume = 1.0; v.play().catch(function(e){}); }
                    return 'loaded_by_id';
                }
                return 'fallback_needed';
            })();
            """
            webView.evaluateJavaScript(loadByIdJS) { [weak self] result, _ in
                if let res = result as? String, res == "loaded_by_id" {
                    return
                }
                self?.loadWatchURL(videoId: song.videoId)
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
        let resetJS = "window.__userPaused = false; window.__loadingNewTrack = true; window.__autoPlayGraceUntil = Date.now() + 8000; window.__reportedPlayingForSig = ''; window.__endedTriggered = false; window.__savedTime = 0; window.__mainDuration = 0; window.__targetVideoId = '\(videoId)';"
        webView.evaluateJavaScript(resetJS, completionHandler: nil)
        if let watchURL = URL(string: "https://m.youtube.com/watch?v=\(videoId)") {
            var request = URLRequest(url: watchURL)
            request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
            webView.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPlayerPageLoaded = true
        if isPlaying, let vid = currentSong?.videoId {
            let forcePlayJS = "window.__userPaused = false; window.__loadingNewTrack = true; window.__autoPlayGraceUntil = Date.now() + 6000; window.__targetVideoId = '\(vid)'; var v = document.querySelector('video'); if(v) { v.muted = false; v.volume = 1.0; v.play().catch(function(e){}); }"
            webView.evaluateJavaScript(forcePlayJS, completionHandler: nil)
        }
    }

    func pausePlayback() {
        guard let song = currentSong else { return }
        isPlaying = false
        lastUserPauseTimestamp = Date()
        let pauseJS = """
        window.__userPaused = true;
        window.__loadingNewTrack = false;
        window.__autoPlayGraceUntil = 0;
        var v = document.querySelector('video');
        if (v) {
            if (window.__origMediaPause) { window.__origMediaPause.call(v); } else { v.pause(); }
        }
        """
        webView.evaluateJavaScript(pauseJS, completionHandler: nil)
        updateNowPlayingInfo(song: song, image: currentArtworkImage)
        onStateChanged?(false, "\(song.title) - \(song.artist)", currentArtworkImage)
    }

    func resumePlayback() {
        guard let song = currentSong else { return }
        isPlaying = true
        lastUserPauseTimestamp = nil
        if silentPlayer?.isPlaying == false {
            silentPlayer?.play()
        }
        startNativeAutoNextWatchdog()
        let playJS = """
        window.__userPaused = false;
        window.__autoPlayGraceUntil = Date.now() + 2000;
        var v = document.querySelector('video');
        if (v) { v.muted = false; v.volume = 1.0; v.play(); 'ok'; } else { 'reload'; }
        """
        webView.evaluateJavaScript(playJS) { [weak self] result, _ in
            if let res = result as? String, res == "reload" {
                self?.loadWatchURL(videoId: song.videoId)
            }
        }
        updateNowPlayingInfo(song: song, image: currentArtworkImage)
        onStateChanged?(true, "\(song.title) - \(song.artist)", currentArtworkImage)
    }

    func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let status = body["status"] as? String,
              let song = currentSong else { return }

        switch status {
        case "progress":
            if let ct = body["currentTime"] as? Double { currentPlaybackTime = ct }
            if let dur = body["duration"] as? Double, dur > 5.0 { currentDuration = dur }
        case "playing":
            if let pausedAt = lastUserPauseTimestamp, Date().timeIntervalSince(pausedAt) < 0.8 {
                return
            }
            isPlaying = true
            isTransitioningTrack = false
            lastUserPauseTimestamp = nil
            onStateChanged?(true, "\(song.title) - \(song.artist)", currentArtworkImage)
            updateNowPlayingInfo(song: song, image: currentArtworkImage)
        case "paused":
            isPlaying = false
            lastUserPauseTimestamp = Date()
            onStateChanged?(false, "\(song.title) - \(song.artist)", currentArtworkImage)
            updateNowPlayingInfo(song: song, image: currentArtworkImage)
        case "ended":
            if !isTransitioningTrack {
                isTransitioningTrack = true
                playNext()
            }
        default:
            break
        }
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.beginBackgroundTaskIfNeeded()
            if self.silentPlayer?.isPlaying == false {
                self.silentPlayer?.play()
            }
            self.webView.evaluateJavaScript("window.__userPaused = false; window.__autoPlayGraceUntil = Date.now() + 1500; var v = document.querySelector('video'); if(v && v.paused) v.play().catch(function(e){});", completionHandler: nil)
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.beginBackgroundTaskIfNeeded()
            if self.silentPlayer?.isPlaying == false {
                self.silentPlayer?.play()
            }
            self.webView.evaluateJavaScript("window.__userPaused = false; window.__autoPlayGraceUntil = Date.now() + 1500; var v = document.querySelector('video'); if(v && v.paused) v.play().catch(function(e){});", completionHandler: nil)
            if let song = self.currentSong {
                self.updateNowPlayingInfo(song: song, image: self.currentArtworkImage)
            }
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
            self?.resumePlayback()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pausePlayback()
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