import UIKit

struct SongItem {
    let videoId: String
    let title: String
    let artist: String
    var thumbnailURL: URL? {
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }
}

class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private init() {
        cache.countLimit = 60 // Batasi cache maksimal 60 gambar agar RAM iPhone 5s tetap lega
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