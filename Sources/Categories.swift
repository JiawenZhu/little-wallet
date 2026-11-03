import SwiftUI
import Combine

/// What a payment was for. Eight come with the app; people add their own, rename them, give them an emoji or an
/// icon, reorder them, and remove any but Other. Saved as its id, so payments made before keep their category.
struct SpendCategory: Hashable, Identifiable, Codable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let groceries = SpendCategory(rawValue: "groceries")
    static let dining = SpendCategory(rawValue: "dining")
    static let transport = SpendCategory(rawValue: "transport")
    static let shopping = SpendCategory(rawValue: "shopping")
    static let bills = SpendCategory(rawValue: "bills")
    static let fun = SpendCategory(rawValue: "fun")
    static let health = SpendCategory(rawValue: "health")
    static let other = SpendCategory(rawValue: "other")

    /// The categories to choose from, in the order you set.
    static var allCases: [SpendCategory] { CategoryLibrary.snapshot.filter { !$0.hidden }.map(\.category) }

    var info: CategoryInfo {
        CategoryLibrary.snapshot.first { $0.id == rawValue }
            ?? CategoryInfo.builtIn.first { $0.id == rawValue }
            ?? CategoryInfo(id: rawValue, name: rawValue.capitalized, icon: .emoji("🏷️"), hex: "#8A8F86")
    }

    var title: String { info.name }
    /// Short enough for the chart's labels.
    var short: String { self == .dining && info.name == "Eating out" ? "Dining" : info.name }
    var color: Color { Color(hex: info.hex) }
    /// The chart's bar colour.
    var barColor: Color { info.barHex.map { Color(hex: $0) } ?? color }
    var isBuiltIn: Bool { CategoryInfo.builtIn.contains { $0.id == rawValue } }

    /// The app's own artwork, for the eight it comes with when they keep it.
    var asset: String? {
        if case .art(let name) = info.icon { return name }
        return nil
    }

    /// An emoji for places that need one character: split notes, Penny's answers.
    var emoji: String {
        switch info.icon {
        case .emoji(let emoji): return emoji
        case .art: return CategoryInfo.builtInEmoji[rawValue] ?? "🧾"
        case .symbol: return "🏷️"
        }
    }

    /// A first guess from the shop's name. Your own categories match when their name shows up in it.
    static func guess(merchant: String, items: [String] = []) -> SpendCategory {
        let text = ([merchant] + items).joined(separator: " ").lowercased()
        let visible = Set(allCases)
        for info in CategoryLibrary.snapshot where !info.hidden && !info.isBuiltIn {
            let words = ([info.name] + info.keywords).map { $0.lowercased() }.filter { $0.count >= 3 }
            if words.contains(where: { text.contains($0) }) { return info.category }
        }
        let rules: [(SpendCategory, [String])] = [
            (.groceries, ["trader joe", "whole foods", "costco", "safeway", "kroger", "aldi", "sprouts", "publix", "wegmans",
                          "h-e-b", "heb", "market", "grocery", "groceries", "instacart", "fresh", "supermarket"]),
            (.dining, ["cafe", "coffee", "starbucks", "restaurant", "burger", "pizza", "chipotle", "mcdonald", "taco", "sushi",
                       "bakery", "kitchen", "grill", "bar ", "doordash", "uber eats", "grubhub", "dinner", "lunch", "breakfast"]),
            (.transport, ["uber", "lyft", "shell", "chevron", "exxon", "gas", "fuel", "parking", "metro", "transit", "airline",
                          "delta", "united", "american air", "southwest", "toll"]),
            (.bills, ["at&t", "verizon", "t-mobile", "comcast", "xfinity", "electric", "water", "insurance", "rent", "internet"]),
            (.fun, ["netflix", "spotify", "cinema", "theater", "theatre", "amc", "steam", "playstation", "xbox", "ticket", "concert"]),
            (.health, ["cvs", "walgreens", "pharmacy", "clinic", "dental", "doctor", "gym", "fitness"]),
            (.shopping, ["amazon", "target", "walmart", "apple store", "best buy", "ikea", "nike", "zara", "uniqlo", "mall"]),
        ]
        let found = rules.first { _, words in words.contains { text.contains($0) } }?.0 ?? .other
        // A category you removed is never guessed.
        return visible.contains(found) ? found : .other
    }
}

