import Foundation
import Combine

/// One question and Penny's answer, kept so the chat is still there next time.
struct PennyTurn: Identifiable, Equatable, Codable {
    var id = UUID()
    var question: String
    var answer: Insight?
    var date: Date = .now
}

/// Something Penny did in PayPal after you confirmed it.
struct PennyDone: Identifiable, Equatable, Codable {
    var id = UUID()
    var text: String
    var date: Date = .now
}

/// What the conversation is about right now, so "what about October?" and "remind them" mean something.
struct PennyContext: Equatable, Codable {
    enum Topic: String, Codable { case total, biggest, categories, shops, compare, habit, average, day, owed }

    /// The last action planned, so "make it $30" and "same for Alex" can build on it.
    struct Action: Equatable, Codable {
        var kind: String
        var names: [String]
        var cents: Int?
        var reason: String?
    }

    var topic: Topic?
    var period: Period?
    var category: SpendCategory?
    var shop: String?
    /// The people being talked about, by full name.
    var people: [String] = []
    var action: Action?
    var updated: Date?

    /// Keeps what an answer was about.
    mutating func absorb(_ intent: AskIntent, answer: Insight) {
        updated = .now
        switch intent {
        case let .total(p, c, s): topic = .total; period = p; category = c; shop = s
        case let .biggest(p): topic = .biggest; period = p
        case let .categories(p): topic = .categories; period = p; category = nil; shop = nil
        case let .merchants(p): topic = .shops; period = p; shop = nil
        case let .compare(p, c): topic = .compare; period = p; category = c
        case let .habit(s): topic = .habit; shop = s; category = nil
        case let .dailyAverage(p): topic = .average; period = p
        case let .day(p): topic = .day; period = p
        case .owed: topic = .owed; people = answer.rows.map(\.title)
        case let .owedBy(name): topic = .owed; people = [name]
        case .act: break
        }
    }

