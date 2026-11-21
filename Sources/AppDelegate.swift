import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    override var canBecomeFirstResponder: Bool {
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        window?.rootViewController = RootTabBarController()
        window?.makeKeyAndVisible()

        application.beginReceivingRemoteControlEvents()
        self.becomeFirstResponder()
        return true
    }

    override func remoteControlReceived(with event: UIEvent?) {
        guard let event = event, event.type == .remoteControl else { return }
        switch event.subtype {
        case .remoteControlPlay:
            if !AudioPlayerManager.shared.isPlaying {
                AudioPlayerManager.shared.togglePlayPause()
            }
        case .remoteControlPause:
            if AudioPlayerManager.shared.isPlaying {
                AudioPlayerManager.shared.togglePlayPause()
            }
        case .remoteControlTogglePlayPause:
            AudioPlayerManager.shared.togglePlayPause()
        case .remoteControlNextTrack:
            AudioPlayerManager.shared.playNext()
        case .remoteControlPreviousTrack:
            AudioPlayerManager.shared.playPrevious()
        default:
            break
        }
    }
}