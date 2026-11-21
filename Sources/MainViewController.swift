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

// MARK: - Tab 1: Streaming
class StreamingViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private let tableView = UITableView()
    private let statusBanner = UILabel()

    private var songs: [SongItem] = []
    private var isShowingRadioQueue = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Streaming"
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupUI()

        // Jika daftar antrean radio sejenis bertambah otomatis, tampilkan di daftar
        AudioPlayerManager.shared.onQueueUpdated = { [weak self] updatedQueue in
            guard let self = self else { return }
            self.songs = updatedQueue
            self.isShowingRadioQueue = true
            self.statusBanner.text = "  Antrean Radio Sejenis (\(updatedQueue.count) lagu)"
            self.tableView.reloadData()
        }

        performSearch(query: "Lagu Pop Indonesia Hits")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    private func setupUI() {
        searchBar.delegate = self
        searchBar.placeholder = "Cari lagu atau artis..."
        searchBar.barStyle = .black
        searchBar.isTranslucent = false
        searchBar.barTintColor = UIColor(white: 0.10, alpha: 1.0)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        statusBanner.text = "  Memuat katalog..."
        statusBanner.textColor = UIColor(white: 0.65, alpha: 1.0)
        statusBanner.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        statusBanner.backgroundColor = UIColor(white: 0.11, alpha: 1.0)
        statusBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBanner)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongTableViewCell.self, forCellReuseIdentifier: "SongCell")
        tableView.rowHeight = 64
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.18, alpha: 1.0)
        // Beri ruang bawah 62pt agar baris terakhir tidak tertutup mini-player
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 62, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: guide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusBanner.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            statusBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBanner.heightAnchor.constraint(equalToConstant: 24),

            tableView.topAnchor.constraint(equalTo: statusBanner.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])
    }

    private func performSearch(query: String) {
        isShowingRadioQueue = false
        statusBanner.text = "  Mencari: \(query)..."
        InnerTubeService.shared.searchSongs(query: query) { [weak self] results, errorMsg in
            self?.songs = results
            self?.tableView.reloadData()
            if let errorMsg = errorMsg {
                self?.statusBanner.text = "  \(errorMsg)"
            } else {
                self?.statusBanner.text = "  Hasil pencarian (\(results.count) lagu)"
            }
        }
    }

    func refreshTable() {
        tableView.reloadData()
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

        let isCurrent = AudioPlayerManager.shared.currentSong?.videoId == song.videoId
        cell.titleLabel.textColor = isCurrent ? UIColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1.0) : .white

        ImageLoader.shared.loadImage(from: song.thumbnailURL) { image in
            if cell.currentVideoId == song.videoId {
                cell.thumbImageView.image = image
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let selectedSong = songs[indexPath.row]
        if isShowingRadioQueue {
            // Jika mengklik dari antrean radio yang sudah ada, langsung lompat ke lagu tersebut
            AudioPlayerManager.shared.playFromQueue(songs: songs, at: indexPath.row)
        } else {
            // Jika mengklik hasil pencarian baru, bangun antrean radio lagu-lagu yang sejenis
            AudioPlayerManager.shared.startRadioWithSong(selectedSong)
        }
        tableView.reloadData()
    }
}

// MARK: - Tab 2: Koleksi (Placeholder untuk fitur download)
class KoleksiViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Koleksi"
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
    }
}

