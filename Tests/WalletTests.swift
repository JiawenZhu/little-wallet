import XCTest
@testable import LittleWallet

@MainActor
final class WalletTests: XCTestCase {
    private func freshStore() -> WalletStore {
        let name = "wallet-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return WalletStore(defaults: defaults)
    }

    func testSpreadAlwaysAddsUpAndMatchesTheServer() {
        // Same answers as the server's spread() in little-fridge-split/server/split.js.
        XCTAssertEqual(SplitMath.spread(100, weights: [1, 1, 1]), [34, 33, 33])
        XCTAssertEqual(SplitMath.spread(7, weights: [0, 0]), [7, 0])
        for total in stride(from: 0, to: 500, by: 37) {
            XCTAssertEqual(SplitMath.spread(total, weights: [3, 11, 0, 7]).reduce(0, +), total)
        }
    }

    func testPaymentsAreKeptNewestFirstAndSurviveARestart() {
        let name = "wallet-restart-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = WalletStore(defaults: defaults)
        store.add(merchant: "Uber", amount: 18.4, date: .now.addingTimeInterval(-3600), source: .manual)
        store.add(merchant: "Trader Joe's", amount: 21.65, source: .tap)
        XCTAssertEqual(store.transactions.map(\.merchant), ["Trader Joe's", "Uber"])
        XCTAssertEqual(WalletStore(defaults: defaults).transactions.map(\.merchant), ["Trader Joe's", "Uber"])
    }

    func testCategoriesAreGuessedFromTheShop() {
        XCTAssertEqual(SpendCategory.guess(merchant: "Trader Joe's"), .groceries)
        XCTAssertEqual(SpendCategory.guess(merchant: "Uber"), .transport)
        XCTAssertEqual(SpendCategory.guess(merchant: "Blue Bottle Coffee"), .dining)
        XCTAssertEqual(SpendCategory.guess(merchant: "Netflix"), .fun)
        XCTAssertEqual(SpendCategory.guess(merchant: "Somewhere new"), .other)
        XCTAssertEqual(freshStore().add(merchant: "CVS Pharmacy", amount: 9, source: .manual).category, .health)
    }

    func testAnApplePayTapArrivesByLinkAndProvesTheSetup() {
        let store = freshStore()
        XCTAssertNil(store.lastTapAt)
        let url = URL(string: "littlewallet://pay?merchant=Trader%20Joe%27s&amount=%2431.47&card=Apple%20Card")!
        XCTAssertTrue(store.handleIncomingURL(url))
        let tx = store.transactions.first
        XCTAssertEqual(tx?.merchant, "Trader Joe's")
        XCTAssertEqual(tx?.amount ?? 0, 31.47, accuracy: 0.001)
        XCTAssertEqual(tx?.card, "Apple Card")
        XCTAssertEqual(tx?.source, .tap)
        XCTAssertNotNil(store.lastTapAt)
        XCTAssertFalse(store.handleIncomingURL(URL(string: "littlefridge://applepay?amount=3")!))
    }

    func testAmountsFromShortcutsAreRead() {
        XCTAssertEqual(WalletStore.amount("$31.47"), 31.47, accuracy: 0.001)
        XCTAssertEqual(WalletStore.amount("31,47"), 31.47, accuracy: 0.001)
        XCTAssertEqual(WalletStore.amount("USD 8"), 8, accuracy: 0.001)
        XCTAssertEqual(WalletStore.amount("$1,234.56"), 1234.56, accuracy: 0.001, "thousands, US style")
        XCTAssertEqual(WalletStore.amount("1.234,56 €"), 1234.56, accuracy: 0.001, "thousands, European style")
        XCTAssertEqual(WalletStore.amount("$2,500"), 2500, accuracy: 0.001, "a comma before three digits is thousands")
        XCTAssertEqual(WalletStore.amount("$13"), 13, accuracy: 0.001)
        XCTAssertEqual(WalletStore.amount("$0.5"), 0.5, accuracy: 0.001)
        XCTAssertEqual(WalletStore.amount(""), 0, accuracy: 0.001)
    }

