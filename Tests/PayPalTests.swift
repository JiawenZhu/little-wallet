import XCTest
@testable import LittleWallet

@MainActor
final class PayPalTests: XCTestCase {
    private func fresh() -> UserDefaults {
        let name = "paypal-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private let json = """
    {"env":"sandbox","balance":"75.20","activity":[
     {"id":"7W837287","date":"2026-11-02T18:20:00Z","kind":"received","amount":"79.00","fee":"3.25","via":"Venmo","name":"Sam Lee",
      "note":"Groceries split with Evan","items":[],"split":{"id":"sca8c94","person":"sam"},"pending":false},
     {"id":"4AB","date":"2026-11-01T12:00:00Z","kind":"sent","amount":"42.10","fee":"0.00","via":"PayPal","name":"Blue Bottle Coffee",
      "note":null,"items":[{"name":"Latte","quantity":2,"amount":"12.00"}],"split":null,"pending":false},
     {"id":"9T18","date":"2026-10-30T09:00:00Z","kind":"transfer","amount":"15.18","fee":"0.00","via":"PayPal","name":null,
      "note":null,"items":[],"split":null,"pending":false}]}
    """

    func testSpendingIsImportedOnceAndFriendsPaymentsSettleTheirShare() throws {
        struct Response: Decodable { var activity: [PayPalActivity] }
        let activity = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).activity
        let store = WalletStore(defaults: fresh())
        let splits = SplitService(defaults: fresh())
        splits.adopt(SentSplit(id: "sca8c94", title: "Groceries", method: "PayPal", createdAt: .now, total: "158.00", itemIDs: [],
                               people: [], shares: ["sam": SplitShare(name: "Sam", total: "79.00", status: "sent", paidVia: nil, link: "")]))
        let link = PayPalLink(defaults: fresh())
        link.preview(activity, balance: "75.20")

        let first = link.apply(to: store, splits: splits)
        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(first.settled, 1)
        XCTAssertEqual(splits.splits.first?.shares["sam"]?.status, "paid")
        XCTAssertEqual(splits.splits.first?.shares["sam"]?.paidVia, "Venmo")

        let coffee = try XCTUnwrap(store.transactions.first)
        XCTAssertEqual(coffee.merchant, "Blue Bottle Coffee")
        XCTAssertEqual(coffee.cents, 4210)
        XCTAssertEqual(coffee.source, .paypal)
        XCTAssertEqual(coffee.category, .dining)
        XCTAssertEqual(coffee.items.first?.quantity, 2)

        let again = link.apply(to: store, splits: splits)
        XCTAssertEqual(again.added, 0, "a PayPal payment is never imported twice")
        XCTAssertEqual(again.settled, 0)
        XCTAssertEqual(store.transactions.count, 1, "bank transfers aren't spending")
    }
}
