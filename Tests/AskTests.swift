import XCTest
@testable import LittleWallet

final class AskTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()
    private func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }
    private var now: Date { day(11, 20) }

    private func pay(_ merchant: String, _ amount: Double, _ month: Int, _ d: Int, _ category: SpendCategory? = nil) -> Payment {
        Payment(date: day(month, d), merchant: merchant, amount: amount, category: category ?? .guess(merchant: merchant))
    }

    private var analyst: Analyst {
        Analyst(payments: [
            pay("Trader Joe's", 21.65, 11, 18), pay("Trader Joe's", 30, 11, 4), pay("Uber", 18.4, 11, 19),
            pay("Sushi Ran", 86, 11, 10), pay("Blue Bottle Coffee", 6.75, 11, 19),
            pay("Trader Joe's", 25, 10, 12), pay("Chipotle", 13, 10, 30), pay("Comcast", 79.99, 10, 2),
        ], now: now, calendar: calendar)
    }

    func testPeriodsAreReadFromQuestions() {
        XCTAssertEqual(Period.find(in: "how much last month", now: now, calendar: calendar), .lastMonth)
        XCTAssertEqual(Period.find(in: "what did I spend in October?", now: now, calendar: calendar), Period(kind: .month, month: 10, year: 2026))
        XCTAssertEqual(Period.find(in: "spent in December", now: now, calendar: calendar), Period(kind: .month, month: 12, year: 2025),
                       "a month still to come means last year's")
        XCTAssertNil(Period.find(in: "coffee", now: now, calendar: calendar))
    }

    func testTotalsAreExact() {
        let a = analyst
        XCTAssertEqual(a.total(.thisMonth), 162.8, accuracy: 0.001)
        XCTAssertEqual(a.total(.lastMonth), 117.99, accuracy: 0.001)
        XCTAssertEqual(a.total(.allTime, merchant: "trader joe"), 76.65, accuracy: 0.001)
        XCTAssertEqual(a.answer(.total(.thisMonth, nil, nil)).headline, "$162.80")
    }

    func testBiggestCategoriesAndCompare() {
        let a = analyst
        XCTAssertEqual(a.answer(.biggest(.thisMonth)).headline, "$86.00")
        XCTAssertEqual(a.byCategory(.thisMonth).first?.category, .dining, "sushi and coffee")
        let compare = a.answer(.compare(.thisMonth, nil))
        XCTAssertTrue(compare.text.hasPrefix("Up 38%"), compare.text)
        XCTAssertEqual(a.answer(.habit("Trader Joe's")).headline, "3×")
    }

    func testSuggestionsFollowRealSpending() {
        let questions = Suggester.questions(analyst, memory: [:], recent: []).map(\.text)
        XCTAssertEqual(questions.first, "How much did I spend this month?")
        XCTAssertTrue(questions.contains("How often do I go to Trader Joe's?"))
        XCTAssertTrue(questions.contains("Why is eating out up this month?"), "dining went from $13 to $92.75")
        XCTAssertFalse(questions.contains("Who still owes me money?"), "nobody owes anything")
    }

    func testSuggestionsLearnWhatSomeoneAsks() {
        let plain = Suggester.questions(analyst, memory: [:], recent: []).map(\.text)
        let learned = Suggester.questions(analyst, memory: ["habit": 4, "shop:trader joe's": 4], recent: []).map(\.text)
        XCTAssertLessThan(learned.firstIndex(of: "How often do I go to Trader Joe's?")!, plain.firstIndex(of: "How often do I go to Trader Joe's?")!)
        let after = Suggester.questions(analyst, memory: [:], recent: ["How much did I spend this month?"]).map(\.text)
        XCTAssertNotEqual(after.first, "How much did I spend this month?", "a question just asked steps back")
    }

    func testTypedQuestionsAreRouted() {
        let a = analyst
        XCTAssertEqual(AskRouter.intent(for: "How much did I spend last month?", analyst: a), .total(.lastMonth, nil, nil))
        XCTAssertEqual(AskRouter.intent(for: "what's the most expensive thing I bought", analyst: a), .biggest(.thisMonth))
        XCTAssertEqual(AskRouter.intent(for: "how often do I go to trader joe's", analyst: a), .habit("Trader Joe's"))
        XCTAssertEqual(AskRouter.intent(for: "how much on coffee this week", analyst: a), .total(.thisWeek, .dining, nil))
        XCTAssertEqual(AskRouter.intent(for: "am I spending more than last month", analyst: a), .compare(.lastMonth, nil))
        XCTAssertEqual(AskRouter.intent(for: "who owes me", analyst: a), .owed)
        XCTAssertNil(AskRouter.intent(for: "tell me a joke", analyst: a))
    }
}
