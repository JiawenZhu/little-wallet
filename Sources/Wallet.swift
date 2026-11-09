import Foundation
import SwiftUI
import Combine
import UIKit

/// Where a payment came from.
enum PaymentSource: String, Codable {
    case tap, manual, voice, receipt, financeKit, paypal

    var label: String {
        switch self {
        case .tap: return "Apple Pay"
        case .manual: return "Added by hand"
        case .voice: return "Voice"
        case .receipt: return "Receipt"
        case .financeKit: return "Apple Card"
        case .paypal: return "PayPal"
        }
    }
}

/// One thing on a receipt.
struct LineItem: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var quantity: Int = 1
    /// The whole line's price, when known.
    var price: Double?
}

/// One payment: anything bought, from any card, cash included.
struct Payment: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date = .now
    var merchant: String
    var amount: Double
    var currencySymbol = "$"
    /// The card's name as Wallet reports it ("Apple Card", "Chase Sapphire"), or "Cash".
    var card: String = ""
    var category: SpendCategory = .other
    var source: PaymentSource = .manual
    var items: [LineItem] = []
    var note: String?
    /// Money friends have paid back for this payment (from settled splits). Filled in for display, never saved.
    var paidBack: Double? = nil
    /// The payment's id where it came from, like a PayPal transaction id, so it's never imported twice.
    var externalID: String? = nil
    /// The repeating payment that added this one, like a monthly bill.
    var recurringID: UUID? = nil

    var cents: Int { Int((amount * 100).rounded()) }
    /// What it really cost you: the amount less what friends paid back.
    var spent: Double { max(0, amount - (paidBack ?? 0)) }
    var formattedAmount: String { String(format: "%@%.2f", currencySymbol, amount) }

    /// Every id a split of this payment may be filed under: its lines, or the whole payment split evenly.
    var splitIDs: [UUID] { splitLines.map(\.id) + [id] }

    /// What a split can share out: the items, each with a price, or the whole payment as one line.
    var splitLines: [LineItem] {
        guard !items.isEmpty else { return [LineItem(id: id, name: merchant, quantity: 1, price: amount)] }
        let known = items.compactMap(\.price).reduce(0, +)
        let unpriced = items.filter { $0.price == nil }.reduce(0) { $0 + max(1, $1.quantity) }
        let each = unpriced > 0 ? max(0, amount - known) / Double(unpriced) : 0
        return items.map { item in
            var line = item
            if line.price == nil { line.price = each * Double(max(1, item.quantity)) }
            return line
        }
    }
}

