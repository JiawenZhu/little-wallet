import Foundation

/// A stretch of time a question is about: "this month", "last week", "October".
struct Period: Equatable, Hashable, Codable {
    enum Kind: String, Codable { case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, month, allTime }
    var kind: Kind
    /// For `.month`: which month (1...12) and year.
    var month = 0
    var year = 0

    static let thisMonth = Period(kind: .thisMonth)
    static let lastMonth = Period(kind: .lastMonth)
    static let thisWeek = Period(kind: .thisWeek)
    static let allTime = Period(kind: .allTime)

    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        func of(_ unit: Calendar.Component, _ date: Date) -> DateInterval { calendar.dateInterval(of: unit, for: date)! }
        func ago(_ unit: Calendar.Component, _ by: Int) -> Date { calendar.date(byAdding: unit, value: -by, to: now)! }
        switch kind {
        case .today: return of(.day, now)
        case .yesterday: return of(.day, ago(.day, 1))
        case .thisWeek: return of(.weekOfYear, now)
        case .lastWeek: return of(.weekOfYear, ago(.weekOfYear, 1))
        case .thisMonth: return of(.month, now)
        case .lastMonth: return of(.month, ago(.month, 1))
        case .thisYear: return of(.year, now)
        case .month: return of(.month, calendar.date(from: DateComponents(year: year, month: month, day: 1))!)
        case .allTime: return DateInterval(start: .distantPast, end: .distantFuture)
        }
    }

    /// How a sentence says it: "this month", "in October", "last week".
    func phrase(now: Date = .now, calendar: Calendar = .current) -> String {
        switch kind {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this week"
        case .lastWeek: return "last week"
        case .thisMonth: return "this month"
        case .lastMonth: return "in " + Self.monthName(interval(now: now, calendar: calendar).start)
        case .thisYear: return "this year"
        case .month: return "in " + Self.monthName(interval(now: now, calendar: calendar).start)
        case .allTime: return "so far"
        }
    }

    /// The period just before this one, for "more than last month?".
    func previous(now: Date = .now, calendar: Calendar = .current) -> Period {
        switch kind {
        case .thisMonth: return .lastMonth
        case .thisWeek: return Period(kind: .lastWeek)
        case .today: return Period(kind: .yesterday)
        default:
            let start = calendar.date(byAdding: .month, value: -1, to: interval(now: now, calendar: calendar).start)!
            let parts = calendar.dateComponents([.year, .month], from: start)
            return Period(kind: .month, month: parts.month!, year: parts.year!)
        }
    }

    static func monthName(_ date: Date) -> String { date.formatted(.dateTime.month(.wide)) }

    /// Reads a period out of a question; nil when none was said.
    static func find(in text: String, now: Date = .now, calendar: Calendar = .current) -> Period? {
        let text = text.lowercased()
        let table: [(String, Kind)] = [("yesterday", .yesterday), ("today", .today), ("last week", .lastWeek),
                                       ("past week", .lastWeek), ("this week", .thisWeek), ("last month", .lastMonth),
                                       ("past month", .lastMonth), ("this month", .thisMonth), ("this year", .thisYear),
                                       ("all time", .allTime), ("ever", .allTime), ("in total", .allTime)]
        if let hit = table.first(where: { text.contains($0.0) }) { return Period(kind: hit.1) }
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                      "november", "december"]
        for (index, name) in months.enumerated() where text.range(of: "\\b\(name)\\b", options: .regularExpression) != nil {
            let current = calendar.dateComponents([.year, .month], from: now)
            let year = index + 1 > current.month! ? current.year! - 1 : current.year!
            return Period(kind: .month, month: index + 1, year: year)
        }
        return nil
    }
}

/// What can be asked. Each one has an exact answer computed from the payments.
enum AskIntent: Equatable, Hashable, Codable {
    case total(Period, SpendCategory?, String?)
    case biggest(Period)
    case categories(Period)
    case merchants(Period)
    case compare(Period, SpendCategory?)
    case habit(String)
    case dailyAverage(Period)
    case day(Period)
    case owed
    /// Something for Penny to do in PayPal, like "Remind everyone who hasn't paid". Planned, then confirmed.
    case act(String)