/// How a category looks and what it's called.
struct CategoryInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    enum Icon: Codable, Equatable, Hashable, Sendable {
        /// One of the app's illustrations.
        case art(String)
        /// Any emoji from the iPhone keyboard.
        case emoji(String)
        /// An icon from the app's library (an SF Symbol name).
        case symbol(String)
    }

    var id: String
    var name: String
    var icon: Icon
    var hex: String
    var barHex: String? = nil
    var hidden = false
    /// Extra words that file a shop under this category, like "petco" for Pets.
    var keywords: [String] = []

    var category: SpendCategory { SpendCategory(rawValue: id) }
    var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    static let builtIn: [CategoryInfo] = [
        .init(id: "groceries", name: "Groceries", icon: .art("CatGroceries"), hex: "#5E8B4A", barHex: "#3F6953"),
        .init(id: "dining", name: "Eating out", icon: .art("CatDining"), hex: "#E08A4F", barHex: "#8DB592"),
        .init(id: "transport", name: "Transport", icon: .art("CatTransport"), hex: "#4F7FB8", barHex: "#A9CBA7"),
        .init(id: "shopping", name: "Shopping", icon: .art("CatShopping"), hex: "#C9637A", barHex: "#EE9A7B"),
        .init(id: "bills", name: "Bills", icon: .art("CatBills"), hex: "#D1A23B", barHex: "#EED77A"),
        .init(id: "fun", name: "Fun", icon: .art("CatFun"), hex: "#9A6FC4", barHex: "#7FAE86"),
        .init(id: "health", name: "Health", icon: .art("CatHealth"), hex: "#3E9C94", barHex: "#B5D3AF"),
        .init(id: "other", name: "Other", icon: .art("CatOther"), hex: "#8A8F86", barHex: "#6E9E78"),
    ]

    static let builtInEmoji = ["groceries": "🛒", "dining": "🍔", "transport": "🚗", "shopping": "🛍️",
                               "bills": "💡", "fun": "🎬", "health": "💊", "other": "🧾"]
}

/// Everyone's categories, kept on the phone. Views watch it; the rest of the app reads `snapshot`.
@MainActor
final class CategoryLibrary: ObservableObject {
    static let shared = CategoryLibrary()

    /// Read anywhere, from any thread. Changed only by the library on the main actor.
    nonisolated(unsafe) private(set) static var snapshot: [CategoryInfo] = CategoryInfo.builtIn

    @Published private(set) var all: [CategoryInfo] = CategoryInfo.builtIn {
        didSet { Self.snapshot = all; save() }
    }

    private let defaults: UserDefaults
    private let key = "little-wallet-categories-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([CategoryInfo].self, from: data), !saved.isEmpty {
            // A category the app adds later still shows up for people who saved theirs before.
            var merged = saved
            for builtIn in CategoryInfo.builtIn where !merged.contains(where: { $0.id == builtIn.id }) {
                merged.insert(builtIn, at: max(0, merged.count - 1))
            }
            all = merged
        }
        Self.snapshot = all
    }

    var visible: [CategoryInfo] { all.filter { !$0.hidden } }
    var removed: [CategoryInfo] { all.filter { $0.hidden } }

    /// Adds a category just before Other.
    @discardableResult
    func add(name: String, icon: CategoryInfo.Icon, hex: String) -> SpendCategory {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        let base = clean.lowercased().filter { $0.isLetter || $0.isNumber }
        var id = "c-" + (base.isEmpty ? "category" : base)
        while all.contains(where: { $0.id == id }) { id += "-\(Int.random(in: 10...99))" }
        let info = CategoryInfo(id: id, name: clean.isEmpty ? "New category" : clean, icon: icon, hex: hex)
        let other = all.firstIndex { $0.id == SpendCategory.other.rawValue } ?? all.count
        all.insert(info, at: other)
        return info.category
    }

    func update(_ info: CategoryInfo) {
        guard let index = all.firstIndex(where: { $0.id == info.id }) else { return }
        var changed = info
        changed.name = String(info.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if changed.name.isEmpty { changed.name = all[index].name }
        all[index] = changed
    }

    /// Takes a category off every list. Its payments move to Other; a built-in one can be brought back.
    func remove(_ category: SpendCategory, in store: WalletStore) {
        guard category != .other, let index = all.firstIndex(where: { $0.id == category.rawValue }) else { return }
        store.recategorize(from: category, to: .other)
        if all[index].isBuiltIn { all[index].hidden = true } else { all.remove(at: index) }
    }

    func restore(_ category: SpendCategory) {
        guard let index = all.firstIndex(where: { $0.id == category.rawValue }) else { return }
        all[index].hidden = false
    }

    func move(from source: IndexSet, to destination: Int) {
        var shown = visible
        shown.move(fromOffsets: source, toOffset: destination)
        all = shown + removed
    }

    /// The eight the app comes with, as they were. Your own categories stay.
    func resetBuiltIns() {
        let custom = all.filter { !$0.isBuiltIn }
        var list = CategoryInfo.builtIn
        list.insert(contentsOf: custom, at: list.count - 1)
        all = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }
}

/// A category's picture: the app's illustration, an emoji, or an icon on a coloured tile.
struct CategoryIcon: View {
    let category: SpendCategory
    var size: CGFloat = 44

    var body: some View { CategoryArt(icon: category.info.icon, hex: category.info.hex, size: size) }
}

struct CategoryArt: View {
    let icon: CategoryInfo.Icon
    let hex: String
    var size: CGFloat = 44

    var body: some View {
        switch icon {
        case .art(let name):
            Image(name).resizable().scaledToFit().frame(width: size, height: size)
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size * 0.74))
                .frame(width: size, height: size)
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.03)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 0.86, height: size * 0.86)
                .background(
                    LinearGradient(colors: [Color(hex: hex).opacity(0.85), Color(hex: hex)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                )
                .shadow(color: Color(hex: hex).opacity(0.35), radius: size * 0.08, y: size * 0.05)
                .frame(width: size, height: size)
        }
    }
}
