import Foundation
import SwiftUI
import Combine

/// Someone a bill can be split with: you, people in your household, or friends you added before.
struct SplitPerson: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var colorIndex: Int
    var isMe = false
    /// Venmo username, phone number or email, when known. Lets "Request in Venmo" fill in who to ask.
    var venmo: String? = nil

    var color: Color { SplitPerson.palette[colorIndex % SplitPerson.palette.count] }
    var hex: String { SplitPerson.hexes[colorIndex % SplitPerson.hexes.count] }
    var initial: String { String(name.prefix(1)).uppercased() }

    /// Green is yours; every friend gets the next colour no one else has.
    static let hexes = ["#5E8B4A", "#E08A4F", "#4F7FB8", "#C9637A", "#9A6FC4", "#D1A23B", "#3E9C94", "#B5654A",
                        "#5A6FD6", "#E06C9F", "#7FA83A", "#2F8FC9", "#8C6A4F", "#D9574A"]
    static let palette = hexes.map { Color(hex: $0) }

    /// One colour each for the first friends; after that, two colours blended, so every avatar still looks different.
    var colors: [Color] { SplitPerson.colors(for: colorIndex) }
    var avatar: AnyShapeStyle { SplitPerson.fill(colors) }

    static func colors(for index: Int) -> [Color] {
        let count = palette.count, first = index % count
        guard index >= count else { return [palette[first]] }
        var second = (first + 1 + 3 * (index / count)) % count
        if second == first { second = (second + 1) % count }
        return [palette[first], palette[second]]
    }

    static func fill(_ colors: [Color]) -> AnyShapeStyle {
        colors.count > 1
            ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(colors.first ?? palette[0])
    }
}

/// One friend's part of a split, as the server reports it.
struct SplitShare: Codable, Equatable {
    var name: String
    var total: String
    /// "sent", "opened" or "paid".
    var status: String
    var paidVia: String?
    var link: String
}

/// A bill that was split and sent: kept on the phone so its status can be followed later.
struct SentSplit: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var method: String
    var createdAt: Date
    var total: String
    var itemIDs: [UUID]
    var people: [SplitPerson]
    var shares: [String: SplitShare]
    /// The food's emoji, for the Venmo note.
    var emojis: String? = nil

    var paidCount: Int { shares.values.filter { $0.status == "paid" }.count }
    var isSettled: Bool { !shares.isEmpty && paidCount == shares.count }
}

/// What a split item shows on the shelf: friends still owe you, or everyone has paid.
enum SplitMark: Equatable {
    case waiting, settled
}

/// Talks to the split server shared with Little Fridge, which makes each friend's PayPal / Venmo settle-up link.
/// Money goes straight to the person who paid; the server never holds it.
@MainActor
final class SplitService: ObservableObject {
    static let shared = SplitService()

    @Published private(set) var splits: [SentSplit] = []
    @Published private(set) var friends: [SplitPerson] = []