    /// What it's about, for learning what someone cares about.
    var topics: [String] {
        switch self {
        case let .total(_, category, merchant):
            return ["total"] + (category.map { ["category:\($0.rawValue)"] } ?? []) + (merchant.map { ["shop:\($0.lowercased())"] } ?? [])
        case .biggest: return ["biggest"]
        case .categories: return ["categories"]
        case .merchants: return ["shops"]
        case let .compare(_, category): return ["compare"] + (category.map { ["category:\($0.rawValue)"] } ?? [])
        case let .habit(shop): return ["habit", "shop:\(shop.lowercased())"]
        case .dailyAverage: return ["average"]
        case .day: return ["day"]
        case .owed: return ["owed"]
        case .act: return ["act"]
        }
    }
}

/// A question shown as a chip.
struct AskQuestion: Identifiable, Hashable {
    var text: String
    var symbol: String
    var intent: AskIntent
    var id: String { text }
}

/// One line in an answer: a payment, a category, a shop or a person.
struct InsightRow: Identifiable, Equatable {
    var id = UUID()
    var image: String?
    var emoji: String?
    var title: String
    var detail: String = ""
    var value: String
    /// 0...1, drawn as a bar behind the row.
    var share: Double?
}

/// An answer: a headline number, a sentence, the lines behind it, and what to ask next.
struct Insight: Equatable {
    var headline: String?
    var text: String
    var rows: [InsightRow] = []
    var followUps: [AskQuestion] = []
    /// Something Penny offers to do in PayPal, shown as a card to check and confirm.
    var plan: PennyPlan? = nil
}

/// Exact answers about spending. The language model asks this; it never does the sums itself.
struct Analyst {
    var payments: [Payment]
    var balances: [SettleBalance] = []
    var now: Date = .now
    var calendar: Calendar = .current

    func payments(in period: Period, category: SpendCategory? = nil, merchant: String? = nil) -> [Payment] {
        let range = period.interval(now: now, calendar: calendar)
        return payments.filter { tx in
            range.contains(tx.date) && (category == nil || tx.category == category)
                && (merchant == nil || tx.merchant.localizedCaseInsensitiveContains(merchant!))
        }
    }

    func total(_ period: Period, category: SpendCategory? = nil, merchant: String? = nil) -> Double {
        payments(in: period, category: category, merchant: merchant).reduce(0) { $0 + $1.spent }
    }

