import SwiftUI

@main
struct LittleWalletApp: App {
    @StateObject private var store = WalletStore.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            HomeView(store: store)
                .onOpenURL { url in _ = store.handleIncomingURL(url) }
                // Hear about payments live only while the app is open.
                .onChange(of: phase, initial: true) { _, now in
                    if now == .active { LiveUpdates.shared.start() } else if now == .background { LiveUpdates.shared.stop() }
                }
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
        if ProcessInfo.processInfo.arguments.contains("-demo-film") { filmData(at: at) }
        return store
    }

    /// The commercial's cast (`-demo-film`): Sam, Alex and Maya, with invented splits and sandbox-style PayPal activity.
    private static func filmData(at: (Int, Int) -> Date) {
        let me = SplitPerson(id: "me", name: "You", colorIndex: 0, isMe: true)
        let service = SplitService.shared
        let sam = service.rememberFriend(named: "Sam Lee", venmo: "sam@example.com") ?? me
        let alex = service.rememberFriend(named: "Alex Kim", venmo: "alex@example.com") ?? me
        let maya = service.rememberFriend(named: "Maya Chen", venmo: "maya@example.com") ?? me
        service.adopt(SentSplit(id: "demo-tj", title: "Trader Joe's run", method: "PayPal", createdAt: at(0, 9), total: "84.00", itemIDs: [],
                                people: [me, sam, alex], shares: [
                                    sam.id: SplitShare(name: sam.name, total: "28.00", status: "opened", paidVia: nil, link: ""),
                                    alex.id: SplitShare(name: alex.name, total: "28.00", status: "sent", paidVia: nil, link: ""),
                                ]))
        service.adopt(SentSplit(id: "demo-dinner", title: "Golden Dragon dinner", method: "PayPal", createdAt: at(2, 19), total: "61.92", itemIDs: [],
                                people: [me, alex, maya], shares: [
                                    alex.id: SplitShare(name: alex.name, total: "20.64", status: "sent", paidVia: nil, link: ""),
                                    maya.id: SplitShare(name: maya.name, total: "20.64", status: "paid", paidVia: "Venmo", link: ""),
                                ]))
        let iso = { (date: Date) in date.formatted(.iso8601) }
        PayPalLink.shared.preview([
            PayPalActivity(id: "FILM1", date: iso(at(1, 20)), kind: .received, amount: "28.00", fee: "1.11", via: "Venmo", name: "Sam Lee",
                           note: "Your share of Sunday brunch", items: [], split: nil),
            PayPalActivity(id: "FILM2", date: iso(at(2, 21)), kind: .received, amount: "20.64", fee: "0.90", via: "Venmo", name: "Maya Chen",
                           note: "Your share of Golden Dragon dinner", items: [], split: .init(id: "demo-dinner", person: maya.id)),
            PayPalActivity(id: "FILM3", date: iso(at(4, 12)), kind: .received, amount: "42.00", fee: "1.51", via: "PayPal", name: "Alex Kim",
                           note: "Concert tickets", items: [], split: nil),
            PayPalActivity(id: "FILM4", date: iso(at(6, 9)), kind: .transfer, amount: "60.00", fee: "0.00", via: "PayPal", items: []),
        ], balance: "212.48")
    }
}
#endif
