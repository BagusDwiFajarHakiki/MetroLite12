import UIKit

class SongTableViewCell: UITableViewCell {
    let thumbImageView = UIImageView()
    let titleLabel = UILabel()
    let artistLabel = UILabel()
    var currentVideoId: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .gray

        thumbImageView.contentMode = .scaleAspectFill
        thumbImageView.clipsToBounds = true
        thumbImageView.layer.cornerRadius = 6
        thumbImageView.backgroundColor = UIColor(white: 0.18, alpha: 1.0)
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbImageView)

        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        artistLabel.textColor = .lightGray
        artistLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(artistLabel)

        NSLayoutConstraint.activate([
            thumbImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            thumbImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbImageView.widthAnchor.constraint(equalToConstant: 48),
            thumbImageView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: thumbImageView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: thumbImageView.topAnchor, constant: 4),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            artistLabel.bottomAnchor.constraint(equalTo: thumbImageView.bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

class MainViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private let tableView = UITableView()
    private let playerBar = UIView()
    private let miniThumbView = UIImageView()
    private let nowPlayingLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)

    private var songs: [SongItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "MetroLite 12"
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupUI()

        AudioPlayerManager.shared.onStateChanged = { [weak self] isPlaying, title, artwork in
            self?.nowPlayingLabel.text = title
            self?.playPauseButton.setTitle(isPlaying ? "Pause" : "Play", for: .normal)
            if let artwork = artwork {
                self?.miniThumbView.image = artwork
            }
        }

        performSearch(query: "Lagu Pop Indonesia Hits")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AudioPlayerManager.shared.attachToWindow(view.window)
    }

    private func setupUI() {
        searchBar.delegate = self
        searchBar.placeholder = "Cari lagu atau artis..."
        searchBar.barStyle = .black
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongTableViewCell.self, forCellReuseIdentifier: "SongCell")
        tableView.rowHeight = 64
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1.0)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        playerBar.backgroundColor = UIColor(white: 0.14, alpha: 1.0)
        playerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerBar)

        miniThumbView.contentMode = .scaleAspectFill
        miniThumbView.clipsToBounds = true
        miniThumbView.layer.cornerRadius = 5
        miniThumbView.backgroundColor = UIColor(white: 0.22, alpha: 1.0)
        miniThumbView.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(miniThumbView)

        nowPlayingLabel.text = "Memuat katalog..."
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
            playerBar.heightAnchor.constraint(equalToConstant: 58),

            miniThumbView.leadingAnchor.constraint(equalTo: playerBar.leadingAnchor, constant: 12),
            miniThumbView.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            miniThumbView.widthAnchor.constraint(equalToConstant: 42),
            miniThumbView.heightAnchor.constraint(equalToConstant: 42),

            nowPlayingLabel.leadingAnchor.constraint(equalTo: miniThumbView.trailingAnchor, constant: 10),
            nowPlayingLabel.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            nowPlayingLabel.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -8),

            playPauseButton.trailingAnchor.constraint(equalTo: playerBar.trailingAnchor, constant: -14),
            playPauseButton.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 56),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: playerBar.topAnchor)
        ])
    }

    @objc private func didTapPlayPause() {
        AudioPlayerManager.shared.togglePlayPause()
    }

    private func performSearch(query: String) {
        nowPlayingLabel.text = "Mencari: \(query)..."
        InnerTubeService.shared.searchSongs(query: query) { [weak self] results, errorMsg in
            self?.songs = results
            self?.tableView.reloadData()
            if let errorMsg = errorMsg {
                self?.nowPlayingLabel.text = errorMsg
            } else if AudioPlayerManager.shared.currentSong == nil {
                self?.nowPlayingLabel.text = "Ditemukan \(results.count) lagu"
            }
        }
    }

    // MARK: - UISearchBarDelegate
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard let query = searchBar.text, !query.isEmpty else { return }
        performSearch(query: query)
    }

    // MARK: - UITableViewDataSource & Delegate
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return songs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SongCell", for: indexPath) as! SongTableViewCell
        let song = songs[indexPath.row]
        cell.currentVideoId = song.videoId
        cell.titleLabel.text = song.title
        cell.artistLabel.text = song.artist
        cell.thumbImageView.image = nil

        ImageLoader.shared.loadImage(from: song.thumbnailURL) { image in
            if cell.currentVideoId == song.videoId {
                cell.thumbImageView.image = image
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let song = songs[indexPath.row]
        AudioPlayerManager.shared.play(song: song)
    }
}