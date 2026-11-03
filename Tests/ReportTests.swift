import XCTest
@testable import LittleWallet

final class ReportTests: XCTestCase {
    private func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T12:00:00Z")! }

    func testReportKeepsOnlyItsDatesAndCategories() {
        let payments = [
            Payment(date: day("2026-10-02"), merchant: "Menards", amount: 31.32, card: "Chase Visa", category: .shopping),
            Payment(date: day("2026-10-20"), merchant: "Trader Joe's", amount: 21.65, category: .groceries),
            Payment(date: day("2026-11-01"), merchant: "Uber", amount: 18.40, category: .transport),
            Payment(date: day("2026-10-21"), merchant: "Apple Pay", amount: 0, category: .other),
        ]
        let report = ExpenseReport(payments: payments, start: day("2026-10-01"), end: day("2026-10-31"),
                                   categories: [.shopping, .groceries, .transport])
        XCTAssertEqual(report.payments.map(\.merchant), ["Trader Joe's", "Menards"])
        XCTAssertEqual(report.total, 52.97, accuracy: 0.001)
        XCTAssertEqual(report.groups.map(\.category), [.shopping, .groceries])
    }

    func testYourShareTakesOffWhatFriendsPaidBack() {
        var dinner = Payment(date: day("2026-10-05"), merchant: "Golden Dragon", amount: 61.92, category: .dining)
        dinner.paidBack = 41.28
        let report = ExpenseReport(payments: [dinner], start: day("2026-10-01"), end: day("2026-10-31"), yourShare: true)
        XCTAssertEqual(report.total, 20.64, accuracy: 0.001)
        XCTAssertEqual(report.paidBack, 41.28, accuracy: 0.001)
    }

    func testCSVQuotesCommasAndDefusesFormulas() {
        let csv = ExpenseReport.join([["Name", "Note"], ["Joe's, Inc", "=HYPERLINK(\"x\")"], ["Plain", "-4.00"]])
        XCTAssertEqual(csv, "Name,Note\r\n\"Joe's, Inc\",\"'=HYPERLINK(\"\"x\"\")\"\r\nPlain,-4.00\r\n")
    }

    @MainActor
    func testPDFHasSummaryTableAndReceiptPages() throws {
        let payments = (0..<25).map { Payment(date: day("2026-10-01").addingTimeInterval(Double($0) * 3600), merchant: "Shop \($0)", amount: 10, category: .shopping) }
        let report = ExpenseReport(payments: payments, start: day("2026-10-01"), end: day("2026-10-31"))
        XCTAssertEqual(ReportPDF(report: report).pages().count, 3)
        let url = try report.file(.pdf)
        let document = CGPDFDocument(url as CFURL)
        XCTAssertEqual(document?.numberOfPages, 3)
    }
}
