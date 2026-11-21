import UIKit

struct SavedSongItem: Codable {
    let videoId: String
    let title: String
    let artist: String
    let duration: String

    func toSongItem() -> SongItem {
        return SongItem(videoId: videoId, title: title, artist: artist, duration: duration)
    }

    static func from(_ song: SongItem) -> SavedSongItem {
        return SavedSongItem(videoId: song.videoId, title: song.title, artist: song.artist, duration: song.duration)
    }
}

struct UserPlaylist: Codable {
    let id: String
    var name: String
    var songs: [SavedSongItem]
}

class PlaylistStorageManager {
    static let shared = PlaylistStorageManager()

    private(set) var playlists: [UserPlaylist] = []
    private(set) var downloadingIds = Set<String>()
    private(set) var downloadErrors: [String: String] = [:]
    var onPlaylistsChanged: (() -> Void)?

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("MetroLitePlaylists.json")
    }

    private var thumbsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("OfflineThumbs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var audioDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("OfflineAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        loadFromDisk()
    }

    private func notifyStateUpdated() {
        DispatchQueue.main.async {
            self.onPlaylistsChanged?()
            NotificationCenter.default.post(name: NSNotification.Name("MetroLitePlaylistsUpdated"), object: nil)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UserPlaylist].self, from: data) else {
            playlists = []
            return
        }
        playlists = decoded
    }

    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: fileURL, options: .atomic)
        }
        notifyStateUpdated()
    }

    @discardableResult
    func createPlaylist(name: String) -> UserPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Playlist Baru" : trimmed
        let newPlaylist = UserPlaylist(id: UUID().uuidString, name: finalName, songs: [])
        playlists.append(newPlaylist)
        saveToDisk()
        return newPlaylist
    }

    func deletePlaylist(at index: Int) {
        guard playlists.indices.contains(index) else { return }
        playlists.remove(at: index)
        saveToDisk()
    }

    func addSong(_ song: SongItem, toPlaylistId playlistId: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        if !playlists[idx].songs.contains(where: { $0.videoId == song.videoId }) {
            playlists[idx].songs.append(SavedSongItem.from(song))
            saveToDisk()
        }
        cacheThumbnailLocally(for: song)
        downloadAudioFile(for: song)
    }

    func removeSong(at songIndex: Int, fromPlaylistId playlistId: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }),
              playlists[idx].songs.indices.contains(songIndex) else { return }
        let removed = playlists[idx].songs.remove(at: songIndex)
        downloadErrors.removeValue(forKey: removed.videoId)
        saveToDisk()
        if !isSongSaved(removed.videoId) {
            try? FileManager.default.removeItem(at: audioFilePath(for: removed.videoId))
            try? FileManager.default.removeItem(at: thumbsDirectory.appendingPathComponent("\(removed.videoId).jpg"))
        }
    }

    func isSongSaved(_ videoId: String) -> Bool {
        return playlists.contains { $0.songs.contains(where: { $0.videoId == videoId }) }
    }

    func isAudioDownloaded(_ videoId: String) -> Bool {
        let path = audioFilePath(for: videoId).path
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return false
        }
        return size > 25_000
    }

    func localAudioURL(for videoId: String) -> URL? {
        let url = audioFilePath(for: videoId)
        return isAudioDownloaded(videoId) ? url : nil
    }

    private func audioFilePath(for videoId: String) -> URL {
        return audioDirectory.appendingPathComponent("\(videoId).m4a")
    }

    func loadLocalThumbnail(videoId: String) -> UIImage? {
        let localFile = thumbsDirectory.appendingPathComponent("\(videoId).jpg")
        guard let data = try? Data(contentsOf: localFile) else { return nil }
        return UIImage(data: data)
    }

    private func cacheThumbnailLocally(for song: SongItem) {
        let localFile = thumbsDirectory.appendingPathComponent("\(song.videoId).jpg")
        if FileManager.default.fileExists(atPath: localFile.path) { return }
        ImageLoader.shared.loadImage(from: song.thumbnailURL) { image in
            guard let image = image, let jpegData = image.jpegData(compressionQuality: 0.85) else { return }
            try? jpegData.write(to: localFile, options: .atomic)
        }
    }

    func downloadAudioFile(for song: SongItem) {
        if isAudioDownloaded(song.videoId) || downloadingIds.contains(song.videoId) {
            notifyStateUpdated()
            return
        }
        downloadErrors.removeValue(forKey: song.videoId)
        downloadingIds.insert(song.videoId)
        notifyStateUpdated()

        InnerTubeService.shared.fetchDirectAudioURL(videoId: song.videoId) { [weak self] streamURL, matchedUserAgent, errorReason in
            guard let self = self else { return }
            guard let streamURL = streamURL else {
                self.downloadingIds.remove(song.videoId)
                self.downloadErrors[song.videoId] = errorReason ?? "URL stream kosong"
                self.notifyStateUpdated()
                return
            }

            // Unduh menggunakan chunked HTTP Range agar tidak ditolak server googlevideo.com
            self.downloadInChunks(videoId: song.videoId, url: streamURL, userAgent: matchedUserAgent, startByte: 0, accumulatedData: Data())
        }
    }

    private func downloadInChunks(videoId: String, url: URL, userAgent: String, startByte: Int, accumulatedData: Data) {
        let chunkSize = 512 * 1024 // 512 KB per permintaan Range
        let endByte = startByte + chunkSize - 1

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if !userAgent.isEmpty {
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        req.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.downloadingIds.remove(videoId)
                self.downloadErrors[videoId] = "Gagal unduh: \(error.localizedDescription)"
                self.notifyStateUpdated()
                return
            }

            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 0

            guard (statusCode == 200 || statusCode == 206), let chunk = data, !chunk.isEmpty else {
                self.downloadingIds.remove(videoId)
                self.downloadErrors[videoId] = "HTTP \(statusCode)"
                self.notifyStateUpdated()
                return
            }

            var updatedData = accumulatedData
            updatedData.append(chunk)

            // Cek total ukuran file dari header Content-Range (format: bytes 0-524287/3456789)
            var totalExpectedBytes: Int? = nil
            if let contentRange = httpResp?.allHeaderFields["Content-Range"] as? String,
               let slashIndex = contentRange.lastIndex(of: "/") {
                let totalStr = String(contentRange[contentRange.index(after: slashIndex)...])
                totalExpectedBytes = Int(totalStr)
            }

            let isFinished: Bool
            if statusCode == 200 {
                isFinished = true
            } else if let total = totalExpectedBytes {
                isFinished = updatedData.count >= total
            } else {
                isFinished = chunk.count < chunkSize
            }

            if isFinished {
                let destURL = self.audioFilePath(for: videoId)
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try updatedData.write(to: destURL, options: .atomic)
                    self.downloadErrors.removeValue(forKey: videoId)
                } catch {
                    self.downloadErrors[videoId] = "Gagal simpan file"
                }
                self.downloadingIds.remove(videoId)
                self.notifyStateUpdated()
            } else {
                self.downloadInChunks(videoId: videoId, url: url, userAgent: userAgent, startByte: updatedData.count, accumulatedData: updatedData)
            }
        }.resume()
    }
}