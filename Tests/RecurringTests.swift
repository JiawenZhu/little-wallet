import XCTest
@testable import LittleWallet

@MainActor
final class RecurringTests: XCTestCase {
    private var calendar: Calendar { .current }

    private func store(_ defaults: UserDefaults? = nil) -> WalletStore {
        let name = "recurring-tests-\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: name)!
        fresh.removePersistentDomain(forName: name)
        return WalletStore(defaults: defaults ?? fresh)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }

    func testMonthlyOnThe31stDoesNotDrift() {
        let start = day(2026, 1, 31)
        let dates = (0..<4).map { RepeatEvery.monthly.date($0, from: start) }
        XCTAssertEqual(dates.map { calendar.component(.day, from: $0) }, [31, 28, 31, 30])
    }

    func testWeeklyAndYearlySteps() {
        let start = day(2026, 3, 2)
        XCTAssertEqual(RepeatEvery.biweekly.date(2, from: start), day(2026, 3, 30))
        XCTAssertEqual(RepeatEvery.yearly.date(1, from: start), day(2027, 3, 2))
    }

    func testStartingInThePastCatchesUpEachDate() {
        let wallet = store()
        let now = day(2026, 11, 9)
        wallet.startRecurring(Recurring(merchant: "Rent", amount: 1500, every: .monthly, start: day(2026, 9, 1)), now: now)
        let rent = wallet.transactions.filter { $0.merchant == "Rent" }
        XCTAssertEqual(rent.count, 3)
        XCTAssertEqual(rent.map { calendar.component(.month, from: $0.date) }, [11, 10, 9])
        XCTAssertEqual(wallet.recurring.first?.logged, 3)
        XCTAssertEqual(wallet.recurring.first?.next, day(2026, 12, 1))
        // Nothing doubles when the app opens again the same day.
        XCTAssertEqual(wallet.logDueRecurring(now: now), 0)
    }

    func testFutureStartAddsNothingUntilItsDay() {
        let wallet = store()
        wallet.startRecurring(Recurring(merchant: "Electric bill", amount: 82.5, start: day(2026, 12, 1)), now: day(2026, 11, 9))
        XCTAssertTrue(wallet.transactions.isEmpty)
        XCTAssertEqual(wallet.logDueRecurring(now: day(2026, 12, 1).addingTimeInterval(60)), 1)
        XCTAssertEqual(wallet.transactions.first?.recurringID, wallet.recurring.first?.id)
        XCTAssertEqual(wallet.transactions.first?.category, .bills)
    }

    func testFirstSavedByHandIsNotAddedTwice() {
        let wallet = store()
        let now = day(2026, 11, 9)
        let bill = Recurring(merchant: "Gym", amount: 40, every: .weekly, start: now)
        var first = wallet.add(merchant: "Gym", amount: 40, date: now, source: .manual)
        first.recurringID = bill.id
        wallet.update(first)
        wallet.startRecurring(bill, firstIsLogged: true, now: now)
        XCTAssertEqual(wallet.transactions.count, 1)
        XCTAssertEqual(wallet.logDueRecurring(now: day(2026, 11, 16).addingTimeInterval(60)), 1)
    }

    func testPausedAndStoppedBillsAddNothingButKeepPastPayments() {
        let wallet = store()
        let now = day(2026, 11, 9)
        let bill = wallet.startRecurring(Recurring(merchant: "Phone bill", amount: 45, start: day(2026, 10, 9)), now: now)
        XCTAssertEqual(wallet.transactions.count, 2)
        wallet.stopRecurring(bill.id)
        XCTAssertEqual(wallet.logDueRecurring(now: day(2027, 3, 9)), 0)
        XCTAssertEqual(wallet.transactions.count, 2)
    }

    func testChangingTheAmountAppliesFromTheNextPayment() {
        let wallet = store()
        let now = day(2026, 11, 9)
        var bill = wallet.startRecurring(Recurring(merchant: "Internet", amount: 60, start: day(2026, 11, 1)), now: now)
        bill.amount = 70
        bill.every = .monthly
        wallet.updateRecurring(bill)
        wallet.logDueRecurring(now: day(2026, 12, 2))
        XCTAssertEqual(wallet.transactions.map(\.amount), [70, 60])
    }

    func testChangingTheRhythmKeepsAddedPaymentsAndCountsOn() {
        let wallet = store()
        let now = day(2026, 11, 9)
        var bill = wallet.startRecurring(Recurring(merchant: "Cleaner", amount: 90, start: day(2026, 11, 2)), now: now)
        bill.every = .weekly
        wallet.updateRecurring(bill)
        // Nov 2 was added; weekly from Nov 2 the next is Nov 9.
        XCTAssertEqual(wallet.recurring.first?.next, day(2026, 11, 9))
    }

    func testCatchUpIsCapped() {
        let wallet = store()
        wallet.startRecurring(Recurring(merchant: "Coffee club", amount: 5, every: .weekly, start: day(2020, 1, 6)), now: day(2026, 11, 9))
        XCTAssertEqual(wallet.transactions.count, WalletStore.catchUpLimit)
        XCTAssertGreaterThan(wallet.recurring.first!.next, day(2026, 11, 9))
    }

    func testBillsSurviveARestart() {
        let name = "recurring-restart-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let wallet = WalletStore(defaults: defaults)
        wallet.startRecurring(Recurring(merchant: "Rent", amount: 1500, start: day(2026, 11, 1)), now: day(2026, 11, 9))
        let again = WalletStore(defaults: defaults)
        XCTAssertEqual(again.recurring.map(\.merchant), ["Rent"])
        XCTAssertEqual(again.transactions.first?.recurringID, again.recurring.first?.id)
    }
}