    func testAmountsAreFormattedWhileTyping() {
        XCTAssertEqual(WalletStore.typing("10000000"), "1,000,000", "seven digits at most")
        XCTAssertEqual(WalletStore.typing("1234"), "1,234")
        XCTAssertEqual(WalletStore.typing("1,2345"), "12,345", "commas are put back where they belong")
        XCTAssertEqual(WalletStore.typing("12.3456"), "12.34", "two decimals at most")
        XCTAssertEqual(WalletStore.typing("12."), "12.", "a point stays while you type the cents")
        XCTAssertEqual(WalletStore.typing("1.2.3"), "1.23", "one decimal point")
        XCTAssertEqual(WalletStore.typing("0007"), "7")
        XCTAssertEqual(WalletStore.typing(".5"), "0.5")
        XCTAssertEqual(WalletStore.typing("0"), "0")
        XCTAssertEqual(WalletStore.typing(""), "")
        XCTAssertEqual(WalletStore.amount(WalletStore.typing("9999999.99")), 9_999_999.99, accuracy: 0.001)
    }

    func testOneTapTwiceIsOnePayment() {
        let store = freshStore()
        let first = store.add(merchant: "Trader Joe's", amount: 21.65, card: "Apple Card", source: .tap)
        let again = store.add(merchant: "trader joe's", amount: 21.65, card: "Apple Card", source: .tap)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(store.transactions.count, 1)
        store.add(merchant: "Trader Joe's", amount: 4.99, source: .tap)
        XCTAssertEqual(store.transactions.count, 2, "a different amount is a different payment")
        store.add(merchant: "Trader Joe's", amount: 21.65, source: .manual)
        XCTAssertEqual(store.transactions.count, 3, "typed payments are never merged")
    }

    func testATapWithoutAnAmountIsStillSaved() {
        let store = freshStore()
        let tx = store.add(merchant: "", amount: WalletStore.amount(""), card: "Chase Freedom", source: .tap)
        XCTAssertEqual(tx.merchant, "Apple Pay")
        XCTAssertEqual(tx.cents, 0)
        XCTAssertNotNil(store.lastTapAt)
    }