    func byCategory(_ period: Period) -> [(category: SpendCategory, amount: Double)] {
        Dictionary(grouping: payments(in: period), by: \.category)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.spent }) }
            .sorted { $0.1 > $1.1 }
    }

    func byMerchant(_ period: Period) -> [(name: String, amount: Double, count: Int)] {
        Dictionary(grouping: payments(in: period), by: { $0.merchant })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.spent }, $0.value.count) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    func biggest(_ period: Period, limit: Int = 3) -> [Payment] {
        Array(payments(in: period).sorted { $0.spent > $1.spent }.prefix(limit))
    }

    /// Every payment ever made at a shop whose name contains `shop`.
    func visits(_ shop: String) -> [Payment] {
        payments.filter { $0.merchant.localizedCaseInsensitiveContains(shop) }.sorted { $0.date > $1.date }
    }

    /// Days that have passed in a period, at least 1.
    func days(in period: Period) -> Int {
        let range = period.interval(now: now, calendar: calendar)
        let end = min(range.end, now)
        let first = period.kind == .allTime ? (payments.map(\.date).min() ?? now) : range.start
        return max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: end).day ?? 0) + 1)
    }

    // MARK: - Answers

    func answer(_ intent: AskIntent) -> Insight {
        switch intent {
        case let .total(period, category, merchant):
            let list = payments(in: period, category: category, merchant: merchant)
            let sum = list.reduce(0) { $0 + $1.spent }
            let what = merchant.map { "at \($0)" } ?? category.map { "on \($0.title.lowercased())" } ?? ""
            let text = list.isEmpty
                ? "Nothing spent \(what) \(period.phrase(now: now, calendar: calendar))."
                : "You spent \(dollars(sum)) \(what) \(period.phrase(now: now, calendar: calendar)), across \(list.count) \(list.count == 1 ? "payment" : "payments")."
            var insight = Insight(headline: dollars(sum), text: Self.tidy(text))
            if category == nil, merchant == nil {
                insight.rows = categoryRows(period, limit: 4)
            } else {
                insight.rows = list.sorted { $0.date > $1.date }.prefix(4).map(row)
            }
            insight.followUps = [
                category == nil && merchant == nil ? AskQuestion(text: "Where did most of it go?", symbol: "chart.pie.fill", intent: .categories(period)) : nil,
                AskQuestion(text: "Compare with the month before", symbol: "arrow.left.arrow.right", intent: .compare(period.kind == .allTime ? .thisMonth : period, category)),
                AskQuestion(text: "My biggest purchases \(period.phrase(now: now, calendar: calendar))", symbol: "crown.fill", intent: .biggest(period)),
            ].compactMap { $0 }
            return insight

        case let .biggest(period):
            let top = biggest(period)
            guard let first = top.first else { return Insight(text: "No purchases \(period.phrase(now: now, calendar: calendar)) yet.") }
            var insight = Insight(headline: dollars(first.spent),
                                  text: "Your most expensive purchase \(period.phrase(now: now, calendar: calendar)) was \(first.merchant) on \(first.date.formatted(.dateTime.month(.abbreviated).day())).",
                                  rows: top.map(row))
            insight.followUps = [
                AskQuestion(text: "How often do I go to \(first.merchant)?", symbol: "repeat", intent: .habit(first.merchant)),
                AskQuestion(text: "How much on \(first.category.title.lowercased()) \(period.phrase(now: now, calendar: calendar))?", symbol: "tag.fill", intent: .total(period, first.category, nil)),
            ]
            return insight

        case let .categories(period):
            let split = byCategory(period)
            guard let top = split.first else { return Insight(text: "No spending \(period.phrase(now: now, calendar: calendar)) yet.") }
            let sum = split.reduce(0) { $0 + $1.amount }
            let percent = Int((top.amount / max(sum, 0.01) * 100).rounded())
            var insight = Insight(headline: top.category.title,
                                  text: "\(top.category.title) took the most \(period.phrase(now: now, calendar: calendar)): \(dollars(top.amount)), \(percent)% of \(dollars(sum)).",
                                  rows: categoryRows(period, limit: 5))
            insight.followUps = [
                AskQuestion(text: "Is \(top.category.title.lowercased()) up from before?", symbol: "chart.line.uptrend.xyaxis", intent: .compare(period, top.category)),
                AskQuestion(text: "Where do I spend most?", symbol: "storefront.fill", intent: .merchants(period)),
            ]
            return insight

        case let .merchants(period):
            let shops = byMerchant(period)
            guard let top = shops.first else { return Insight(text: "No spending \(period.phrase(now: now, calendar: calendar)) yet.") }
            let most = shops.prefix(5).map(\.amount).max() ?? 1
            var insight = Insight(headline: top.name,
                                  text: "You spent the most at \(top.name) \(period.phrase(now: now, calendar: calendar)): \(dollars(top.amount)) over \(top.count) \(top.count == 1 ? "visit" : "visits").",
                                  rows: shops.prefix(5).map { shop in
                                      InsightRow(image: SpendCategory.guess(merchant: shop.name).asset, emoji: SpendCategory.guess(merchant: shop.name).emoji, title: shop.name,
                                                 detail: "\(shop.count) \(shop.count == 1 ? "payment" : "payments")",
                                                 value: dollars(shop.amount), share: shop.amount / max(most, 0.01))
                                  })
            insight.followUps = [AskQuestion(text: "How often do I go to \(top.name)?", symbol: "repeat", intent: .habit(top.name))]
            return insight

        case let .compare(period, category):
            let before = period.previous(now: now, calendar: calendar)
            let a = total(period, category: category), b = total(before, category: category)
            let what = category.map { " on \($0.title.lowercased())" } ?? ""
            let change = b > 0 ? (a - b) / b : 0
            let text: String
            if b == 0 { text = "Nothing\(what) \(before.phrase(now: now, calendar: calendar)) to compare with; \(dollars(a)) \(period.phrase(now: now, calendar: calendar))." }
            else if abs(change) < 0.05 { text = "About the same\(what): \(dollars(a)) \(period.phrase(now: now, calendar: calendar)) and \(dollars(b)) \(before.phrase(now: now, calendar: calendar))." }
            else {
                text = "\(change > 0 ? "Up" : "Down") \(Int((abs(change) * 100).rounded()))%\(what): \(dollars(a)) \(period.phrase(now: now, calendar: calendar)) against \(dollars(b)) \(before.phrase(now: now, calendar: calendar))."
            }
            let most = max(a, b, 0.01)
            var insight = Insight(headline: b == 0 ? dollars(a) : (change >= 0 ? "+" : "−") + dollars(abs(a - b)), text: text, rows: [
                InsightRow(emoji: "📅", title: period.phrase(now: now, calendar: calendar).replacingOccurrences(of: "in ", with: "").capitalizedFirst, value: dollars(a), share: a / most),
                InsightRow(emoji: "🗓️", title: before.phrase(now: now, calendar: calendar).replacingOccurrences(of: "in ", with: "").capitalizedFirst, value: dollars(b), share: b / most),
            ])
            if category == nil, let mover = biggestMover(period) {
                insight.followUps = [AskQuestion(text: "Why is \(mover.title.lowercased()) up?", symbol: "magnifyingglass", intent: .compare(period, mover))]
            }
            return insight

        case let .habit(shop):
            let list = visits(shop)
            guard let last = list.first else { return Insight(text: "No payments at \(shop) yet.") }
            let sum = list.reduce(0) { $0 + $1.spent }
            let month = payments(in: .thisMonth, merchant: shop).count
            var insight = Insight(headline: "\(list.count)×",
                                  text: "You've paid at \(last.merchant) \(list.count) \(list.count == 1 ? "time" : "times") (\(month) this month), \(dollars(sum)) in all, about \(dollars(sum / Double(list.count))) a visit. Last time was \(last.date.formatted(.relative(presentation: .named))).",
                                  rows: list.prefix(4).map(row))
            insight.followUps = [AskQuestion(text: "How much at \(last.merchant) this month?", symbol: "storefront.fill", intent: .total(.thisMonth, nil, last.merchant))]
            return insight

        case let .dailyAverage(period):
            let sum = total(period), days = days(in: period)
            return Insight(headline: dollars(sum / Double(days)),
                           text: "You've averaged \(dollars(sum / Double(days))) a day \(period.phrase(now: now, calendar: calendar)), \(dollars(sum)) over \(days) \(days == 1 ? "day" : "days").",
                           followUps: [AskQuestion(text: "My biggest purchases \(period.phrase(now: now, calendar: calendar))", symbol: "crown.fill", intent: .biggest(period))])

        case let .day(period):
            let list = payments(in: period).sorted { $0.date > $1.date }
            return Insight(headline: dollars(list.reduce(0) { $0 + $1.spent }),
                           text: list.isEmpty ? "Nothing bought \(period.phrase(now: now, calendar: calendar))."
                               : "\(list.count) \(list.count == 1 ? "payment" : "payments") \(period.phrase(now: now, calendar: calendar)).",
                           rows: list.prefix(6).map(row))

        case .owed:
            let open = balances.filter { $0.owed > 0 }
            guard !open.isEmpty else { return Insight(headline: "$0.00", text: "Nobody owes you anything right now.") }
            let sum = open.reduce(0) { $0 + $1.owed }
            return Insight(headline: money(sum),
                           text: open.count == 1 ? "\(open[0].person.name) owes you \(money(open[0].owed))." : "\(open.count) friends owe you \(money(sum)) in all.",
                           rows: open.map { InsightRow(emoji: "🙋", title: $0.person.name, detail: "\($0.splits) \($0.splits == 1 ? "split" : "splits")", value: money($0.owed)) },
                           followUps: [AskQuestion(text: open.count == 1 ? "Remind \(open[0].person.name)" : "Remind everyone who hasn't paid",
                                                   symbol: "bell.fill", intent: .act("remind everyone who hasn't paid"))])

        case .act:
            return Insight(text: "")
        }
    }

    /// The category that grew most against the period before, when it grew by a third or more.
    func biggestMover(_ period: Period) -> SpendCategory? {
        let before = period.previous(now: now, calendar: calendar)
        var best: (category: SpendCategory, growth: Double)?
        for category in SpendCategory.allCases {
            let now = total(period, category: category), then = total(before, category: category)
            guard then > 0, now >= then * 1.33, now - then >= 10 else { continue }
            if now - then > best?.growth ?? 0 { best = (category, now - then) }
        }
        return best?.category
    }

    private func categoryRows(_ period: Period, limit: Int) -> [InsightRow] {
        let split = byCategory(period)
        let most = split.first?.amount ?? 1
        return split.prefix(limit).map {
            InsightRow(image: $0.category.asset, emoji: $0.category.emoji, title: $0.category.title, value: dollars($0.amount), share: $0.amount / max(most, 0.01))
        }
    }

    private func row(_ tx: Payment) -> InsightRow {
        InsightRow(image: tx.category.asset, emoji: tx.category.emoji, title: tx.merchant,
                   detail: tx.date.formatted(.dateTime.month(.abbreviated).day()), value: dollars(tx.spent))
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " .", with: ".")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
