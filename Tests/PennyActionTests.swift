import XCTest
@testable import LittleWallet

@MainActor
final class PennyActionTests: XCTestCase {
    private func setup() -> SplitService {
        let splits = SplitService(defaults: UserDefaults(suiteName: "penny-\(UUID().uuidString)")!)
        let me = SplitPerson(id: "me", name: "Evan", colorIndex: 0, isMe: true)
        let sam = SplitPerson(id: "sam", name: "Sam Lee", colorIndex: 1, venmo: "sam@example.com")
        let jing = SplitPerson(id: "jing", name: "Jing Allen", colorIndex: 2, venmo: "4155550134")
        splits.adopt(SentSplit(id: "tj", title: "Trader Joe's run", method: "PayPal", createdAt: .now, total: "40.00", itemIDs: [],
                               people: [me, sam, jing], shares: [
                                   "sam": SplitShare(name: "Sam Lee", total: "15.74", status: "sent", paidVia: nil, link: ""),
                                   "jing": SplitShare(name: "Jing Allen", total: "9.60", status: "paid", paidVia: "Venmo", link: ""),
                               ]))
        return splits
    }

    func testRemindPlansAnInvoiceForEachUnpaidShare() throws {
        let splits = setup()
        XCTAssertTrue(PennyPlanner.isAction("Remind everyone who hasn't paid"))
        let reply = PennyPlanner.reply(to: "Remind everyone who hasn't paid", splits: splits, paypal: PayPalLink(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let plan = try XCTUnwrap(reply.plan)
        XCTAssertEqual(plan.kind, .invoice)
        XCTAssertEqual(plan.lines.map(\.name), ["Sam Lee"], "Jing already paid")
        XCTAssertEqual(plan.lines.first?.cents, 1574)
        XCTAssertEqual(plan.lines.first?.to, "sam@example.com")
        XCTAssertEqual(plan.lines.first?.note, "Your share of Trader Joe's run")
    }

    func testInvoiceReadsWhoHowMuchAndWhatFor() throws {
        let reply = PennyPlanner.reply(to: "Invoice Sam $45 for his half of the Airbnb", splits: setup(), paypal: PayPalLink(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let line = try XCTUnwrap(reply.plan?.lines.first)
        XCTAssertEqual(line.name, "Sam Lee")
        XCTAssertEqual(line.cents, 4500)
        XCTAssertEqual(line.note, "Half of the Airbnb")
    }

    func testPayBackGoesToVenmoByPhoneAndNeedsAnAddress() throws {
        let reply = PennyPlanner.reply(to: "Pay Sam and Jing back $20 for the concert tickets", splits: setup(), paypal: PayPalLink(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let plan = try XCTUnwrap(reply.plan)
        XCTAssertEqual(plan.kind, .payout)
        XCTAssertEqual(plan.total, 4000)
        XCTAssertEqual(plan.lines.map(\.wallet).sorted(), ["PayPal", "Venmo"])
        XCTAssertTrue(plan.ready)
        var missing = plan
        missing.lines[0].to = ""
        XCTAssertFalse(missing.ready)
    }

    func testOnlyTickedLinesAreSentAndCounted() {
        var plan = PennyPlan(kind: .invoice, lines: [
            .init(name: "Jing", cents: 1287, note: "A"), .init(name: "Aaron", cents: 1284, note: "B"), .init(name: "Jing", cents: 1566, note: "C"),
        ])
        XCTAssertEqual(plan.confirmTitle, "Send 3 invoices")
        plan.lines[1].included = false
        XCTAssertEqual(plan.chosen.map(\.note), ["A", "C"])
        XCTAssertEqual(plan.total, 2853)
        XCTAssertEqual(plan.confirmTitle, "Send 2 invoices")
        for index in plan.lines.indices { plan.lines[index].included = false }
        XCTAssertFalse(plan.ready, "nothing ticked, nothing to send")
    }

    func testFriendsAndInvoicesAreCountedApart() {
        XCTAssertTrue(PennyPlanner.inviteLine(shares: 9, people: 2).hasPrefix("2 friends still owe you for 9 splits"))
        XCTAssertTrue(PennyPlanner.inviteLine(shares: 3, people: 1).hasPrefix("1 friend still owes you for 3 splits"))
        XCTAssertTrue(PennyPlanner.inviteLine(shares: 2, people: 2).contains("each of the 2 friends"))
    }

    func testRefundNeedsAPaymentFromThatFriend() {
        let reply = PennyPlanner.reply(to: "Refund Jing $5", splits: setup(), paypal: PayPalLink(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        XCTAssertNil(reply.plan)
        XCTAssertTrue(reply.text.contains("can't find"))
        XCTAssertFalse(PennyPlanner.isAction("How much did I spend this month?"))
    }
}

@MainActor
final class LiveUpdateTests: XCTestCase {
    func testAPaymentFromTheServerSettlesTheShareOnce() {
        let splits = SplitService(defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!)
        splits.adopt(SentSplit(id: "tj", title: "Trader Joe's run", method: "PayPal", createdAt: .now, total: "14.43", itemIDs: [],
                               people: [], shares: ["sam": SplitShare(name: "Sam Lee", total: "7.22", status: "requested", paidVia: nil, link: "")]))
        let paid = LiveUpdates.Paid(split: "tj", person: "sam", amount: "7.22", via: "PayPal invoice")
        XCTAssertTrue(LiveUpdates.settle(paid, splits: splits, notify: false))
        XCTAssertEqual(splits.splits.first?.shares["sam"]?.status, "paid")
        XCTAssertEqual(splits.splits.first?.shares["sam"]?.paidVia, "PayPal invoice")
        XCTAssertFalse(LiveUpdates.settle(paid, splits: splits, notify: false), "already paid")
        XCTAssertFalse(LiveUpdates.settle(.init(split: "nope", person: "sam"), splits: splits, notify: false))
    }
}