    func testTheShortcutsActionSavesAPayment() async throws {
        let before = WalletStore.shared.transactions.count
        var intent = LogPaymentIntent()
        intent.merchant = "Blue Bottle Coffee"
        intent.amount = "$1,006.75"
        intent.card = "Apple Card"
        _ = try await intent.perform()
        let saved = WalletStore.shared.transactions.first { $0.merchant == "Blue Bottle Coffee" && $0.cents == 100675 }
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.source, .tap)
        XCTAssertEqual(saved?.category, .dining)
        XCTAssertEqual(WalletStore.shared.transactions.count, before + 1)
        if let saved { WalletStore.shared.delete(saved.id) }
    }

    func testAPaymentWithoutItemsSplitsAsOneLine() {
        let tx = freshStore().add(merchant: "Sushi Ran", amount: 86, source: .voice)
        XCTAssertEqual(tx.splitLines.count, 1)
        XCTAssertEqual(tx.splitLines[0].id, tx.id, "the whole payment is one stable line")
        XCTAssertEqual(tx.splitLines[0].price ?? 0, 86, accuracy: 0.001)
    }

    func testUnpricedItemsShareWhatIsLeft() {
        let tx = freshStore().add(merchant: "Costco", amount: 30, source: .manual, items: [
            LineItem(name: "Salmon", price: 18), LineItem(name: "Eggs"), LineItem(name: "Bread", quantity: 2),
        ])
        let prices = tx.splitLines.map { $0.price ?? 0 }
        XCTAssertEqual(prices[0], 18, accuracy: 0.001)
        XCTAssertEqual(prices[1], 4, accuracy: 0.001, "$12 left over three copies")
        XCTAssertEqual(prices[2], 8, accuracy: 0.001)
    }

    func testMoneyPaidBackComesOffWhatYouSpent() {
        let tx = freshStore().add(merchant: "Groceries", amount: 158, source: .manual)
        let sam = SplitPerson(id: "f1", name: "Sam", colorIndex: 1), eva = SplitPerson(id: "f2", name: "Eva", colorIndex: 2)
        let split = SentSplit(id: "s1", title: "Groceries", method: "Card", createdAt: .now, total: "158.00", itemIDs: [tx.id],
                              people: [sam, eva], shares: [
                                "f1": SplitShare(name: "Sam", total: "52.67", status: "sent", link: ""),
                                "f2": SplitShare(name: "Eva", total: "52.66", status: "paid", link: ""),
                              ])
        let service = SplitService(defaults: UserDefaults(suiteName: "net-\(UUID().uuidString)")!)
        service.adopt(split)
        let netted = service.netted([tx])[0]
        XCTAssertEqual(netted.paidBack ?? 0, 52.66, accuracy: 0.001, "only Eva has paid")
        XCTAssertEqual(netted.spent, 105.34, accuracy: 0.001)
        XCTAssertEqual(service.netted([freshStore().add(merchant: "Uber", amount: 18, source: .tap)])[0].paidBack, nil)
    }

    func testVenmoSplitsStayOnThePhoneWithEachExactShare() async {
        let service = SplitService(defaults: UserDefaults(suiteName: "venmo-\(UUID().uuidString)")!)
        let me = SplitPerson(id: "me", name: "Evan", colorIndex: 0, isMe: true)
        let sam = SplitPerson(id: "f1", name: "Sam", colorIndex: 1), eva = SplitPerson(id: "f2", name: "Eva", colorIndex: 2)
        let split = service.recordVenmo(title: "Groceries", method: "Apple Pay", people: [me, sam, eva], itemIDs: [UUID()],
                                        emojis: "🛒", totals: ["me": 1000, "f1": 1250, "f2": 750])
        XCTAssertTrue(split.id.hasPrefix(SplitService.venmoPrefix))
        XCTAssertEqual(split.shares["f1"]?.total, "12.50", "each friend gets their own amount")
        XCTAssertEqual(split.shares["f2"]?.total, "7.50")
        XCTAssertNil(split.shares["me"], "you're never asked to pay yourself")
        service.markRequested(split: split.id, person: "f1")
        XCTAssertEqual(service.splits.first?.shares["f1"]?.status, "requested")
        service.markPaidByHand(split: split.id, person: "f1", via: "Venmo")
        let refreshed = await service.refresh(split.id)
        XCTAssertEqual(refreshed?.shares["f1"]?.status, "paid", "no server to undo it")
        XCTAssertEqual(SettleBalance.from(service.splits).first { $0.person.id == "f2" }?.owed, 750)
        XCTAssertEqual(Venmo.note(title: "Groceries", emojis: "🛒"), "🛒 Groceries split · Little Wallet 👛")
    }

    func testVenmoProfileLinksGiveTheUsername() {
        XCTAssertEqual(Venmo.username(fromLink: "https://venmo.com/u/Jing-Allen"), "Jing-Allen")
        XCTAssertEqual(Venmo.username(fromLink: "https://account.venmo.com/u/simon-Luo-1?ref=share"), "simon-Luo-1")
        XCTAssertEqual(Venmo.username(fromLink: "Check me out on Venmo! https://venmo.com/Andrew-Kim-180"), "Andrew-Kim-180")
        XCTAssertNil(Venmo.username(fromLink: "https://venmo.com/code?user_id=123"), "a QR code link has no username")
        XCTAssertEqual(Venmo.recipient("https://venmo.com/u/Jing-Allen"), "Jing-Allen")
        XCTAssertEqual(Venmo.recipient("(312) 555-0199"), "3125550199", "a contact's phone works as a Venmo recipient")
    }

    func testSettingALinePriceWhileSplitting() {
        let store = freshStore()
        let tx = store.add(merchant: "Target", amount: 20, source: .manual, items: [LineItem(name: "Socks")])
        store.setPrice(7.5, line: tx.items[0].id, in: tx.id)
        XCTAssertEqual(store.transaction(tx.id)?.items[0].price ?? 0, 7.5, accuracy: 0.001)
        let whole = store.add(merchant: "Uber", amount: 18, source: .tap)
        store.setPrice(19.25, line: whole.id, in: whole.id)
        XCTAssertEqual(store.transaction(whole.id)?.amount ?? 0, 19.25, accuracy: 0.001, "a one-line payment changes its amount")
    }
}
