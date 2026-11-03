import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Little Wallet has learned about what someone likes to ask. Kept on the phone.
@MainActor
final class AskMemory: ObservableObject {
    static let shared = AskMemory()

    /// How often each topic was asked ("compare", "category:dining", "shop:trader joe's").
    @Published private(set) var interest: [String: Int] = [:]
    /// The last questions asked, newest first.
    @Published private(set) var recent: [String] = []

    private let defaults: UserDefaults
    private let interestKey = "little-wallet-ask-interest-v1"
    private let recentKey = "little-wallet-ask-recent-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interest = defaults.dictionary(forKey: interestKey) as? [String: Int] ?? [:]
        recent = defaults.stringArray(forKey: recentKey) ?? []
    }

    func asked(_ text: String, topics: [String]) {
        for topic in topics { interest[topic, default: 0] += 1 }
        recent.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        recent.insert(text, at: 0)
        recent = Array(recent.prefix(12))
        defaults.set(interest, forKey: interestKey)
        defaults.set(recent, forKey: recentKey)
    }

    /// Topics asked most, for the model's picture of this person.
    var favorites: [String] { interest.sorted { $0.value > $1.value }.prefix(4).map(\.key) }
}

/// Picks questions worth asking from someone's real spending, nudged towards what they like to ask.
enum Suggester {
    static func questions(_ analyst: Analyst, memory: [String: Int], recent: [String], limit: Int = 10) -> [AskQuestion] {
        guard !analyst.payments.isEmpty else {
            return [AskQuestion(text: "How do I track Apple Pay?", symbol: "wave.3.right", intent: .total(.thisMonth, nil, nil))]
        }
        let now = analyst.now, cal = analyst.calendar
        let thisMonth = analyst.payments(in: .thisMonth)
        let lastMonth = analyst.payments(in: .lastMonth)
        let lastName = Period.monthName(Period.lastMonth.interval(now: now, calendar: cal).start)
        var candidates: [(AskQuestion, Double)] = []
        func add(_ text: String, _ symbol: String, _ intent: AskIntent, _ score: Double) {
            candidates.append((AskQuestion(text: text, symbol: symbol, intent: intent), score))
        }

        // Fall back to last month when this one has barely started.
        let main: Period = thisMonth.count >= 2 || lastMonth.isEmpty ? .thisMonth : .lastMonth
        let mainWords = main == .thisMonth ? "this month" : "in \(lastName)"
        add("How much did I spend \(mainWords)?", "dollarsign.circle.fill", .total(main, nil, nil), 5)
        if !lastMonth.isEmpty, main == .thisMonth { add("How much did I spend in \(lastName)?", "calendar", .total(.lastMonth, nil, nil), 4) }
        add("What was my most expensive purchase \(mainWords)?", "crown.fill", .biggest(main), 4.2)
        if Set(analyst.payments(in: main).map(\.category)).count >= 2 {
            add("Where did most of my money go \(mainWords)?", "chart.pie.fill", .categories(main), 4)
        }
        if !thisMonth.isEmpty, !lastMonth.isEmpty { add("Am I spending more than last month?", "arrow.left.arrow.right", .compare(.thisMonth, nil), 3.6) }
        if let mover = analyst.biggestMover(.thisMonth) {
            add("Why is \(mover.title.lowercased()) up this month?", "chart.line.uptrend.xyaxis", .compare(.thisMonth, mover), 4.4)
        }
        if let top = analyst.byCategory(main).first {
            add("How much on \(top.category.title.lowercased()) \(mainWords)?", "tag.fill", .total(main, top.category, nil), 3)
        }
        let shops = analyst.byMerchant(.allTime)
        if let regular = shops.max(by: { $0.count < $1.count }), regular.count >= 2 {
            add("How often do I go to \(regular.name)?", "repeat", .habit(regular.name), 3.2)
        }
        if let top = analyst.byMerchant(main).first { add("How much have I spent at \(top.name)?", "storefront.fill", .total(.allTime, nil, top.name), 2.4) }
        if analyst.balances.contains(where: { $0.owed > 0 }) { add("Who still owes me money?", "person.2.fill", .owed, 4.6) }
        if !analyst.payments(in: .thisWeek).isEmpty { add("How much did I spend this week?", "calendar.badge.clock", .total(.thisWeek, nil, nil), 2.6) }
        if !analyst.payments(in: Period(kind: .yesterday)).isEmpty { add("What did I buy yesterday?", "clock.arrow.circlepath", .day(Period(kind: .yesterday)), 2.2) }
        add("What's my daily average \(mainWords)?", "divide.circle.fill", .dailyAverage(main), 2)
        add("Where do I spend the most?", "mappin.and.ellipse", .merchants(main), 2.8)

        let recentSet = Set(recent.prefix(3).map { $0.lowercased() })
        var seen = Set<String>()
        return candidates
            .map { question, base -> (AskQuestion, Double) in
                let liked = question.intent.topics.reduce(0.0) { $0 + Double(memory[$1] ?? 0) }
                let justAsked = recentSet.contains(question.text.lowercased()) ? 3.0 : 0
                return (question, base + min(liked, 6) * 0.6 - justAsked)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
            .filter { seen.insert($0.text).inserted }
            .prefix(limit).map { $0 }
    }
}

/// Reads a typed or spoken question with plain rules, for when the language model isn't there.
enum AskRouter {
    static func intent(for raw: String, analyst: Analyst) -> AskIntent? {
        let text = raw.lowercased()
        let period = Period.find(in: text, now: analyst.now, calendar: analyst.calendar) ?? .thisMonth
        let has = { (words: [String]) in words.contains { text.contains($0) } }
        let category = SpendCategory.allCases.first { has([$0.title.lowercased(), $0.rawValue]) }
            ?? (has(["food", "restaurant", "coffee", "dinner", "lunch"]) ? .dining : has(["gas", "ride", "uber", "lyft"]) ? .transport : nil)
        let shop = analyst.byMerchant(.allTime).map(\.name).first { text.contains($0.lowercased()) }

        if has(["owe", "pay me back", "paid me", "settle"]) { return .owed }
        if has(["how often", "how many times", "visits"]), let shop { return .habit(shop) }
        if has(["most expensive", "biggest", "largest", "priciest", "top purchase"]) { return .biggest(period) }
        if has(["more than", "less than", "compare", " vs", "versus", "up from", "down from", "why is"]) { return .compare(period, category) }
        if has(["where did", "which category", "categories", "breakdown", "go to", "most money"]) && shop == nil {
            return has(["store", "shop", "place", "where do"]) ? .merchants(period) : .categories(period)
        }
        if has(["where do i spend", "which store", "which shop", "top store", "top shop"]) { return .merchants(period) }
        if has(["average", "per day", "a day", "daily"]) { return .dailyAverage(period) }
        if has(["what did i buy", "what did i get", "purchases"]) { return .day(Period.find(in: text) ?? Period(kind: .today)) }
        if has(["how much", "spent", "spend", "total", "cost"]) { return .total(period, shop == nil ? category : nil, shop) }
        return nil
    }
}

/// Answers questions about spending on the phone: suggested questions exactly, typed or spoken ones with Apple's
/// on-device model calling exact spending tools, and with plain rules when the model isn't available.
enum AskAgent {
    enum Engine: Equatable { case exact, appleIntelligence, rules }
    static let log = Logger(subsystem: "com.jiawenzhu.littlewallet", category: "ask")

