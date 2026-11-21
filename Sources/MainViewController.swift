import UIKit

// MARK: - Cell Grid 2 Kolom untuk Halaman Awal / Pencarian
class SongGridCollectionViewCell: UICollectionViewCell {
    let thumbImageView = UIImageView()
    let titleLabel = UILabel()
    let artistLabel = UILabel()
    var currentVideoId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true

        thumbImageView.contentMode = .scaleAspectFill
        thumbImageView.clipsToBounds = true
        thumbImageView.backgroundColor = UIColor(white: 0.18, alpha: 1.0)
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbImageView)

        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        artistLabel.textColor = .lightGray
        artistLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        artistLabel.numberOfLines = 1
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(artistLabel)

        NSLayoutConstraint.activate([
            thumbImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbImageView.heightAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.72),

            titleLabel.topAnchor.constraint(equalTo: thumbImageView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            artistLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Cell Baris untuk Halaman Antrean (Menampilkan Artis & Durasi)
class SongTableViewCell: UITableViewCell {
    let thumbImageView = UIImageView()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
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

        subtitleLabel.textColor = .lightGray
        subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            thumbImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            thumbImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbImageView.widthAnchor.constraint(equalToConstant: 48),
            thumbImageView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: thumbImageView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: thumbImageView.topAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: thumbImageView.bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Tab 1: Streaming (Grid 2 Kolom di Halaman Awal, Baris Bersih di Antrean)
class StreamingViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private var collectionView: UICollectionView!
    private let tableView = UITableView()
    private let gridRefreshControl = UIRefreshControl()

    private var browseSongs: [SongItem] = []
    private var queueSongs: [SongItem] = []
    private var isShowingRadioQueue = false
    private var lastQuery = "Lagu Pop Indonesia Hits"

    private let homeFeedQueries = [
        "Lagu Pop Indonesia Hits",
        "Musik Viral Indonesia Terbaru",
        "Top Indo Acoustic Chill",
        "Lagu Galau Indonesia Terbaik",
        "Indonesian Indie Hits",
        "Pop Barat Hits Terbaru"
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Streaming"
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupUI()

        AudioPlayerManager.shared.onQueueUpdated = { [weak self] updatedQueue in
            guard let self = self else { return }
            self.queueSongs = updatedQueue
            self.switchToQueueMode(true)
        }

        AudioPlayerManager.shared.onOpenQueueRequested = { [weak self] currentQueue in
            guard let self = self else { return }
            self.queueSongs = currentQueue
            self.switchToQueueMode(true)
        }

        performSearch(query: lastQuery, isRefresh: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshActiveList()
    }

    private func setupUI() {
        searchBar.delegate = self
        searchBar.placeholder = "Cari lagu atau artis..."
        searchBar.barStyle = .black
        searchBar.isTranslucent = false
        searchBar.barTintColor = UIColor(white: 0.10, alpha: 1.0)
        searchBar.tintColor = .white
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        // 1. Setup Grid 2 Kolom (Halaman Awal & Pencarian)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 10, left: 12, bottom: 70, right: 12)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(SongGridCollectionViewCell.self, forCellWithReuseIdentifier: "GridCell")
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        gridRefreshControl.tintColor = .white
        gridRefreshControl.addTarget(self, action: #selector(didPullToRefresh), for: .valueChanged)
        collectionView.refreshControl = gridRefreshControl
        view.addSubview(collectionView)

        // 2. Setup Baris List (Halaman Antrean Radio — tanpa searchBar & tanpa banner, diberi jarak atas 10pt)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SongTableViewCell.self, forCellReuseIdentifier: "SongCell")
        tableView.rowHeight = 64
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.18, alpha: 1.0)
        tableView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 64, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset
        tableView.keyboardDismissMode = .onDrag
        tableView.isHidden = true
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: guide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            collectionView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            tableView.topAnchor.constraint(equalTo: guide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])
    }

    private func switchToQueueMode(_ enabled: Bool) {
        isShowingRadioQueue = enabled
        updateBackButtonVisibility()
        if enabled {
            title = "Antrean"
            searchBar.isHidden = true
            searchBar.resignFirstResponder()
            collectionView.isHidden = true
            tableView.isHidden = false
            tableView.reloadData()
        } else {
            title = "Streaming"
            searchBar.isHidden = false
            tableView.isHidden = true
            collectionView.isHidden = false
            collectionView.reloadData()
        }
    }

    private func makeBackChevronIcon(size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2.4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: size.width * 0.65, y: size.height * 0.20))
        ctx.addLine(to: CGPoint(x: size.width * 0.28, y: size.height * 0.50))
        ctx.addLine(to: CGPoint(x: size.width * 0.65, y: size.height * 0.80))
        ctx.strokePath()
        let img = UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysTemplate)
        UIGraphicsEndImageContext()
        return img
    }

    private func updateBackButtonVisibility() {
        if isShowingRadioQueue {
            let backIcon = makeBackChevronIcon(size: CGSize(width: 22, height: 22))
            let backBtn = UIBarButtonItem(image: backIcon, style: .plain, target: self, action: #selector(didTapExitQueue))
            backBtn.tintColor = .white
            navigationItem.leftBarButtonItem = backBtn
        } else {
            navigationItem.leftBarButtonItem = nil
        }
    }

    @objc private func didTapExitQueue() {
        searchBar.resignFirstResponder()
        if !browseSongs.isEmpty {
            switchToQueueMode(false)
        } else {
            performSearch(query: lastQuery, isRefresh: false)
        }
    }

    @objc private func didPullToRefresh() {
        if let typedText = searchBar.text, !typedText.trimmingCharacters(in: .whitespaces).isEmpty {
            performSearch(query: typedText, isRefresh: true)
        } else {
            let candidates = homeFeedQueries.filter { $0 != lastQuery }
            let nextFeedQuery = candidates.randomElement() ?? "Lagu Pop Indonesia Hits"
            performSearch(query: nextFeedQuery, isRefresh: true)
        }
    }

    private func performSearch(query: String, isRefresh: Bool) {
        lastQuery = query
        switchToQueueMode(false)

        InnerTubeService.shared.searchSongs(query: query) { [weak self] results, _ in
            guard let self = self else { return }
            self.gridRefreshControl.endRefreshing()

            let finalResults = isRefresh ? results.shuffled() : results
            self.browseSongs = finalResults
            self.collectionView.reloadData()
        }
    }

    func refreshActiveList() {
        if isShowingRadioQueue {
            tableView.reloadData()
        } else {
            collectionView.reloadData()
        }
    }

    // MARK: - UISearchBarDelegate
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.resignFirstResponder()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.resignFirstResponder()
        guard let query = searchBar.text, !query.isEmpty else { return }
        performSearch(query: query, isRefresh: false)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if searchBar.isFirstResponder {
            searchBar.setShowsCancelButton(false, animated: true)
            searchBar.resignFirstResponder()
        }
    }

    // MARK: - UICollectionViewDataSource & FlowLayout (Grid 2 Kolom Halaman Awal)
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return browseSongs.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GridCell", for: indexPath) as! SongGridCollectionViewCell
        let song = browseSongs[indexPath.item]
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

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalHorizontalPadding: CGFloat = 12 + 12 + 10
        let cardWidth = floor((collectionView.bounds.width - totalHorizontalPadding) / 2.0)
        let cardHeight = floor(cardWidth * 0.72) + 56
        return CGSize(width: cardWidth, height: cardHeight)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.resignFirstResponder()
        let selectedSong = browseSongs[indexPath.item]
        AudioPlayerManager.shared.startRadioWithSong(selectedSong)
    }

    // MARK: - UITableViewDataSource & Delegate (Daftar Baris Antrean + Durasi)
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return queueSongs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SongCell", for: indexPath) as! SongTableViewCell
        let song = queueSongs[indexPath.row]
        cell.currentVideoId = song.videoId
        cell.titleLabel.text = song.title
        if song.duration.isEmpty {
            cell.subtitleLabel.text = song.artist
        } else {
            cell.subtitleLabel.text = "\(song.artist) • \(song.duration)"
        }
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
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.resignFirstResponder()
        AudioPlayerManager.shared.playFromQueue(songs: queueSongs, at: indexPath.row)
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

    private lazy var playIcon = makePlayIcon(size: CGSize(width: 20, height: 20))
    private lazy var pauseIcon = makePauseIcon(size: CGSize(width: 20, height: 20))
    private lazy var nextIcon = makeNextIcon(size: CGSize(width: 20, height: 20))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupTabs()
        setupGlobalMiniPlayer()

        AudioPlayerManager.shared.onStateChanged = { [weak self] isPlaying, title, artwork in
            guard let self = self else { return }
            self.nowPlayingLabel.text = title
            self.playPauseButton.setImage(isPlaying ? self.pauseIcon : self.playIcon, for: .normal)
            if let artwork = artwork {
                self.miniThumbView.image = artwork
            }
            self.streamingVC.refreshActiveList()
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

    private func makePlayIcon(size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.move(to: CGPoint(x: size.width * 0.25, y: size.height * 0.18))
        ctx.addLine(to: CGPoint(x: size.width * 0.82, y: size.height * 0.50))
        ctx.addLine(to: CGPoint(x: size.width * 0.25, y: size.height * 0.82))
        ctx.closePath()
        ctx.fillPath()
        let img = UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysTemplate)
        UIGraphicsEndImageContext()
        return img
    }

    private func makePauseIcon(size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        let barW = size.width * 0.20
        let barH = size.height * 0.64
        let y = size.height * 0.18
        ctx.fill(CGRect(x: size.width * 0.24, y: y, width: barW, height: barH))
        ctx.fill(CGRect(x: size.width * 0.56, y: y, width: barW, height: barH))
        let img = UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysTemplate)
        UIGraphicsEndImageContext()
        return img
    }

    private func makeNextIcon(size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.move(to: CGPoint(x: size.width * 0.18, y: size.height * 0.20))
        ctx.addLine(to: CGPoint(x: size.width * 0.68, y: size.height * 0.50))
        ctx.addLine(to: CGPoint(x: size.width * 0.18, y: size.height * 0.80))
        ctx.closePath()
        ctx.fillPath()
        ctx.fill(CGRect(x: size.width * 0.72, y: size.height * 0.20, width: size.width * 0.12, height: size.height * 0.60))
        let img = UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysTemplate)
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
        nowPlayingLabel.isUserInteractionEnabled = true
        nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
        let tapTitleGesture = UITapGestureRecognizer(target: self, action: #selector(didTapMiniPlayerTitle))
        nowPlayingLabel.addGestureRecognizer(tapTitleGesture)
        playerBar.addSubview(nowPlayingLabel)

        playPauseButton.setImage(playIcon, for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playerBar.addSubview(playPauseButton)

        nextButton.setImage(nextIcon, for: .normal)
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
            nextButton.widthAnchor.constraint(equalToConstant: 36),
            nextButton.heightAnchor.constraint(equalToConstant: 36),

            playPauseButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -6),
            playPauseButton.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 36),
            playPauseButton.heightAnchor.constraint(equalToConstant: 36),

            nowPlayingLabel.leadingAnchor.constraint(equalTo: miniThumbView.trailingAnchor, constant: 10),
            nowPlayingLabel.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            nowPlayingLabel.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -8)
        ])
    }

    @objc private func didTapMiniPlayerTitle() {
        selectedIndex = 0
        AudioPlayerManager.shared.reopenCurrentQueue()
    }

    @objc private func didTapPlayPause() {
        AudioPlayerManager.shared.togglePlayPause()
    }

    @objc private func didTapNext() {
        AudioPlayerManager.shared.playNext()
    }
}