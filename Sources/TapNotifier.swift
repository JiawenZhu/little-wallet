import SwiftUI
import UIKit
import UserNotifications

/// Tells you a tap was saved — "$13.00 at Trader Joe's" — and opens that payment when you tap the notification.
enum TapNotifier {
    static func saved(_ payment: Payment) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        if payment.cents == 0 {
            content.title = "\(payment.merchant) — how much was it?"
            content.body = "Apple Pay didn't share the amount for this one. Tap to add it."
        } else {
            content.title = "\(payment.formattedAmount) at \(payment.merchant)"
            content.body = "Saved to Little Wallet\(payment.card.isEmpty ? "" : " · \(payment.card)"). Tap to add what you bought or split it."
        }
        content.sound = nil
        content.threadIdentifier = "taps"
        content.userInfo = ["payment": payment.id.uuidString]
        try? await center.add(UNNotificationRequest(identifier: "tap-\(payment.id.uuidString)", content: content, trigger: nil))
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])) ?? false
    }

    static var isAllowed: Bool {
        get async { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized }
    }
}

/// Shows tap banners while the app is open, and opens the payment a notification is about.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["payment"] as? String, let id = UUID(uuidString: raw) else { return }
        await MainActor.run { WalletStore.shared.openRequest = id }
    }
}
