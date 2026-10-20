import AppKit
import HolosDictation

/// Pairs sleep and login-session interruptions with their return notifications.
@MainActor
enum DictationSessionNotifications {
    static func observe(_ center: NotificationCenter,
                        onChange: @escaping @MainActor (DictationSessionPolicy.Interruption, Bool) -> Void)
        -> [NSObjectProtocol] {
        let events: [(Notification.Name, DictationSessionPolicy.Interruption, Bool)] = [
            (NSWorkspace.willSleepNotification, .sleep, true),
            (NSWorkspace.didWakeNotification, .sleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false),
        ]
        return events.map { name, reason, suspending in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // NotificationCenter delivers this observer on the main queue.
                MainActor.assumeIsolated { onChange(reason, suspending) }
            }
        }
    }
}
