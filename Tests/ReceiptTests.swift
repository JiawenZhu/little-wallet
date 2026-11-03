import XCTest
@testable import LittleWallet

final class ReceiptTests: XCTestCase {
    func testGroceryReceiptReadsItemsTaxAndTotal() {
        let rows = [
            "TRADER JOE'S",
            "1234 Market St  San Francisco CA 94103",
            "(415) 555-0134",
            "ORGANIC BANANAS  1.99",
            "2 X GREEK YOGURT  7.98",
            "SOURDOUGH BREAD 4011  4.49 F",
            "STRAWBERRIES",
            "1.50 lb @ 3.99/lb  5.99",
            "Cashews  8.49",
            "SUBTOTAL  28.94",
            "TAX  1.12",
            "TOTAL  30.06",
            "VISA  30.06",
            "CHANGE DUE  0.00",
            "11/01/26 14:32",
        ]
        let scan = ReceiptParser.parse(rows)
        XCTAssertEqual(scan.merchant, "Trader Joe's")
        XCTAssertEqual(scan.lines.map(\.name), ["Organic Bananas", "Greek Yogurt", "Sourdough Bread", "Strawberries", "Cashews"])
        XCTAssertEqual(scan.lines.map(\.cents), [199, 798, 449, 599, 849])
        XCTAssertEqual(scan.lines[1].quantity, 2)
        XCTAssertEqual(scan.subtotalCents, 2894)
        XCTAssertEqual(scan.taxCents, 112)
        XCTAssertEqual(scan.totalCents, 3006)
        XCTAssertEqual(scan.extrasCents, 112)
        XCTAssertTrue(ReceiptParser.addsUp(scan))
    }

    func testCountRowUnderAnItemSplitsItIntoOnePerThing() {
        let rows = [
            "MENARDS",
            "Sale Transaction",
            "FLEX GROUND SPOUT EXT  8.69",
            "1585181",
            "K-SNAP SWING UP OUTLET  19.98",
            "1581460  2 @9.99",
            "TOTAL  28.67",
            "TAX CHAMPAIGN-IL 9.25%  2.65",
            "TOTAL SALE  31.32",
            "CHASE VISA 1949",
            "TOTAL NUMBER OF ITEMS =  3",
        ]
        let scan = ReceiptParser.parse(rows)
        XCTAssertEqual(scan.lines.map(\.cents), [869, 1998])
        XCTAssertEqual(scan.lines[1].quantity, 2)
        XCTAssertEqual(scan.totalCents, 3132)
        XCTAssertTrue(ReceiptParser.addsUp(scan))

        let unpacked = ReceiptParser.unpacked(scan)
        XCTAssertEqual(unpacked.lines.map(\.name), ["Flex Ground Spout Ext", "K-snap Swing UP Outlet", "K-snap Swing UP Outlet"])
        XCTAssertEqual(unpacked.lines.map(\.cents), [869, 999, 999])
        XCTAssertEqual(unpacked.totalCents, 3132)
    }

    func testUnpackingKeepsEveryCent() {
        var scan = ReceiptScan()
        scan.lines = [.init(name: "Tacos", quantity: 3, cents: 1000), .init(name: "Soda cans", quantity: 24, cents: 1299)]
        let unpacked = ReceiptParser.unpacked(scan)
        XCTAssertEqual(unpacked.lines.map(\.cents), [334, 333, 333, 1299])
        XCTAssertEqual(unpacked.itemsCents, scan.itemsCents)
    }

    func testRestaurantTipAndDiscount() {
        let rows = [
            "Golden Dragon Kitchen",
            "Table 12  Server: Amy",
            "Dumplings  12.00",
            "Kung Pao Chicken  16.50",
            "Fried Rice  11.00",
            "Happy hour discount  -2.00",
            "Subtotal  37.50",
            "Tax  3.28",
            "Total  40.78",
            "Tip  7.50",
            "Total  48.28",
        ]
        let scan = ReceiptParser.parse(rows)
        XCTAssertEqual(scan.merchant, "Golden Dragon Kitchen")
        XCTAssertEqual(scan.lines.map(\.cents), [1200, 1650, 900])
        XCTAssertEqual(scan.tipCents, 750)
        XCTAssertEqual(scan.totalCents, 4828)
        XCTAssertEqual(scan.extrasLabel, "Tax & tip")
    }

    func testRowsJoinPiecesOnOneLine() {
        let rows = ReceiptReader.rows(from: [
            ("4.99", CGRect(x: 0.8, y: 0.301, width: 0.1, height: 0.02)),
            ("MILK", CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.02)),
            ("EGGS", CGRect(x: 0.1, y: 0.34, width: 0.2, height: 0.02)),
        ])
        XCTAssertEqual(rows.map(\.text), ["MILK  4.99", "EGGS"])
    }

    @MainActor func testEveryFriendGetsTheirOwnColour() {
        let defaults = UserDefaults(suiteName: "colours-\(UUID())")!
        let service = SplitService(defaults: defaults)
        let names = (1...20).map { "Friend \($0)" }
        let people = names.compactMap { service.rememberFriend(named: $0) }
        XCTAssertEqual(Set(people.map(\.colorIndex)).count, 20)
        XCTAssertFalse(people.contains { $0.colorIndex == 0 })
        // Forgetting someone frees their colour for the next friend, never doubles one up.
        service.forget(people[2])
        let next = service.rememberFriend(named: "Newcomer")!
        XCTAssertEqual(next.colorIndex, people[2].colorIndex)
        XCTAssertEqual(SplitPerson.colors(for: 3).count, 1)
        XCTAssertEqual(SplitPerson.colors(for: 15).count, 2)
    }
}
