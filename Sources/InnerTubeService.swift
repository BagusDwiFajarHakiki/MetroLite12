import UIKit

struct SongItem {
    let videoId: String
    let title: String
    let artist: String
    let duration: String
    var thumbnailURL: URL? {
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }
}

class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private init() {
        cache.countLimit = 80
    }

    func loadImage(from url: URL?, completion: @escaping (UIImage?) -> Void) {
        guard let url = url else {
            completion(nil)
            return
        }
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self?.cache.setObject(image, forKey: key)
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
}

class InnerTubeService {
    static let shared = InnerTubeService()
    private init() {}

    private let webContext: [String: Any] = [
        "client": [
            "clientName": "WEB_REMIX",
            "clientVersion": "1.20260101.01.00",
            "hl": "id",
            "gl": "ID"
        ]
    ]

    func searchSongs(query: String, completion: @escaping ([SongItem], String?) -> Void) {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            completion([], "URL tidak valid")
            return
        }

        var request = makeBaseRequest(url: url)
        let body: [String: Any] = [
            "context": webContext,
            "query": query,
            "params": "EgWKAQIIAWoKEAMQBBAJEAoQBQ%3D%3D"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion([], "Error jaringan: \(error.localizedDescription)") }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion([], "Gagal membaca JSON dari server") }
                return
            }

            var results: [SongItem] = []
            var seenIds = Set<String>()
            self.extractSongsRecursively(from: json, results: &results, seenIds: &seenIds)

            DispatchQueue.main.async {
                if results.isEmpty {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    completion([], "0 lagu ditemukan (HTTP \(statusCode))")
                } else {
                    completion(results, nil)
                }
            }
        }.resume()
    }

    func fetchRelatedSongs(videoId: String, completion: @escaping ([SongItem]) -> Void) {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/next?prettyPrint=false") else {
            completion([])
            return
        }

        var request = makeBaseRequest(url: url)
        let body: [String: Any] = [
            "context": webContext,
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "isAudioOnly": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var results: [SongItem] = []
            var seenIds: Set<String> = [videoId]
            self.extractRelatedRecursively(from: json, results: &results, seenIds: &seenIds)

            DispatchQueue.main.async {
                completion(results)
            }
        }.resume()
    }

    // Mengembalikan pasangan (URL stream audio langsung, User-Agent yang cocok untuk mengunduhnya)
    func fetchDirectAudioURL(videoId: String, completion: @escaping (URL?, String) -> Void) {
        let candidates: [(client: [String: Any], userAgent: String, clientId: String)] = [
            (
                client: [
                    "clientName": "ANDROID_VR",
                    "clientVersion": "1.60.19",
                    "deviceMake": "Oculus",
                    "deviceModel": "Quest 3",
                    "androidSdkVersion": 32,
                    "osName": "Android",
                    "osVersion": "12L",
                    "hl": "id",
                    "gl": "ID"
                ],
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                clientId: "28"
            ),
            (
                client: [
                    "clientName": "IOS",
                    "clientVersion": "20.10.4",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iOS",
                    "osVersion": "18.3.2.22D82",
                    "hl": "id",
                    "gl": "ID"
                ],
                userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)",
                clientId: "5"
            ),
            (
                client: [
                    "clientName": "ANDROID",
                    "clientVersion": "20.10.38",
                    "androidSdkVersion": 34,
                    "osName": "Android",
                    "osVersion": "14",
                    "hl": "id",
                    "gl": "ID"
                ],
                userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
                clientId: "3"
            )
        ]

        tryFetchAudioWithClient(videoId: videoId, candidates: candidates, index: 0, completion: completion)
    }

    private func tryFetchAudioWithClient(
        videoId: String,
        candidates: [(client: [String: Any], userAgent: String, clientId: String)],
        index: Int,
        completion: @escaping (URL?, String) -> Void
    ) {
        guard candidates.indices.contains(index),
              let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            DispatchQueue.main.async { completion(nil, "") }
            return
        }

        let current = candidates[index]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(current.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(current.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        if let ver = current.client["clientVersion"] as? String {
            request.setValue(ver, forHTTPHeaderField: "X-YouTube-Client-Version")
        }

        let body: [String: Any] = [
            "context": ["client": current.client],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streamingData = json["streamingData"] as? [String: Any] else {
                self?.tryFetchAudioWithClient(videoId: videoId, candidates: candidates, index: index + 1, completion: completion)
                return
            }

            let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
            let formats = streamingData["formats"] as? [[String: Any]] ?? []

            // 1. Cari itag 140 (audio/mp4 128kbps AAC) atau audio/mp4 lainnya yang memiliki direct URL
            var bestAudioURL: String?
            for fmt in adaptiveFormats {
                if let mime = fmt["mimeType"] as? String,
                   mime.contains("audio/mp4"),
                   let directUrl = fmt["url"] as? String,
                   !directUrl.isEmpty {
                    bestAudioURL = directUrl
                    if (fmt["itag"] as? Int) == 140 { break }
                }
            }

            // 2. Cadangan: format audio apa saja yang punya direct URL
            if bestAudioURL == nil {
                for fmt in adaptiveFormats {
                    if let mime = fmt["mimeType"] as? String,
                       mime.contains("audio/"),
                       let directUrl = fmt["url"] as? String,
                       !directUrl.isEmpty {
                        bestAudioURL = directUrl
                        break
                    }
                }
            }

            // 3. Cadangan terakhir: format muxed mp4 (audio+video ringan) agar AVPlayer tetap bisa memutar suaranya
            if bestAudioURL == nil {
                for fmt in formats {
                    if let mime = fmt["mimeType"] as? String,
                       mime.contains("video/mp4"),
                       let directUrl = fmt["url"] as? String,
                       !directUrl.isEmpty {
                        bestAudioURL = directUrl
                        break
                    }
                }
            }

            if let urlStr = bestAudioURL, let streamURL = URL(string: urlStr) {
                DispatchQueue.main.async { completion(streamURL, current.userAgent) }
            } else {
                self?.tryFetchAudioWithClient(videoId: videoId, candidates: candidates, index: index + 1, completion: completion)
            }
        }.resume()
    }

    private func makeBaseRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func extractSongsRecursively(from node: Any, results: inout [SongItem], seenIds: inout Set<String>) {
        if let dict = node as? [String: Any] {
            if let itemRenderer = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                if let videoId = extractVideoId(from: itemRenderer), !seenIds.contains(videoId),
                   let flexColumns = itemRenderer["flexColumns"] as? [[String: Any]] {
                    let title = extractText(from: flexColumns, index: 0) ?? "Unknown Title"
                    let rawMeta = extractText(from: flexColumns, index: 1) ?? "YouTube Music"
                    let parsed = parseArtistAndDuration(from: rawMeta)
                    seenIds.insert(videoId)
                    results.append(SongItem(videoId: videoId, title: title, artist: parsed.artist, duration: parsed.duration))
                }
            }
            for (_, value) in dict {
                extractSongsRecursively(from: value, results: &results, seenIds: &seenIds)
            }
        } else if let array = node as? [Any] {
            for element in array {
                extractSongsRecursively(from: element, results: &results, seenIds: &seenIds)
            }
        }
    }

    private func extractRelatedRecursively(from node: Any, results: inout [SongItem], seenIds: inout Set<String>) {
        if let dict = node as? [String: Any] {
            if let panelVideo = dict["playlistPanelVideoRenderer"] as? [String: Any],
               let videoId = panelVideo["videoId"] as? String,
               !seenIds.contains(videoId) {
                let title = extractRunsText(from: panelVideo["title"]) ?? "Unknown Title"
                let rawByline = extractRunsText(from: panelVideo["longBylineText"])
                    ?? extractRunsText(from: panelVideo["shortBylineText"])
                    ?? "YouTube Music"
                let durationText = extractRunsText(from: panelVideo["lengthText"]) ?? ""
                let parsed = parseArtistAndDuration(from: rawByline, fallbackDuration: durationText)
                seenIds.insert(videoId)
                results.append(SongItem(videoId: videoId, title: title, artist: parsed.artist, duration: parsed.duration))
            }
            for (_, value) in dict {
                extractRelatedRecursively(from: value, results: &results, seenIds: &seenIds)
            }
        } else if let array = node as? [Any] {
            for element in array {
                extractRelatedRecursively(from: element, results: &results, seenIds: &seenIds)
            }
        }
    }

    private func parseArtistAndDuration(from raw: String, fallbackDuration: String = "") -> (artist: String, duration: String) {
        let parts = raw.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var foundDuration = fallbackDuration
        var cleanArtistParts: [String] = []

        let ignoredLabels: Set<String> = ["Lagu", "Song", "Video", "Single", "Album", "EP"]

        for part in parts {
            if part.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
                foundDuration = part
                continue
            }
            if part.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil || ignoredLabels.contains(part) {
                continue
            }
            cleanArtistParts.append(part)
        }

        let artistName = cleanArtistParts.first ?? (parts.first ?? "YouTube Music")
        return (artistName, foundDuration)
    }

    private func extractRunsText(from obj: Any?) -> String? {
        guard let dict = obj as? [String: Any],
              let runs = dict["runs"] as? [[String: Any]] else { return nil }
        let text = runs.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    private func extractVideoId(from renderer: [String: Any]) -> String? {
        if let playlistData = renderer["playlistItemData"] as? [String: Any],
           let vid = playlistData["videoId"] as? String {
            return vid
        }
        if let overlay = renderer["overlay"] as? [String: Any],
           let musicOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = musicOverlay["content"] as? [String: Any],
           let playButton = content["musicPlayButtonRenderer"] as? [String: Any],
           let navEndpoint = playButton["playNavigationEndpoint"] as? [String: Any],
           let watchEndpoint = navEndpoint["watchEndpoint"] as? [String: Any],
           let vid = watchEndpoint["videoId"] as? String {
            return vid
        }
        return nil
    }

    private func extractText(from columns: [[String: Any]], index: Int) -> String? {
        guard columns.indices.contains(index),
              let renderer = columns[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let textObj = renderer["text"] as? [String: Any],
              let runs = textObj["runs"] as? [[String: Any]] else { return nil }
        let combined = runs.compactMap { $0["text"] as? String }.joined()
        return combined.isEmpty ? nil : combined
    }
}