    private let splitsKey = "little-wallet-splits-v1"
    private let friendsKey = "little-wallet-split-friends-v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: splitsKey), let list = try? JSONDecoder().decode([SentSplit].self, from: data) { splits = list }
        if let data = defaults.data(forKey: friendsKey), let list = try? JSONDecoder().decode([SplitPerson].self, from: data) { friends = list }
        // Friends saved before colours were handed out one each may share one; give them their own.
        var used: Set<Int> = [0]
        var changed = false
        for index in friends.indices {
            if used.contains(friends[index].colorIndex) {
                friends[index].colorIndex = (1...).first { !used.contains($0) }!
                changed = true
            }
            used.insert(friends[index].colorIndex)
        }
        if changed { saveFriends() }
    }

    /// The first colour no friend has yet. Yours is 0.
    private var nextColor: Int {
        let used = Set(friends.map(\.colorIndex))
        return (1...).first { !used.contains($0) }!
    }

    /// The server in use. Override with `defaults write … split-server-url` or `-split-server-url <url>` for testing.
    var serverURL: URL {
        if let custom = defaults.string(forKey: "split-server-url"), let url = URL(string: custom) { return url }
        #if DEBUG
        #if targetEnvironment(simulator)
        return URL(string: "http://localhost:8787")!
        #else
        return URL(string: "http://Evans-MacBook-Pro.local:8787")!
        #endif
        #else
        return URL(string: "https://little-fridge-split.onrender.com")!
        #endif
    }

    /// Signs a request to the split server with this app's key, so only Little Wallet can use the PayPal account.
    nonisolated static func authorize(_ request: inout URLRequest) {
        if let key = Bundle.main.object(forInfoDictionaryKey: "SplitAppKey") as? String, !key.isEmpty, !key.hasPrefix("$(") {
            request.setValue(key, forHTTPHeaderField: "x-app-key")
        }
    }

    /// Splits that include any of these items, newest first.
    func splits(for itemIDs: [UUID]) -> [SentSplit] {
        let wanted = Set(itemIDs)
        return splits.filter { !wanted.isDisjoint(with: $0.itemIDs) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Whether these items were split, and whether everyone has paid. Nil when they never were.
    func mark(for itemIDs: [UUID]) -> SplitMark? {
        let found = splits(for: itemIDs)
        guard !found.isEmpty else { return nil }
        return found.allSatisfy(\.isSettled) ? .settled : .waiting
    }

    func rememberFriend(named raw: String, venmo: String? = nil) -> SplitPerson? {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return nil }
        let recipient = venmo.flatMap(Venmo.recipient)
        if let index = friends.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if let recipient, friends[index].venmo == nil {
                friends[index].venmo = recipient
                saveFriends()
            }
            return friends[index]
        }
        let person = SplitPerson(id: "f" + UUID().uuidString.prefix(8).lowercased(), name: name, colorIndex: nextColor, venmo: recipient)
        friends.append(person)
        saveFriends()
        return person
    }

    /// Saves a friend's Venmo username, phone or email. Returns false when Venmo wouldn't understand it.
    @discardableResult
    func setVenmo(_ raw: String, for id: String) -> Bool {
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { friends[index].venmo = nil; saveFriends(); return true }
        guard let recipient = Venmo.recipient(trimmed) else { return false }
        friends[index].venmo = recipient
        saveFriends()
        return true
    }

    func forget(_ person: SplitPerson) {
        friends.removeAll { $0.id == person.id }
        saveFriends()
    }

    struct Line {
        let item: LineItem
        let price: Double
        let people: [String]
        /// Shown on the friend's page beside the line.
        let emoji: String
    }

    /// Sends the split to the server and keeps it. Throws a message fit to show the person.
    func send(title: String, method: String, paidAt: Date, me: SplitPerson, people: [SplitPerson], lines: [Line]) async throws -> SentSplit {
        let id = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        let body: [String: Any] = [
            "id": id,
            "app": "wallet",
            "title": title,
            "paidWith": method,
            "paidAt": ISO8601DateFormatter().string(from: paidAt),
            "organizer": ["id": me.id, "venmo": me.venmo ?? ""],
            "people": Dictionary(uniqueKeysWithValues: people.map { ($0.id, ["name": $0.name, "color": $0.hex]) }),
            "lines": lines.map { line in
                ["id": line.item.id.uuidString, "name": line.item.name, "price": String(format: "%.2f", line.price),
                 "people": line.people, "emoji": line.emoji]
            },
        ]
        let view: ServerSplit = try await request("POST", "/api/splits", body: body)
        let sent = SentSplit(id: id, title: title, method: method, createdAt: .now, total: view.total,
                             itemIDs: lines.map(\.item.id), people: people, shares: view.shares,
                             emojis: String(lines.map(\.emoji).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(4).joined()))
        splits.append(sent)
        saveSplits()
        return sent
    }

    /// The friend's page shows an emoji for each line: the thing's own when it's a common one, else the category's.
    static func emoji(for name: String, category: SpendCategory) -> String {
        let name = name.lowercased()
        let known: [(String, String)] = [
            ("pudding", "🍮"), ("chow fun", "🍜"), ("noodle", "🍜"), ("ramen", "🍜"), ("pho ", "🍜"), ("dumpling", "🥟"),
            ("strawberr", "🍓"), ("blueberr", "🫐"), ("banana", "🍌"), ("grape", "🍇"), ("lemon", "🍋"), ("orange", "🍊"),
            ("avocado", "🥑"), ("tomato", "🍅"), ("carrot", "🥕"), ("broccoli", "🥦"), ("lettuce", "🥬"), ("spinach", "🥬"),
            ("pepper", "🫑"), ("corn", "🌽"), ("potato", "🥔"), ("mushroom", "🍄"), ("cheese", "🧀"), ("butter", "🧈"),
            ("yogurt", "🥣"), ("milk", "🥛"), ("egg", "🥚"), ("bread", "🍞"), ("sourdough", "🍞"), ("baguette", "🥖"),
            ("croissant", "🥐"), ("salmon", "🐟"), ("fish", "🐟"), ("shrimp", "🍤"), ("chicken", "🍗"), ("bacon", "🥓"),
            ("steak", "🥩"), ("beef", "🥩"), ("pizza", "🍕"), ("dumpling", "🥟"), ("ice cream", "🍨"), ("juice", "🧃"),
            ("coffee", "☕️"), ("tea", "🍵"), ("cola", "🥤"), ("soda", "🥤"), ("water", "💧"), ("apple", "🍎"),
        ]
        return known.first { name.contains($0.0) }?.1 ?? category.emoji
    }

    /// Asks the server who has opened or paid.
    @discardableResult
    func refresh(_ id: String) async -> SentSplit? {
        // Venmo splits live only on this phone; there's nothing to ask the server.
        if id.hasPrefix(Self.venmoPrefix) { return splits.first { $0.id == id } }
        guard let index = splits.firstIndex(where: { $0.id == id }),
              let view: ServerSplit = try? await request("GET", "/api/splits/\(id)") else { return splits.first { $0.id == id } }
        let merged = Self.merge(local: splits[index].shares, server: view.shares)
        if splits[index].shares != merged {
            splits[index].shares = merged
            saveSplits()
        }
        return splits[index]
    }

    /// The server's view, except that a share marked paid on this phone (Apple Cash, a free Venmo request)
    /// stays paid: the server never hears about those payments.
    static func merge(local: [String: SplitShare], server: [String: SplitShare]) -> [String: SplitShare] {
        var result = server
        for (person, share) in local where share.isPaid && result[person]?.isPaid != true {
            result[person] = share
        }
        return result
    }

    /// Marks a share paid by hand (for example after a free Venmo request outside the app).
    func markPaidByHand(split id: String, person: String, via: String = "marked by you") {
        guard let index = splits.firstIndex(where: { $0.id == id }) else { return }
        splits[index].shares[person]?.status = "paid"
        splits[index].shares[person]?.paidVia = via
        saveSplits()
    }

    static let venmoPrefix = "v-"

    /// A split asked for in Venmo instead of with links. Venmo doesn't tell other apps about payments, so it lives
    /// only on this phone and you mark each friend paid when their Venmo payment arrives.
    @discardableResult
    func recordVenmo(title: String, method: String, people: [SplitPerson], itemIDs: [UUID], emojis: String,
                     totals: [String: Int]) -> SentSplit {
        let id = Self.venmoPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(14).lowercased()
        var shares: [String: SplitShare] = [:]
        for person in people where !person.isMe {
            let cents = totals[person.id] ?? 0
            guard cents > 0 else { continue }
            shares[person.id] = SplitShare(name: person.name, total: String(format: "%d.%02d", cents / 100, cents % 100),
                                           status: "sent", paidVia: nil, link: "")
        }
        let total = totals.values.reduce(0, +)
        let split = SentSplit(id: id, title: title, method: method, createdAt: .now,
                              total: String(format: "%d.%02d", total / 100, total % 100), itemIDs: itemIDs,
                              people: people, shares: shares, emojis: emojis)
        splits.append(split)
        saveSplits()
        return split
    }

    /// You opened Venmo with this friend's request.
    func markRequested(split id: String, person: String) {
        guard let index = splits.firstIndex(where: { $0.id == id }), splits[index].shares[person]?.status == "sent" else { return }
        splits[index].shares[person]?.status = "requested"
        saveSplits()
    }

    /// Keeps a split that was made elsewhere (tests, or a restored backup).
    func adopt(_ split: SentSplit) {
        splits.removeAll { $0.id == split.id }
        splits.append(split)
        saveSplits()
    }

    func delete(_ id: String) {
        splits.removeAll { $0.id == id }
        saveSplits()
    }

    // MARK: - Network

    private struct ServerSplit: Decodable {
        let id: String
        let total: String
        let shares: [String: SplitShare]
    }

    private struct ServerError: Decodable { let error: String }

    private func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: serverURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 25
        Self.authorize(&request)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SplitError(message: "Couldn't reach the payment server. Check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw SplitError(message: message ?? "Something went wrong (\(status)). Please try again.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func saveSplits() {
        if let data = try? JSONEncoder().encode(splits) { defaults.set(data, forKey: splitsKey) }
    }

    private func saveFriends() {
        if let data = try? JSONEncoder().encode(friends) { defaults.set(data, forKey: friendsKey) }
    }
}

