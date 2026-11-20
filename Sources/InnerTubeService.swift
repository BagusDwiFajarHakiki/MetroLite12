import Foundation

struct SongItem {
    let videoId: String
    let title: String
    let artist: String
}

class InnerTubeService {
    static let shared = InnerTubeService()
    private init() {}

    // Menyimpan visitorData dari sesi pencarian untuk lolos pengecekan bot
    private var visitorData: String?

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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

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

            // Tangkap visitorData dari responseContext agar dianggap sesi browser/klien sah
            if let responseContext = json["responseContext"] as? [String: Any],
               let vData = responseContext["visitorData"] as? String {
                self.visitorData = vData
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

    func fetchAudioStreamURL(videoId: String, completion: @escaping (URL?, String?) -> Void) {
        // Prioritas 1: TVHTML5_SIMPLY_EMBEDDED_PLAYER (bebas poToken & bebas login untuk lagu publik)
        tryFetchTVEmbedded(videoId: videoId) { url, err in
            if let url = url {
                completion(url, nil)
            } else {
                // Prioritas 2: ANDROID_MUSIC dengan visitorData
                self.tryFetchAndroidMusic(videoId: videoId) { fallbackURL, fallbackErr in
                    completion(fallbackURL, fallbackErr ?? err)
                }
            }
        }
    }

    private func tryFetchTVEmbedded(videoId: String, completion: @escaping (URL?, String?) -> Void) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            completion(nil, "URL player salah")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version", forHTTPHeaderField: "User-Agent")
        if let vData = visitorData {
            request.setValue(vData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientDict: [String: Any] = [
            "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            "clientVersion": "2.0",
            "hl": "id",
            "gl": "ID"
        ]
        if let vData = visitorData {
            clientDict["visitorData"] = vData
        }

        let body: [String: Any] = [
            "context": [
                "client": clientDict,
                "thirdParty": [
                    "embedUrl": "https://www.youtube.com/"
                ]
            ],
            "videoId": videoId,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        executePlayerRequest(request: request, completion: completion)
    }

    private func tryFetchAndroidMusic(videoId: String, completion: @escaping (URL?, String?) -> Void) {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            completion(nil, "URL player salah")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.apps.youtube.music/7.03.52 (Linux; U; Android 14) gzip", forHTTPHeaderField: "User-Agent")
        if let vData = visitorData {
            request.setValue(vData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientDict: [String: Any] = [
            "clientName": "ANDROID_MUSIC",
            "clientVersion": "7.03.52",
            "androidSdkVersion": 34,
            "hl": "id",
            "gl": "ID"
        ]
        if let vData = visitorData {
            clientDict["visitorData"] = vData
        }

        let body: [String: Any] = [
            "context": [
                "client": clientDict
            ],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        executePlayerRequest(request: request, completion: completion)
    }

    private func executePlayerRequest(request: URLRequest, completion: @escaping (URL?, String?) -> Void) {
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(nil, "Respons player kosong") }
                return
            }

            if let streamingData = json["streamingData"] as? [String: Any] {
                let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
                let formats = streamingData["formats"] as? [[String: Any]] ?? []
                let allFormats = adaptive + formats

                // Prioritas 1: audio/mp4 (AAC/M4A native iOS)
                for format in allFormats {
                    if let mimeType = format["mimeType"] as? String,
                       mimeType.contains("audio/mp4"),
                       let urlString = format["url"] as? String,
                       let streamURL = URL(string: urlString) {
                        DispatchQueue.main.async { completion(streamURL, nil) }
                        return
                    }
                }

                // Prioritas 2: format mp4 gabungan jika audio-only membutuhkan cipher
                for format in allFormats {
                    if let mimeType = format["mimeType"] as? String,
                       mimeType.contains("video/mp4"),
                       let urlString = format["url"] as? String,
                       let streamURL = URL(string: urlString) {
                        DispatchQueue.main.async { completion(streamURL, nil) }
                        return
                    }
                }
            }

            let playability = (json["playabilityStatus"] as? [String: Any])?["reason"] as? String ?? "Stream tidak tersedia"
            DispatchQueue.main.async { completion(nil, playability) }
        }.resume()
    }

    // Pemindai rekursif untuk menangkap item lagu dari struktur JSON YouTube Music
    private func extractSongsRecursively(from node: Any, results: inout [SongItem], seenIds: inout Set<String>) {
        if let dict = node as? [String: Any] {
            if let itemRenderer = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                if let videoId = extractVideoId(from: itemRenderer), !seenIds.contains(videoId),
                   let flexColumns = itemRenderer["flexColumns"] as? [[String: Any]] {
                    let title = extractText(from: flexColumns, index: 0) ?? "Unknown Title"
                    let artist = extractText(from: flexColumns, index: 1) ?? "YouTube Music"
                    seenIds.insert(videoId)
                    results.append(SongItem(videoId: videoId, title: title, artist: artist))
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