    static func answer(_ question: String, analyst: Analyst, profile: [String]) async -> (Insight, Engine) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let reply = await LocalAnalyst.answer(question, analyst: analyst, profile: profile) {
            return (reply, .appleIntelligence)
        }
        #endif
        if let intent = AskRouter.intent(for: question, analyst: analyst) { return (analyst.answer(intent), .rules) }
        return (Insight(text: "I can answer questions about your payments: totals, categories, shops, your biggest purchases, and who owes you. Try one of these.",
                        followUps: Suggester.questions(analyst, memory: [:], recent: [], limit: 4)), .rules)
    }

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return LocalAnalyst.available }
        #endif
        return false
    }
}

#if canImport(FoundationModels)
/// Collects what the tools found, so the answer can show the exact rows under the model's words.
@available(iOS 26.0, *)
private final class ToolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [Insight] = []
    func add(_ insight: Insight) { lock.lock(); found.append(insight); lock.unlock() }
    var last: Insight? { lock.lock(); defer { lock.unlock() }; return found.last }
}

@available(iOS 26.0, *)
private enum LocalAnalyst {
    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Generable
    struct Question {
        @Guide(description: "What the question is about: total, biggest, categories, shops, compare, habit, average, day or owed.")
        var kind: String
        @Guide(description: "The time it's about, like \"this month\", \"last month\", \"this week\", \"today\", \"yesterday\", \"this year\", \"all time\" or a month name. \"this month\" when not said.")
        var period: String
        @Guide(description: "A spending category if one was asked about: groceries, dining, transport, shopping, bills, fun, health or other. Empty otherwise.")
        var category: String
        @Guide(description: "A shop's name if one was asked about. Empty otherwise.")
        var shop: String
    }

