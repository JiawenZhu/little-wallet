import XCTest
@testable import LittleWallet

@MainActor
final class CategoryTests: XCTestCase {
    private func fresh() -> UserDefaults { UserDefaults(suiteName: "categories-\(UUID().uuidString)")! }

    override func tearDown() {
        // Leave the shared list as the app ships it for the other tests.
        CategoryLibrary(defaults: fresh()).resetBuiltIns()
        super.tearDown()
    }

    func testPaymentsSavedBeforeStillReadTheirCategory() throws {
        let old = #"[{"id":"6F1C3A4E-1111-4A6B-9C1D-2E3F4A5B6C7D","date":0,"merchant":"Uber","amount":18.4,"currencySymbol":"$","card":"","category":"transport","source":"tap","items":[]}]"#
        let payments = try JSONDecoder().decode([Payment].self, from: Data(old.utf8))
        XCTAssertEqual(payments.first?.category, .transport)
        XCTAssertEqual(payments.first?.category.title, "Transport")
        let again = try JSONDecoder().decode([Payment].self, from: JSONEncoder().encode(payments))
        XCTAssertEqual(again.first?.category, .transport)
    }

    func testAddEditAndRemoveYourOwnCategory() {
        let defaults = fresh()
        let library = CategoryLibrary(defaults: defaults)
        let store = WalletStore(defaults: fresh())
        let pets = library.add(name: "Pets", icon: .emoji("🐶"), hex: "#E08A4F")
        XCTAssertEqual(library.visible.map(\.name).suffix(2), ["Pets", "Other"], "new categories go just before Other")
        XCTAssertEqual(pets.emoji, "🐶")
        XCTAssertNil(pets.asset)

        var info = library.all.first { $0.id == pets.rawValue }!
        info.keywords = ["petco"]
        library.update(info)
        XCTAssertEqual(SpendCategory.guess(merchant: "Petco #212"), pets)

        store.add(merchant: "Petco", amount: 30, category: pets, source: .manual)
        library.remove(pets, in: store)
        XCTAssertEqual(store.transactions.first?.category, .other, "its payments move to Other")
        XCTAssertFalse(library.all.contains { $0.id == pets.rawValue })

        XCTAssertEqual(CategoryLibrary(defaults: defaults).all, library.all, "kept across launches")
    }

    func testBuiltInsCanBeRemovedAndBroughtBackButOtherStays() {
        let library = CategoryLibrary(defaults: fresh())
        let store = WalletStore(defaults: fresh())
        library.remove(.fun, in: store)
        XCTAssertFalse(SpendCategory.allCases.contains(.fun))
        XCTAssertEqual(SpendCategory.guess(merchant: "Netflix"), .other, "a removed category is never guessed")
        library.restore(.fun)
        XCTAssertTrue(SpendCategory.allCases.contains(.fun))
        library.remove(.other, in: store)
        XCTAssertTrue(SpendCategory.allCases.contains(.other))
    }
}

final class PayMethodTests: XCTestCase {
    func testWaysToPayAreRecognisedByName() {
        XCTAssertEqual(PayMethods.info(for: "venmo").name, "Venmo")
        XCTAssertFalse(PayMethods.info(for: "Cash").isCard)
        XCTAssertEqual(PayMethods.info(for: "Chase Sapphire").symbol, PayMethods.info(for: "Credit card").symbol)
        XCTAssertEqual(PayMethods.info(for: "Chase Sapphire").name, "Chase Sapphire")
        XCTAssertEqual(PayMethods.info(for: "Wells Fargo Debit").hex, PayMethods.info(for: "Debit card").hex)
        PayMethods.remember("Grandma's envelope", as: "Cash")
        XCTAssertFalse(PayMethods.info(for: "Grandma's envelope").isCard)
        XCTAssertGreaterThanOrEqual(PayMethods.all.count, 35)
    }
}
