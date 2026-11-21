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
        DispatchQueue.main.async {
            self.onPlaylistsChanged?()
        }
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
        return size > 50_000
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
            return
        }
        downloadingIds.insert(song.videoId)
        DispatchQueue.main.async { self.onPlaylistsChanged?() }

        InnerTubeService.shared.fetchDirectAudioURL(videoId: song.videoId) { [weak self] streamURL in
            guard let self = self else { return }
            guard let streamURL = streamURL else {
                self.downloadingIds.remove(song.videoId)
                DispatchQueue.main.async { self.onPlaylistsChanged?() }
                return
            }

            var req = URLRequest(url: streamURL)
            req.setValue("com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            URLSession.shared.downloadTask(with: req) { tempURL, _, _ in
                defer {
                    self.downloadingIds.remove(song.videoId)
                    DispatchQueue.main.async { self.onPlaylistsChanged?() }
                }
                guard let tempURL = tempURL else { return }
                let destURL = self.audioFilePath(for: song.videoId)
                try? FileManager.default.removeItem(at: destURL)
                try? FileManager.default.moveItem(at: tempURL, to: destURL)
            }.resume()
        }
    }
}