/// Every payment, kept on the phone.
@MainActor
final class WalletStore: ObservableObject {
    static let shared: WalletStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo-wallet") { return .demo() }
        #endif
        return WalletStore()
    }()

    @Published private(set) var transactions: [Payment] = []
    /// When the Apple Pay automation last delivered a tap: proof the setup works.
    @Published private(set) var lastTapAt: Date?
    /// A payment to open, from a tapped notification.
    @Published var openRequest: UUID?
    /// Bills and subscriptions that add themselves when they come due.
    @Published var recurring: [Recurring] = []

    private let key = "little-wallet-transactions-v1"
    private let tapKey = "little-wallet-last-tap-v1"
    private let recurringKey = "little-wallet-recurring-v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Payment].self, from: data) {
            transactions = saved
        }
        lastTapAt = defaults.object(forKey: tapKey) as? Date
        if let data = defaults.data(forKey: recurringKey), let saved = try? JSONDecoder().decode([Recurring].self, from: data) {
            recurring = saved
        }
    }

    func transaction(_ id: UUID) -> Payment? { transactions.first { $0.id == id } }

    /// Saves a payment, newest first. Categories are guessed when not given.
    @discardableResult
    func add(merchant: String, amount: Double, date: Date = .now, card: String = "", category: SpendCategory? = nil,
             source: PaymentSource, items: [LineItem] = [], note: String? = nil) -> Payment {
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if source == .tap {
            lastTapAt = .now
            defaults.set(lastTapAt, forKey: tapKey)
            // The automation can fire twice for one tap; the same shop and amount within two minutes is one payment.
            if let same = transactions.first(where: { $0.source == .tap && abs($0.date.timeIntervalSince(date)) < 120
                && $0.cents == Int((amount * 100).rounded()) && $0.merchant.caseInsensitiveCompare(name.isEmpty ? "Apple Pay" : name) == .orderedSame }) {
                return same
            }
        }
        let tx = Payment(date: date, merchant: name.isEmpty ? (source == .tap ? "Apple Pay" : "Payment") : name, amount: max(0, amount),
                             card: card.trimmingCharacters(in: .whitespacesAndNewlines),
                             category: category ?? .guess(merchant: name, items: items.map(\.name)),
                             source: source, items: items, note: note)
        transactions.append(tx)
        transactions.sort { $0.date > $1.date }
        save()
        return tx
    }

    /// Moves every payment in one category to another, when a category is removed.
    func recategorize(from old: SpendCategory, to new: SpendCategory) {
        var changed = false
        for index in transactions.indices where transactions[index].category == old {
            transactions[index].category = new
            changed = true
        }
        if changed { save() }
    }

    func count(in category: SpendCategory) -> Int { transactions.filter { $0.category == category }.count }

    /// Adds payments from PayPal that aren't here yet. Returns how many were new.
    @discardableResult
    func importPayments(_ incoming: [Payment]) -> Int {
        let known = Set(transactions.compactMap(\.externalID))
        let fresh = incoming.filter { $0.externalID.map { !known.contains($0) } ?? false }
        guard !fresh.isEmpty else { return 0 }
        transactions.append(contentsOf: fresh)
        transactions.sort { $0.date > $1.date }
        save()
        return fresh.count
    }

    func update(_ tx: Payment) {
        guard let index = transactions.firstIndex(where: { $0.id == tx.id }) else { return }
        transactions[index] = tx
        transactions.sort { $0.date > $1.date }
        save()
    }

    func delete(_ id: UUID) {
        transactions.removeAll { $0.id == id }
        ReceiptVault.remove(id)
        save()
    }

    /// Keeps a receipt photo with its payment. Its items fill in when the payment had none.
    func attachReceipt(_ image: UIImage, to id: UUID, items: [LineItem] = []) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
        ReceiptVault.save(image, for: id)
        if transactions[index].items.isEmpty { transactions[index].items = items }
        objectWillChange.send()
        save()
    }

    func removeReceipt(from id: UUID) {
        ReceiptVault.remove(id)
        objectWillChange.send()
    }

    /// The payment a scanned receipt is most likely for: the same amount, within three days, with no receipt yet.
    /// An Apple Pay tap usually arrives first; the paper receipt comes after.
    func match(cents: Int, date: Date?) -> Payment? {
        guard cents > 0 else { return nil }
        let when = date ?? .now
        return transactions
            .filter { abs($0.cents - cents) <= 1 && abs($0.date.timeIntervalSince(when)) < 3 * 86_400 && !ReceiptVault.has($0.id) && $0.source != .receipt }
            .min { abs($0.date.timeIntervalSince(when)) < abs($1.date.timeIntervalSince(when)) }
    }

    /// A line's own price, set while splitting. A payment with no items gets its amount changed instead.
    func setPrice(_ price: Double?, line id: UUID, in transactionID: UUID) {
        guard let index = transactions.firstIndex(where: { $0.id == transactionID }) else { return }
        if let item = transactions[index].items.firstIndex(where: { $0.id == id }) {
            transactions[index].items[item].price = price
        } else if id == transactionID, let price {
            transactions[index].amount = price
        }
        save()
    }

    /// Every card seen so far, most used first.
    var cards: [String] {
        let counts = Dictionary(grouping: transactions.map(\.card).filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// littlewallet://pay?merchant=Trader%20Joe%27s&amount=21.65&card=Apple%20Card
    func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme == "littlewallet", url.host == "pay",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        add(merchant: value("merchant") ?? "", amount: Self.amount(value("amount") ?? ""), card: value("card") ?? "", source: .tap)
        return true
    }

    /// Shortcuts may pass "$31.47", "$1,234.56", "31,47", "1.234,56" or "USD 31.47". The last "." or "," is the
    /// decimal mark only when one or two digits follow it; otherwise it separates thousands.
    nonisolated static func amount(_ raw: String) -> Double {
        let kept = raw.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard let mark = kept.lastIndex(where: { $0 == "." || $0 == "," }),
              case let decimals = kept.distance(from: mark, to: kept.endIndex) - 1, decimals >= 1, decimals <= 2 else {
            return Double(kept.filter(\.isNumber)) ?? 0
        }
        let whole = kept[..<mark].filter(\.isNumber)
        return Double((whole.isEmpty ? "0" : String(whole)) + "." + kept[kept.index(after: mark)...]) ?? 0
    }

    /// What the amount field shows while someone types: "1000000" becomes "1,000,000", one decimal point, at most
    /// two decimals, no leading zeros, and never more than $9,999,999.99.
    nonisolated static func typing(_ raw: String) -> String {
        var whole = "", fraction = "", sawPoint = false
        for character in raw where character.isNumber || character == "." {
            if character == "." { sawPoint = true; continue }
            if sawPoint { if fraction.count < 2 { fraction.append(character) } }
            else if whole.count < 7 { whole.append(character) }
        }
        whole = String(whole.drop { $0 == "0" })
        if whole.isEmpty && (sawPoint || raw.contains("0")) { whole = "0" }
        guard !whole.isEmpty else { return "" }
        let grouped = Int(whole).map { $0.formatted(.number.grouping(.automatic)) } ?? whole
        return grouped + (sawPoint ? "." + fraction : "")
    }

    /// One payment from a repeating bill, added without saving; `sortAndSave` follows.
    func appendRecurring(_ bill: Recurring, on date: Date) {
        transactions.append(Payment(date: date, merchant: bill.merchant, amount: bill.amount, card: bill.card,
                                    category: bill.category, source: .manual, note: bill.note, recurringID: bill.id))
    }

    func sortAndSave() {
        transactions.sort { $0.date > $1.date }
        save()
    }

    func saveRecurring() {
        if let data = try? JSONEncoder().encode(recurring) { defaults.set(data, forKey: recurringKey) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(transactions) { defaults.set(data, forKey: key) }
    }
}

enum Theme {
    static let background = Color(red: 0.97, green: 0.95, blue: 0.91)
    static let card = Color(red: 1, green: 0.995, blue: 0.98)
    static let ink = Color(red: 0.18, green: 0.22, blue: 0.19)
    static let secondary = Color(red: 0.43, green: 0.46, blue: 0.42)
    static let accent = Color(red: 0.25, green: 0.41, blue: 0.32)
    static let softGreen = Color(red: 0.88, green: 0.93, blue: 0.86)
    static let line = Color(red: 0.87, green: 0.86, blue: 0.81)
}

/// "$1,555,500.00": cents as dollars, with thousands separated.
func money(_ cents: Int) -> String {
    (cents < 0 ? "-$" : "$") + (abs(cents) / 100).formatted(.number.grouping(.automatic)) + String(format: ".%02d", abs(cents) % 100)
}