struct SplitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SplitService {
    /// The payments with `paidBack` filled in: every share a friend has actually paid, on the payment it splits.
    func netted(_ payments: [Payment]) -> [Payment] {
        var owner: [UUID: UUID] = [:]
        for tx in payments { for line in tx.splitIDs { owner[line] = tx.id } }
        var back: [UUID: Int] = [:]
        for split in splits {
            guard let tx = split.itemIDs.lazy.compactMap({ owner[$0] }).first else { continue }
            let paid = split.shares.values.filter { $0.status == "paid" }
                .reduce(0) { $0 + Int(((Double($1.total) ?? 0) * 100).rounded()) }
            back[tx, default: 0] += paid
        }
        guard !back.isEmpty else { return payments }
        return payments.map { tx in
            var tx = tx
            if let cents = back[tx.id], cents > 0 { tx.paidBack = min(tx.amount, Double(cents) / 100) }
            return tx
        }
    }
}

/// Splits `total` cents by `weights` so the parts always add up exactly (largest remainders), like the server.
enum SplitMath {
    static func spread(_ total: Int, weights: [Int]) -> [Int] {
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.indices.map { $0 == 0 ? total : 0 } }
        let exact = weights.map { Double(total) * Double($0) / Double(sum) }
        var parts = exact.map { Int($0.rounded(.down)) }
        var left = total - parts.reduce(0, +)
        let order = exact.indices.sorted { a, b in
            let fa = exact[a] - exact[a].rounded(.down), fb = exact[b] - exact[b].rounded(.down)
            return fa != fb ? fa > fb : a < b
        }
        for i in order where left > 0 {
            parts[i] += 1
            left -= 1
        }
        return parts
    }

    /// Each person's total in cents, given each line's price and who shares it.
    static func totals(lines: [(cents: Int, people: [String])], people: [String]) -> [String: Int] {
        var result = Dictionary(uniqueKeysWithValues: people.map { ($0, 0) })
        for line in lines where !line.people.isEmpty {
            for (person, part) in zip(line.people, spread(line.cents, weights: line.people.map { _ in 1 })) {
                result[person, default: 0] += part
            }
        }
        return result
    }
}

extension Color {
    /// "#RRGGBB"
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
