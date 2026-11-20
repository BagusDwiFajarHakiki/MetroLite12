import Foundation

struct SongItem {
    let videoId: String
    let title: String
    let artist: String
}

class InnerTubeService {
    static let shared = InnerTubeService()
    private init() {}

    // Identitas klien untuk InnerTube API
    private let clientContext: [String: Any] = [
        "client": [
            "clientName": "IOS_MUSIC",
            "clientVersion": "6.42",
            "hl": "id",
            "gl": "ID"
        ]
    ]

    func searchSongs(query: String, completion: @escaping ([SongItem]) -> Void) {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")

        let body: [String: Any] = [
            "context": clientContext,
            "query": query,
            "params": "EgWKAQIIAWoKEAMQBBAJEAoQBQ%3D%3D" // Filter khusus Songs
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let results = self.parseSearchResults(json: json)
            DispatchQueue.main.async {
                completion(results)
            }
        }.resume()
    }

    func fetchAudioStreamURL(videoId: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID_TESTSUITE",
                    "clientVersion": "1.9",
                    "androidSdkVersion": 30
                ]
            ],
            "videoId": videoId
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streamingData = json["streamingData"] as? [String: Any],
                  let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Cari stream audio/mp4 (AAC/M4A) yang didukung langsung oleh AVPlayer iOS 12
            for format in adaptiveFormats {
                if let mimeType = format["mimeType"] as? String,
                   mimeType.contains("audio/mp4"),
                   let urlString = format["url"] as? String,
                   let streamURL = URL(string: urlString) {
                    DispatchQueue.main.async {
                        completion(streamURL)
                    }
                    return
                }
            }

            DispatchQueue.main.async { completion(nil) }
        }.resume()
    }

    private func parseSearchResults(json: [String: Any]) -> [SongItem] {
        var items: [SongItem] = []
        guard let contents = json["contents"] as? [String: Any],
              let tabbedSearch = contents["tabbedSearchResultsRenderer"] as? [String: Any],
              let tabs = tabbedSearch["tabs"] as? [[String: Any]],
              let firstTab = tabs.first?["tabRenderer"] as? [String: Any],
              let tabContent = firstTab["content"] as? [String: Any],
              let sectionList = tabContent["sectionListRenderer"] as? [String: Any],
              let sections = sectionList["contents"] as? [[String: Any]] else {
            return items
        }

        for section in sections {
            guard let shelf = section["musicShelfRenderer"] as? [String: Any],
                  let shelfContents = shelf["contents"] as? [[String: Any]] else { continue }

            for entry in shelfContents {
                guard let itemRenderer = entry["musicResponsiveListItemRenderer"] as? [String: Any],
                      let playlistItemData = itemRenderer["playlistItemData"] as? [String: Any],
                      let videoId = playlistItemData["videoId"] as? String,
                      let flexColumns = itemRenderer["flexColumns"] as? [[String: Any]] else { continue }

                let title = extractText(from: flexColumns, index: 0) ?? "Unknown Title"
                let artist = extractText(from: flexColumns, index: 1) ?? "Unknown Artist"
                items.append(SongItem(videoId: videoId, title: title, artist: artist))
            }
        }
        return items
    }

    private func extractText(from columns: [[String: Any]], index: Int) -> String? {
        guard columns.indices.contains(index),
              let renderer = columns[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let textObj = renderer["text"] as? [String: Any],
              let runs = textObj["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String else { return nil }
        return text
    }
}