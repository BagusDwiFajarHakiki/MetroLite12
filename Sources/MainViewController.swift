import UIKit

class MainViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private let tableView = UITableView()
    private let playerBar = UIView()
    private let nowPlayingLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)

    private var songs: [SongItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "MetroLite 12"
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupUI()

        AudioPlayerManager.shared.onStateChanged = { [weak self] isPlaying, title in
            self?.nowPlayingLabel.text = title
            self?.playPauseButton.setTitle(isPlaying ? "Pause" : "Play", for: .normal)
        }
    }

    private func setupUI() {
        searchBar.delegate = self
        searchBar.placeholder = "Cari lagu atau artis..."
        searchBar.barStyle = .black
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1.0)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        playerBar.backgroundColor = UIColor(white: 0.14, alpha: 1.0)
        playerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerBar)

        nowPlayingLabel.text = "Belum ada lagu diputar"
        nowPlayingLabel.textColor = .white
        nowPlayingLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(nowPlayingLabel)

        playPauseButton.setTitle("Play", for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(playPauseButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: guide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            playerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            playerBar.heightAnchor.constraint(equalToConstant: 54),

            nowPlayingLabel.leadingAnchor.constraint(equalTo: playerBar.leadingAnchor, constant: 14),
            nowPlayingLabel.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            nowPlayingLabel.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -10),

            playPauseButton.trailingAnchor.constraint(equalTo: playerBar.trailingAnchor, constant: -14),
            playPauseButton.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 60),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: playerBar.topAnchor)
        ])
    }

    @objc private func didTapPlayPause() {
        AudioPlayerManager.shared.togglePlayPause()
    }

    // MARK: - UISearchBarDelegate
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard let query = searchBar.text, !query.isEmpty else { return }
        nowPlayingLabel.text = "Mencari..."
        InnerTubeService.shared.searchSongs(query: query) { [weak self] results in
            self?.songs = results
            self?.tableView.reloadData()
            if AudioPlayerManager.shared.currentSong == nil {
                self?.nowPlayingLabel.text = "Pilih lagu untuk diputar"
            }
        }
    }

    // MARK: - UITableViewDataSource & Delegate
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return songs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "SongCell")
        let song = songs[indexPath.row]
        cell.backgroundColor = .clear
        cell.textLabel?.text = song.title
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        cell.detailTextLabel?.text = song.artist
        cell.detailTextLabel?.textColor = .lightGray
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let song = songs[indexPath.row]
        nowPlayingLabel.text = "Memuat stream: \(song.title)..."
        InnerTubeService.shared.fetchAudioStreamURL(videoId: song.videoId) { [weak self] url in
            guard let streamURL = url else {
                self?.nowPlayingLabel.text = "Gagal mengambil stream audio"
                return
            }
            AudioPlayerManager.shared.play(song: song, streamURL: streamURL)
        }
    }
}