    struct SpendingTool: Tool {
        let analyst: Analyst
        let log: ToolLog
        let name = "lookUpSpending"
        let description = "Looks up exact numbers from the person's payments. Always use it before answering; never estimate."

        typealias Arguments = Question

        func call(arguments: Question) async throws -> String {
            let intent = Self.intent(arguments, analyst: analyst)
            let insight = analyst.answer(intent)
            log.add(insight)
            let rows = insight.rows.map { "\($0.title)\($0.detail.isEmpty ? "" : " (\($0.detail))"): \($0.value)" }.joined(separator: "; ")
            return insight.text + (rows.isEmpty ? "" : " Details: \(rows).")
        }

        static func intent(_ q: Question, analyst: Analyst) -> AskIntent {
            let period = Period.find(in: q.period, now: analyst.now, calendar: analyst.calendar) ?? .thisMonth
            let category = SpendCategory.allCases.first { $0.rawValue == q.category.lowercased() || $0.title.lowercased() == q.category.lowercased() }
            let shop = q.shop.trimmingCharacters(in: .whitespaces).isEmpty ? nil : q.shop
            switch q.kind.lowercased() {
            case "biggest": return .biggest(period)
            case "categories": return .categories(period)
            case "shops": return .merchants(period)
            case "compare": return .compare(period, category)
            case "habit": return shop.map(AskIntent.habit) ?? .merchants(period)
            case "average": return .dailyAverage(period)
            case "day": return .day(period)
            case "owed": return .owed
            default: return .total(period, category, shop)
            }
        }
    }

    static func answer(_ question: String, analyst: Analyst, profile: [String]) async -> Insight? {
        guard available else { return nil }
        let log = ToolLog()
        let known = profile.isEmpty ? "" : " What you know about them: \(profile.joined(separator: "; "))."
        let session = LanguageModelSession(tools: [SpendingTool(analyst: analyst, log: log)], instructions: """
            You are Penny, the friendly helper at the front desk of Little Wallet, a spending tracker. Talk like a \
            kind, cheerful receptionist: natural, warm and brief, one or two short sentences, first person. Never \
            say you are an AI, a model or an assistant. Answer questions about the person's own payments using \
            only numbers from the lookUpSpending tool. If a question isn't about their money, say kindly what you \
            can help with.\(known) Today is \
            \(analyst.now.formatted(date: .complete, time: .omitted)).
            """)
        do {
            let reply = try await session.respond(to: question).content
            var insight = log.last ?? Insight(text: reply)
            insight.text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return insight
        } catch {
            AskAgent.log.error("On-device model couldn't answer: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
