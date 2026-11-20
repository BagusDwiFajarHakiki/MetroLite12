import Foundation

struct SongItem {
    let videoId: String
    let title: String
    let artist: String
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
        // Mencoba klien IOS terlebih dahulu karena mengembalikan stream audio/mp4 langsung untuk AVPlayer
        tryFetchStream(videoId: videoId, clientName: "IOS", clientVersion: "19.29.1", userAgent: "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)") { url, err in
            if let url = url {
                completion(url, nil)
            } else {
                // Fallback ke ANDROID_VR jika klien IOS dibatasi
                self.tryFetchStream(videoId: videoId, clientName: "ANDROID_VR", clientVersion: "1.56.21", userAgent: "com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip") { fallbackURL, fallbackErr in
                    completion(fallbackURL, fallbackErr ?? err)
                }
            }
        }
    }

    private func tryFetchStream(videoId: String, clientName: String, clientVersion: String, userAgent: String, completion: @escaping (URL?, String?) -> Void) {
        guard let url = URL(string: "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false") else {
            completion(nil, "URL player salah")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": clientName,
                    "clientVersion": clientVersion,
                    "hl": "id",
                    "gl": "ID"
                ]
            ],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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

                // Prioritas 2: format mp4 gabungan apa pun jika audio-only tidak tersedia
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