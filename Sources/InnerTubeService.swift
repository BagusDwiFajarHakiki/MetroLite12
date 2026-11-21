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

    // Memisahkan nama artis dan durasi (format mm:ss) serta membuang tahun rilis/label tipe
    private func parseArtistAndDuration(from raw: String, fallbackDuration: String = "") -> (artist: String, duration: String) {
        let parts = raw.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var foundDuration = fallbackDuration
        var cleanArtistParts: [String] = []

        let ignoredLabels: Set<String> = ["Lagu", "Song", "Video", "Single", "Album", "EP"]

        for part in parts {
            // Cek apakah bagian ini adalah durasi (contoh: 3:45 atau 1:02:10)
            if part.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
                foundDuration = part
                continue
            }
            // Abaikan tahun 4 digit (contoh: 2024, 2026) atau label kategori
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