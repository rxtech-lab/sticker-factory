import UIKit

extension Notification.Name {
    /// Posted on the main thread each time the phone is shaken. SwiftUI has no shake gesture, so
    /// the window, last in line for motion events, passes it on.
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
