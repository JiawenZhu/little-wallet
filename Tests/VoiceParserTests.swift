import XCTest
@testable import LittleWallet

final class VoiceParserTests: XCTestCase {
    private let friends = ["Sam", "Kate Bell"]

    func testOnePricedItem() {
        let plan = VoiceParser.parse("$13 strawberry")
        XCTAssertEqual(plan.lines, [.init(name: "Strawberry", cents: 1300)])
        XCTAssertFalse(plan.wantsSplit)
    }

    func testSeveralItemsAndTheShop() {
        let plan = VoiceParser.parse("I bought strawberries for $13 and milk 4 dollars at Trader Joe's")
        XCTAssertEqual(plan.store, "Trader Joe's")
        XCTAssertEqual(plan.lines, [.init(name: "Strawberries", cents: 1300), .init(name: "Milk", cents: 400)])
        XCTAssertEqual(plan.totalCents, 1700)
    }

    func testSplitWithFriendsMatchesMisheardNames() {
        let plan = VoiceParser.parse("Split $13 strawberries with Sam and Kit", friends: friends)
        XCTAssertTrue(plan.wantsSplit)
        XCTAssertEqual(plan.people, ["Sam", "Kate Bell"])
        XCTAssertEqual(plan.lines, [.init(name: "Strawberries", cents: 1300)])
        XCTAssertEqual(plan.shares, [434, 433, 433], "Three people, exact to the cent")
    }

    func testSpokenNumbersAndNoFood() {
        let plan = VoiceParser.parse("Seven dollars split up")
        XCTAssertTrue(plan.wantsSplit)
        XCTAssertEqual(plan.lines, [.init(name: "Payment", cents: 700)])
    }

    func testSplitUpAnItem() {
        let plan = VoiceParser.parse("Split up strawberry $13")
        XCTAssertTrue(plan.wantsSplit)
        XCTAssertEqual(plan.lines, [.init(name: "Strawberry", cents: 1300)])
    }

    func testQuantityAndEach() {
        XCTAssertEqual(VoiceParser.parse("2 milks $4 each").lines, [.init(name: "Milks", quantity: 2, cents: 800)])
    }

    func testAndInsideAName() {
        XCTAssertEqual(VoiceParser.parse("mac and cheese $5").lines, [.init(name: "Mac and cheese", cents: 500)])
    }

    func testSplitSomeWaysWithoutNames() {
        let plan = VoiceParser.parse("split three ways eggs six dollars")
        XCTAssertEqual(plan.headcount, 3)
        XCTAssertEqual(plan.lines, [.init(name: "Eggs", cents: 600)])
        XCTAssertEqual(plan.shares, [200, 200, 200])
    }

    func testBetweenMeAndFriends() {
        let plan = VoiceParser.parse("Twenty five dollars at Costco split between me, Sam and Kate", friends: friends)
        XCTAssertEqual(plan.store, "Costco")
        XCTAssertEqual(plan.people, ["Sam", "Kate Bell"])
        XCTAssertEqual(plan.lines, [.init(name: "Payment", cents: 2500)])
        XCTAssertEqual(plan.shares, [834, 833, 833])
    }

    func testDollarsAndCents() {
        XCTAssertEqual(VoiceParser.parse("bread 3 dollars and 50 cents").lines, [.init(name: "Bread", cents: 350)])
    }

    func testModelAnswersAreTidied() {
        let raw = VoicePlan(store: " ", lines: [.init(name: "avocados", quantity: 3, cents: 600), .init(name: "Nothing", cents: 0)],
                            people: ["me", "Kit", "Sam"])
        let plan = VoiceParser.tidy(raw, friends: friends)
        XCTAssertEqual(plan.lines, [.init(name: "Avocados", quantity: 3, cents: 600)])
        XCTAssertEqual(plan.people, ["Kate Bell", "Sam"])
        XCTAssertTrue(plan.wantsSplit)
    }
}
