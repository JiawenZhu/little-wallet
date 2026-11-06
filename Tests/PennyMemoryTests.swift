import XCTest
@testable import LittleWallet

@MainActor
final class PennyMemoryTests: XCTestCase {
    private func fresh() -> UserDefaults { UserDefaults(suiteName: "penny-mem-\(UUID().uuidString)")! }
    private let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

    private var analyst: Analyst {
        let at = { (m: Int, d: Int) in ISO8601DateFormatter().date(from: String(format: "2026-%02d-%02dT12:00:00Z", m, d))! }
        return Analyst(payments: [
            Payment(date: at(11, 3), merchant: "Costco", amount: 80, category: .groceries),
            Payment(date: at(11, 4), merchant: "Chipotle", amount: 14, category: .dining),
            Payment(date: at(10, 9), merchant: "Costco", amount: 120, category: .groceries),
            Payment(date: at(10, 10), merchant: "Sushi Ran", amount: 60, category: .dining),
        ], now: now)
    }

    func testFollowUpsCarryThePeriodAndTopic() {
        var context = PennyContext()
        XCTAssertNil(context.followUp("what about October?", analyst: analyst), "nothing to follow up yet")
        context.absorb(.total(.thisMonth, .dining, nil), answer: Insight(text: ""))
        let october = Period(kind: .month, month: 10, year: 2026)
        XCTAssertEqual(context.followUp("what about October?", analyst: analyst), .total(october, .dining, nil))
        context.absorb(.total(october, .dining, nil), answer: Insight(text: ""))
        XCTAssertEqual(context.followUp("and groceries?", analyst: analyst), .total(october, .groceries, nil), "keeps October")
        XCTAssertEqual(context.followUp("at Costco?", analyst: analyst), .total(october, nil, "Costco"))
        XCTAssertEqual(context.followUp("why?", analyst: analyst), .compare(october, .dining))
        XCTAssertEqual(context.followUp("what was the biggest?", analyst: analyst), .biggest(october))
    }

    func testAFullQuestionStandsOnItsOwn() {
        var context = PennyContext()
        context.absorb(.total(.lastMonth, .dining, nil), answer: Insight(text: ""))
        XCTAssertNil(context.followUp("How much did I spend on my trip to the beach house?", analyst: analyst))
    }

    func testTheChatSurvivesAClosedApp() throws {
        let defaults = fresh()
        let chat = PennyChat(defaults: defaults)
        chat.turns = [PennyTurn(question: "How much on dining?", answer: Insight(headline: "$14.00", text: "You spent $14.00.",
                                plan: PennyPlan(kind: .invoice, lines: [.init(name: "Sam", cents: 500, note: "Tea")])))]
        chat.context.absorb(.total(.thisMonth, .dining, nil), answer: Insight(text: ""))
        chat.remember("Sam is my roommate")
        chat.save()

        let later = PennyChat(defaults: defaults)
        XCTAssertEqual(later.turns.first?.question, "How much on dining?")
        XCTAssertEqual(later.turns.first?.answer?.headline, "$14.00")
        XCTAssertNil(later.turns.first?.answer?.plan, "a card can't be confirmed from an old chat")
        XCTAssertEqual(later.turns.first?.answer?.closedPlan, "PayPal invoice · $5.00")
        XCTAssertEqual(later.context.category, .dining)
        XCTAssertEqual(later.facts, ["Sam is my roommate"])

        later.startOver()
        XCTAssertTrue(later.turns.isEmpty)
        XCTAssertNil(later.context.topic)
        XCTAssertEqual(later.facts, ["Sam is my roommate"], "starting over keeps what she was told to remember")
    }

    func testRememberingAndForgetting() throws {
        let chat = PennyChat(defaults: fresh())
        XCTAssertEqual(chat.command("Remember that my grocery budget is $300.")?.text, "Got it. I'll remember that my grocery budget is $300.")
        XCTAssertEqual(chat.facts, ["my grocery budget is $300"])
        XCTAssertEqual(chat.recall("What's my budget?"), "my grocery budget is $300")
        XCTAssertNil(chat.recall("How is the weather?"))
        XCTAssertEqual(chat.command("what do you remember?")?.rows.first?.title, "my grocery budget is $300")
        XCTAssertNil(chat.command("How much did I spend?"))
        XCTAssertEqual(chat.command("forget the budget")?.text, "Okay, I've forgotten that.")
        XCTAssertTrue(chat.facts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(chat.command("did you send it?")).text.contains("only act after you tap"))
    }

    func testPronounsAndChangesFollowTheConversation() throws {
        let splits = SplitService(defaults: fresh())
        let me = SplitPerson(id: "me", name: "You", colorIndex: 0, isMe: true)
        let sam = SplitPerson(id: "sam", name: "Sam Lee", colorIndex: 1)
        let alex = SplitPerson(id: "alex", name: "Alex Kim", colorIndex: 2)
        splits.adopt(SentSplit(id: "tj", title: "Trader Joe's", method: "PayPal", createdAt: .now, total: "56.00", itemIDs: [], people: [me, sam, alex], shares: [
            "sam": SplitShare(name: "Sam Lee", total: "28.00", status: "sent", paidVia: nil, link: ""),
            "alex": SplitShare(name: "Alex Kim", total: "28.00", status: "sent", paidVia: nil, link: ""),
        ]))
        let paypal = PayPalLink(defaults: fresh())
        var context = PennyContext()

        let unknown = PennyPlanner.reply(to: "remind him", splits: splits, paypal: paypal, context: &context)
        XCTAssertNil(unknown.plan)
        XCTAssertTrue(unknown.text.contains("Who do you mean"))

        context.people = ["Sam Lee"]
        let plan = try XCTUnwrap(PennyPlanner.reply(to: "remind him", splits: splits, paypal: paypal, context: &context).plan)
        XCTAssertEqual(plan.lines.map(\.name), ["Sam Lee"], "Alex wasn't being discussed")

        context.people = ["Sam Lee", "Alex Kim"]
        _ = PennyPlanner.reply(to: "remind them", splits: splits, paypal: paypal, context: &context)
        let both = try XCTUnwrap(PennyPlanner.reply(to: "make it $30", splits: splits, paypal: paypal, context: &context).plan)
        XCTAssertEqual(both.lines.map(\.name), ["Sam Lee", "Alex Kim"], "nobody is dropped")
        XCTAssertEqual(both.total, 6000)

        _ = PennyPlanner.reply(to: "Invoice Sam $45 for the Airbnb", splits: splits, paypal: paypal, context: &context)
        XCTAssertTrue(PennyPlanner.isAction("make it $30", context: context))
        let changed = try XCTUnwrap(PennyPlanner.reply(to: "make it $30", splits: splits, paypal: paypal, context: &context).plan)
        XCTAssertEqual(changed.lines.first?.cents, 3000)
        XCTAssertEqual(changed.lines.first?.name, "Sam Lee")
        XCTAssertEqual(changed.lines.first?.note, "The Airbnb")
        let same = try XCTUnwrap(PennyPlanner.reply(to: "same for Alex", splits: splits, paypal: paypal, context: &context).plan)
        XCTAssertEqual(same.lines.first?.name, "Alex Kim")
        XCTAssertEqual(same.lines.first?.cents, 3000)
    }
}
