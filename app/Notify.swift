// Finished / failed notifications for long jobs (Wabbajack lists, collections, updates) — only when SkyrimMT isn't
// the active app. Permission is asked when the first long job starts.
import AppKit
import UserNotifications

enum Notify {
    static func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String) {
        DispatchQueue.main.async {
            guard !NSApp.isActive else { return }
            let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
