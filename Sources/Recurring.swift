import Foundation

/// How often a bill comes back.
enum RepeatEvery: String, Codable, CaseIterable, Identifiable {
    case weekly, biweekly, monthly, quarterly, yearly

    var id: String { rawValue }

    /// The chip's label.
    var short: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Every 3 months"
        case .yearly: return "Yearly"
        }
    }

    /// "every month", for sentences.
    var phrase: String {
        switch self {
        case .weekly: return "every week"
        case .biweekly: return "every 2 weeks"
        case .monthly: return "every month"
        case .quarterly: return "every 3 months"
        case .yearly: return "every year"
        }
    }

    /// How many times it comes in a year, for the yearly total.
    var perYear: Double {
        switch self {
        case .weekly: return 52
        case .biweekly: return 26
        case .monthly: return 12
        case .quarterly: return 4
        case .yearly: return 1
        }
    }

    /// The `index`th date counted from the first one. Always counted from the first date, so a bill on the 31st
    /// lands on Feb 28 and goes back to the 31st in March instead of drifting.
    func date(_ index: Int, from start: Date, calendar: Calendar = .current) -> Date {
        let value: (Calendar.Component, Int)
        switch self {
        case .weekly: value = (.day, 7 * index)
        case .biweekly: value = (.day, 14 * index)
        case .monthly: value = (.month, index)
        case .quarterly: value = (.month, 3 * index)
        case .yearly: value = (.year, index)
        }
        return calendar.date(byAdding: value.0, value: value.1, to: start) ?? start
    }
}

/// A payment that comes back on its own: rent, the electric bill, a subscription.
struct Recurring: Identifiable, Codable, Equatable {
    var id = UUID()
    var merchant: String
    var amount: Double
    var category: SpendCategory = .bills
    var card: String = ""
    var note: String?
    var every: RepeatEvery = .monthly
    /// The first payment's date; every later one is counted from it.
    var start: Date
    /// How many payments have been added so far.
    var logged = 0
    var paused = false

    var cents: Int { Int((amount * 100).rounded()) }
    func date(_ index: Int) -> Date { every.date(index, from: start) }
    /// When the next one will be added.
    var next: Date { date(logged) }
    var yearly: Double { amount * every.perYear }
}

extension WalletStore {
    /// The most missed payments added at once, so a bill started years ago doesn't flood the list.
    static let catchUpLimit = 60

    /// Adds every repeating payment that has come due, each on its own date. Returns how many were added.
    @discardableResult
    func logDueRecurring(now: Date = .now) -> Int {
        var added = 0
        for index in recurring.indices where !recurring[index].paused {
            var bill = recurring[index]
            var count = 0
            while bill.next <= now && count < Self.catchUpLimit {
                appendRecurring(bill, on: bill.next)
                bill.logged += 1
                count += 1
            }
            // Past the limit, skip ahead to today rather than adding years of payments.
            while bill.next <= now { bill.logged += 1 }
            if bill != recurring[index] { recurring[index] = bill }
            added += count
        }
        if added > 0 { sortAndSave() }
        saveRecurring()
        return added
    }

    /// Starts a repeating payment. Anything already due (today, or a past start date) is added straight away.
    @discardableResult
    /// `firstIsLogged` when the first payment was already saved by hand and linked to it.
    func startRecurring(_ bill: Recurring, firstIsLogged: Bool = false, now: Date = .now) -> Recurring {
        var bill = bill
        bill.merchant = bill.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        bill.logged = firstIsLogged ? 1 : 0
        recurring.append(bill)
        logDueRecurring(now: now)
        return recurring.first { $0.id == bill.id } ?? bill
    }

    /// Changes a repeating payment from the next one on; payments already added stay as they were.
    func updateRecurring(_ bill: Recurring) {
        guard let index = recurring.firstIndex(where: { $0.id == bill.id }) else { return }
        let old = recurring[index]
        var bill = bill
        // A new rhythm or first date restarts the count from the next payment still to come.
        if bill.every != old.every || bill.start != old.start {
            var logged = 0
            let last = transactions.filter { $0.recurringID == bill.id }.map(\.date).max()
            if let last { while bill.every.date(logged, from: bill.start) <= last { logged += 1 } }
            bill.logged = logged
        }
        recurring[index] = bill
        saveRecurring()
        logDueRecurring()
    }

    /// Stops it coming back. Payments already added are kept.
    func stopRecurring(_ id: UUID) {
        recurring.removeAll { $0.id == id }
        saveRecurring()
    }

    func recurringBill(_ id: UUID?) -> Recurring? { id.flatMap { id in recurring.first { $0.id == id } } }
}