    /// A short line for the on-device model.
    var summary: String? {
        var parts: [String] = []
        if let period { parts.append("time: \(period.phrase())") }
        if let category { parts.append("category: \(category.title)") }
        if let shop { parts.append("shop: \(shop)") }
        if !people.isEmpty { parts.append("people: \(people.joined(separator: ", "))") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Reads a follow-up like "what about October?", "and dining?", "at Costco?" or "why?". Nil when the question
    /// stands on its own or nothing has been discussed yet.
    func followUp(_ raw: String, analyst: Analyst) -> AskIntent? {
        guard let topic else { return nil }
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let has = { (words: [String]) in words.contains { text.contains($0) } }
        let found = Period.find(in: text, now: analyst.now, calendar: analyst.calendar)
        let newCategory = SpendCategory.allCases.first { has([$0.title.lowercased(), $0.rawValue]) }
        let newShop = analyst.byMerchant(.allTime).map(\.name).first { text.contains($0.lowercased()) }
        let words = text.split(separator: " ").count
        let cue = text.range(of: #"^(what|how) about\b|^and\b|^also\b|^same\b|^only\b|^just\b|^then\b|\b(that|those|these|them|it|there|instead)\b"#, options: .regularExpression) != nil
        let bare = words <= 4 && (found != nil || newCategory != nil || newShop != nil)
        let why = text == "why" || text.hasPrefix("why is that") || text.hasPrefix("why so")
        let short = words <= 4 && has(["biggest", "most expensive", "how often", "more than", "less than", "compare", "average", "breakdown"])
        guard cue || bare || why || short else { return nil }

        let period = found ?? self.period ?? .thisMonth
        // Naming a shop or a category replaces the other; naming neither keeps both.
        let category = newShop != nil ? nil : newCategory ?? self.category
        let shop = newCategory != nil ? nil : newShop ?? self.shop

        if why || has(["compare", "more than", "less than", "versus", " vs"]) { return .compare(period, category) }
        if has(["biggest", "most expensive", "largest", "priciest"]) { return .biggest(period) }
        if has(["how often", "how many times"]), let shop { return .habit(shop) }
        if has(["average", "per day", "a day"]) { return .dailyAverage(period) }
        if has(["breakdown", "which category", "categories"]) { return .categories(period) }
        if has(["which store", "which shop", "where"]), shop == nil { return .merchants(period) }

        switch topic {
        case .total: return .total(period, category, shop)
        case .biggest: return .biggest(period)
        case .categories: return newCategory != nil ? .total(period, newCategory, nil) : .categories(period)
        case .shops: return newShop != nil ? .total(period, nil, newShop) : .merchants(period)
        case .compare: return .compare(period, category)
        case .habit: return shop.map { found != nil ? .total(period, nil, $0) : .habit($0) } ?? .total(period, category, nil)
        case .average: return .dailyAverage(period)
        case .day: return .day(period)
        case .owed: return found != nil || newCategory != nil || newShop != nil ? .total(period, category, shop) : nil
        }
    }
}

/// Penny's memory, kept on the phone: the chat, what it's about, what she's done, and what you asked her to remember.
@MainActor
final class PennyChat: ObservableObject {
    static let shared = PennyChat()

    @Published var turns: [PennyTurn] = []
    @Published var context = PennyContext()
    @Published private(set) var done: [PennyDone] = []
    @Published private(set) var facts: [String] = []

    private let defaults: UserDefaults
    private let key = "little-wallet-penny-memory-v1"

    private struct Saved: Codable {
        var turns: [PennyTurn]
        var context: PennyContext
        var done: [PennyDone]
        var facts: [String]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            turns = saved.turns.filter { $0.answer != nil }
            context = saved.context
            done = saved.done
            facts = saved.facts
        }
    }

    func save() {
        // A confirm card can't be picked up again later, so a saved chat keeps a note of it instead.
        let kept = turns.suffix(60).filter { $0.answer != nil }.map { turn -> PennyTurn in
            var turn = turn
            if let plan = turn.answer?.plan {
                turn.answer?.closedPlan = "\(plan.title) · \(money(plan.total))"
                turn.answer?.plan = nil
            }
            return turn
        }
        let saved = Saved(turns: Array(kept), context: context, done: Array(done.suffix(30)), facts: facts)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }

    /// Clears the chat and what it was about. What you asked her to remember stays.
    func startOver() {
        turns = []
        context = PennyContext()
        save()
    }

    func record(done text: String) {
        done.append(PennyDone(text: text))
        save()
    }

    func remember(_ fact: String) {
        guard !facts.contains(where: { $0.caseInsensitiveCompare(fact) == .orderedSame }) else { return }
        facts.append(fact)
        save()
    }

    /// Removes facts that mention these words. Returns how many went.
    @discardableResult
    func forget(_ words: String?) -> Int {
        guard let words else {
            let count = facts.count
            facts = []
            save()
            return count
        }
        let keep = facts.filter { !$0.lowercased().contains(words.lowercased()) }
        let gone = facts.count - keep.count
        facts = keep
        save()
        return gone
    }

    /// The last few exchanges, for the on-device model.
    var recentHistory: [String] {
        turns.suffix(6).compactMap { turn in
            guard let answer = turn.answer else { return nil }
            return "They asked: \(turn.question)\nYou said: \(answer.text.prefix(140))"
        }
    }

    /// "Remember that…", "forget…", "what do you remember?", "what did you send?". Nil for anything else.
    func command(_ raw: String) -> Insight? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.range(of: #"what do you (remember|know)|what have you remembered"#, options: .regularExpression) != nil {
            guard !facts.isEmpty else { return Insight(text: "Nothing yet. Say “remember that…” and I'll keep it.") }
            return Insight(text: "Here's what you've told me to remember.",
                           rows: facts.map { InsightRow(emoji: "📌", title: $0, value: "") })
        }
        if lower.range(of: #"^(please )?forget (everything|all of it|it all)\b"#, options: .regularExpression) != nil {
            let count = forget(nil)
            return Insight(text: count == 0 ? "There was nothing to forget." : "Done. I've forgotten all \(count == 1 ? "1 thing" : "\(count) things") you told me.")
        }
        if let match = lower.firstMatch(of: #/^(?:please )?forget (?:that |about |the )?(.+)$/#) {
            let words = String(match.1).trimmingCharacters(in: .punctuationCharacters)
            return Insight(text: forget(words) > 0 ? "Okay, I've forgotten that." : "I don't have anything about “\(words)”.")
        }
        if let match = text.firstMatch(of: #/^(?i:(?:please )?(?:remember|keep in mind|note)(?: that)?)[:,]?\s+(.+)$/#) {
            let fact = String(match.1).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            remember(fact)
            return Insight(text: "Got it. I'll remember that \(fact).")
        }
        if lower.range(of: #"what (did|have) you (send|sent|do|done)|did (that|it) (send|go through)|did you send"#, options: .regularExpression) != nil {
            guard !done.isEmpty else { return Insight(text: "I haven't sent anything yet. I only act after you tap confirm.") }
            return Insight(text: "Here's what I've sent for you.",
                           rows: done.suffix(5).reversed().map { InsightRow(emoji: "✅", title: $0.text, detail: $0.date.formatted(.dateTime.month(.abbreviated).day()), value: "") })
        }
        return nil
    }

    /// A remembered fact that shares a real word with the question.
    func recall(_ question: String) -> String? {
        let common: Set<String> = ["what", "when", "where", "which", "does", "have", "that", "this", "with", "about", "much", "many", "your", "from", "there"]
        let wanted = Set(question.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !common.contains($0) })
        return facts.first { fact in
            !wanted.isDisjoint(with: fact.lowercased().split { !$0.isLetter }.map(String.init))
        }
    }

    /// A welcome that picks up where you left off.
    var pickUp: String? {
        guard let last = turns.last, let topic = context.summary else { return nil }
        let gap = Date.now.timeIntervalSince(last.date)
        guard gap > 600 else { return nil }
        return "Welcome back! We were talking about \(topic.replacingOccurrences(of: "time: ", with: "").replacingOccurrences(of: "category: ", with: "").replacingOccurrences(of: "shop: ", with: "").replacingOccurrences(of: "people: ", with: "").replacingOccurrences(of: "; ", with: ", "))."
    }
}
