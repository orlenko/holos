import AppKit
import HolosDictation
import Testing
@testable import HolosApp

@MainActor
struct DictationSessionNotificationsTests {
    @Test func workspaceNotificationsRestoreThePriorToggleAfterBothInterruptionsEnd() {
        let center = NotificationCenter()
        var policy = DictationSessionPolicy()
        var enabled = true
        var restores = 0
        let observers = DictationSessionNotifications.observe(center) { reason, suspending in
            if suspending {
                policy.suspend(for: reason, wasEnabled: enabled)
                enabled = false
            } else if policy.resume(from: reason) {
                enabled = true
                restores += 1
            }
        }
        defer { for observer in observers { center.removeObserver(observer) } }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(!enabled)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!enabled)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(enabled && restores == 1)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(restores == 1)
        enabled = false
        policy.didDisable()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!enabled && restores == 1)
    }
}