// MARK: - Root TabBar Controller + Global Mini-Player
class RootTabBarController: UITabBarController {
    private let playerBar = UIView()
    private let topBorder = UIView()
    private let miniThumbView = UIImageView()
    private let nowPlayingLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)

    private let streamingVC = StreamingViewController()
    private let koleksiVC = KoleksiViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupTabs()
        setupGlobalMiniPlayer()

        AudioPlayerManager.shared.onStateChanged = { [weak self] isPlaying, title, artwork in
            self?.nowPlayingLabel.text = title
            self?.playPauseButton.setTitle(isPlaying ? "Pause" : "Play", for: .normal)
            if let artwork = artwork {
                self?.miniThumbView.image = artwork
            }
            self?.streamingVC.refreshTable()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AudioPlayerManager.shared.attachToWindow(view.window)
    }

    private func setupTabs() {
        let nav1 = UINavigationController(rootViewController: streamingVC)
        nav1.navigationBar.barStyle = .black
        nav1.navigationBar.isTranslucent = false
        nav1.navigationBar.barTintColor = UIColor(white: 0.10, alpha: 1.0)
        nav1.navigationBar.tintColor = .white
        nav1.tabBarItem = UITabBarItem(title: "Streaming", image: makeTabIcon(systemFallback: "♫"), tag: 0)

        let nav2 = UINavigationController(rootViewController: koleksiVC)
        nav2.navigationBar.barStyle = .black
        nav2.navigationBar.isTranslucent = false
        nav2.navigationBar.barTintColor = UIColor(white: 0.10, alpha: 1.0)
        nav2.navigationBar.tintColor = .white
        nav2.tabBarItem = UITabBarItem(title: "Koleksi", image: makeTabIcon(systemFallback: "↓"), tag: 1)

        tabBar.barStyle = .black
        tabBar.isTranslucent = false
        tabBar.barTintColor = UIColor(white: 0.10, alpha: 1.0)
        tabBar.tintColor = UIColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1.0)
        tabBar.unselectedItemTintColor = .lightGray

        viewControllers = [nav1, nav2]
    }

    // Membuat ikon sederhana bawaan untuk TabBar iOS 12 tanpa bergantung SF Symbols (iOS 13+)
    private func makeTabIcon(systemFallback symbol: String) -> UIImage? {
        let size = CGSize(width: 24, height: 24)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let strSize = symbol.size(withAttributes: attrs)
        let rect = CGRect(x: (size.width - strSize.width) / 2, y: (size.height - strSize.height) / 2, width: strSize.width, height: strSize.height)
        symbol.draw(in: rect, withAttributes: attrs)
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }

    private func setupGlobalMiniPlayer() {
        playerBar.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        playerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerBar)

        topBorder.backgroundColor = UIColor(white: 0.24, alpha: 1.0)
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(topBorder)

        miniThumbView.contentMode = .scaleAspectFill
        miniThumbView.clipsToBounds = true
        miniThumbView.layer.cornerRadius = 5
        miniThumbView.backgroundColor = UIColor(white: 0.24, alpha: 1.0)
        miniThumbView.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(miniThumbView)

        nowPlayingLabel.text = "Pilih lagu untuk mulai"
        nowPlayingLabel.textColor = .white
        nowPlayingLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(nowPlayingLabel)

        playPauseButton.setTitle("Play", for: .normal)
        playPauseButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(playPauseButton)

        nextButton.setTitle("Next", for: .normal)
        nextButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        nextButton.tintColor = .white
        nextButton.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(nextButton)

        NSLayoutConstraint.activate([
            playerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerBar.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            playerBar.heightAnchor.constraint(equalToConstant: 56),

            topBorder.topAnchor.constraint(equalTo: playerBar.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: playerBar.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: playerBar.trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),

            miniThumbView.leadingAnchor.constraint(equalTo: playerBar.leadingAnchor, constant: 12),
            miniThumbView.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            miniThumbView.widthAnchor.constraint(equalToConstant: 40),
            miniThumbView.heightAnchor.constraint(equalToConstant: 40),

            nextButton.trailingAnchor.constraint(equalTo: playerBar.trailingAnchor, constant: -10),
            nextButton.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 46),

            playPauseButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -4),
            playPauseButton.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 52),

            nowPlayingLabel.leadingAnchor.constraint(equalTo: miniThumbView.trailingAnchor, constant: 10),
            nowPlayingLabel.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            nowPlayingLabel.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -6)
        ])
    }

    @objc private func didTapPlayPause() {
        AudioPlayerManager.shared.togglePlayPause()
    }

    @objc private func didTapNext() {
        AudioPlayerManager.shared.playNext()
    }
}