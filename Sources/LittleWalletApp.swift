import SwiftUI

@main
struct LittleWalletApp: App {
    @StateObject private var store = WalletStore.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            HomeView(store: store)
                .onOpenURL { url in _ = store.handleIncomingURL(url) }
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}

#if DEBUG
extension WalletStore {
    /// Screenshots and design checks only (`-demo-wallet`): a believable month, never saved over real data.
    static func demo() -> WalletStore {
        let name = "little-wallet-demo"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = WalletStore(defaults: defaults)
        let now = Date.now
        func at(_ daysAgo: Int, _ hour: Int) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            return Calendar.current.date(bySettingHour: hour, minute: 12, second: 0, of: day)!
        }
        let rows: [(String, Double, Int, Int, String, PaymentSource, [LineItem])] = [
            ("Trader Joe's", 21.65, 0, 10, "Apple Card", .tap, [LineItem(name: "Strawberries", quantity: 2, price: 10.83),
                                                                 LineItem(name: "Greek yogurt", price: 5.49), LineItem(name: "Milk", price: 5.33)]),
            ("Uber", 18.40, 0, 8, "Apple Card", .tap, []),
            ("Blue Bottle Coffee", 6.75, 1, 9, "Debit", .tap, []),
            ("Chipotle", 13.00, 1, 13, "Apple Card", .voice, []),
            ("Netflix", 15.49, 2, 7, "Apple Card", .tap, []),
            ("Whole Foods Market", 38.40, 3, 18, "Debit", .tap, []),
            ("Shell", 42.10, 4, 17, "Apple Card", .tap, []),
            ("Target", 64.20, 5, 15, "Debit", .tap, []),
            ("CVS Pharmacy", 12.35, 6, 11, "Cash", .manual, []),
            ("Comcast", 79.99, 7, 9, "Debit", .manual, []),
            ("AMC Theatres", 31.50, 8, 20, "Apple Card", .tap, []),
            ("Costco", 112.80, 9, 16, "Apple Card", .tap, []),
            ("Sushi Ran", 86.00, 10, 19, "Apple Card", .voice, []),
        ]
        for row in rows {
            let saved = store.add(merchant: row.0, amount: row.1, date: at(row.2, row.3), card: row.4, source: row.5, items: row.6)
            // Receipt photos for screenshots, from `-scan-image <path>`.
            if ["Trader Joe's", "Costco", "Sushi Ran"].contains(row.0), let path = UserDefaults.standard.string(forKey: "demo-receipt"),
               let photo = UIImage(contentsOfFile: path) {
                store.attachReceipt(photo, to: saved.id)
            }
        }
        // A split with one friend still to pay, so Penny has someone to remind (`-demo-splits`).
        if ProcessInfo.processInfo.arguments.contains("-demo-splits") {
            let me = SplitPerson(id: "me", name: "Evan", colorIndex: 0, isMe: true)
            let sam = SplitPerson(id: "demo-sam", name: "Sam Lee", colorIndex: 1)
            let jing = SplitPerson(id: "demo-jing", name: "Jing Allen", colorIndex: 2)
            SplitService.shared.adopt(SentSplit(id: "demo-tj", title: "Trader Joe's run", method: "PayPal", createdAt: at(1, 18), total: "21.65",
                                                itemIDs: [], people: [me, sam, jing], shares: [
                                                    "demo-sam": SplitShare(name: "Sam Lee", total: "7.22", status: "opened", paidVia: nil, link: ""),
                                                    "demo-jing": SplitShare(name: "Jing Allen", total: "7.21", status: "sent", paidVia: nil, link: ""),
                                                ]))
        }
        return store
    }
}
#endif
