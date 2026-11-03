import SwiftUI
import UIKit

/// Which payments a report covers.
enum ReportRange: Hashable, CaseIterable, Identifiable {
    case thisMonth, lastMonth, threeMonths, thisYear, custom
    var id: Self { self }

    var title: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .threeMonths: return "3 months"
        case .thisYear: return "This year"
        case .custom: return "Custom"
        }
    }

    /// The first and last day it covers, or nil for custom dates.
    func days(now: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let month = calendar.dateInterval(of: .month, for: now)!
        switch self {
        case .thisMonth: return (month.start, now)
        case .lastMonth:
            let last = calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: -1, to: now)!)!
            return (last.start, last.end.addingTimeInterval(-1))
        case .threeMonths: return (calendar.date(byAdding: .month, value: -2, to: month.start)!, now)
        case .thisYear: return (calendar.dateInterval(of: .year, for: now)!.start, now)
        case .custom: return nil
        }
    }
}

enum ReportFormat: String, CaseIterable, Identifiable {
    case pdf, csv, itemsCSV
    var id: Self { self }

    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .csv: return "CSV"
        case .itemsCSV: return "Items CSV"
        }
    }

    var detail: String {
        switch self {
        case .pdf: return "Summary, every payment and receipt photos"
        case .csv: return "One row per payment, for Numbers or Excel"
        case .itemsCSV: return "One row per thing bought"
        }
    }
}

/// An expense report: the payments in a date range, totalled by category and card, ready to save as PDF or CSV.
struct ExpenseReport {
    struct Group: Identifiable {
        var category: SpendCategory
        var count: Int
        var total: Double
        var id: SpendCategory { category }
    }

    var start: Date
    var end: Date
    /// Newest first, with what friends paid back filled in.
    var payments: [Payment]
    /// Count only what was really yours, after friends paid back.
    var yourShare = false
    var withPhotos = true
    var made: Date = .now

    init(payments all: [Payment], start: Date, end: Date, categories: Set<SpendCategory> = Set(SpendCategory.allCases),
         yourShare: Bool = false, withPhotos: Bool = true) {
        let calendar = Calendar.current
        self.start = calendar.startOfDay(for: start)
        self.end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
        let from = self.start, to = self.end
        payments = all.filter { $0.date >= from && $0.date <= to && categories.contains($0.category) && $0.cents > 0 }
            .sorted { $0.date > $1.date }
        self.yourShare = yourShare
        self.withPhotos = withPhotos
    }

    func amount(_ payment: Payment) -> Double { yourShare ? payment.spent : payment.amount }
    var total: Double { payments.reduce(0) { $0 + amount($1) } }
    var paidBack: Double { payments.reduce(0) { $0 + ($1.paidBack ?? 0) } }
    var withReceipts: [Payment] { payments.filter { ReceiptVault.has($0.id) } }

    var groups: [Group] {
        Dictionary(grouping: payments, by: \.category)
            .map { Group(category: $0.key, count: $0.value.count, total: $0.value.reduce(0) { $0 + amount($1) }) }
            .sorted { $0.total > $1.total }
    }

    var cards: [(name: String, total: Double)] {
        Dictionary(grouping: payments) { $0.card.isEmpty ? "Not recorded" : $0.card }
            .map { ($0.key, $0.value.reduce(0) { $0 + amount($1) }) }
            .sorted { $0.1 > $1.1 }
    }

    var rangeText: String {
        let sameYear = Calendar.current.isDate(start, equalTo: end, toGranularity: .year)
        let first = sameYear ? start.formatted(.dateTime.month(.abbreviated).day()) : start.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(first) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    /// "Little Wallet Oct 1 – Oct 31, 2026"
    var fileName: String {
        "Little Wallet \(rangeText)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ",", with: "")
    }

    // MARK: - CSV

    func csv() -> String {
        var rows = [["Date", "Time", "Merchant", "Category", "Amount", "Paid back", "Your share", "Card", "Added by", "Items", "Note", "Receipt"]]
        for p in payments {
            rows.append([
                p.date.formatted(.iso8601.year().month().day()),
                p.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)),
                p.merchant, p.category.title,
                Self.plain(p.amount), Self.plain(p.paidBack ?? 0), Self.plain(p.spent),
                p.card, p.source.label,
                p.items.map { $0.quantity > 1 ? "\($0.name) x\($0.quantity)" : $0.name }.joined(separator: "; "),
                p.note ?? "",
                ReceiptVault.has(p.id) ? "Yes" : "",
            ])
        }
        return Self.join(rows)
    }

    func itemsCSV() -> String {
        var rows = [["Date", "Merchant", "Category", "Item", "Quantity", "Price", "Payment total", "Card"]]
        for p in payments {
            for line in p.splitLines {
                rows.append([p.date.formatted(.iso8601.year().month().day()), p.merchant, p.category.title, line.name,
                             String(max(1, line.quantity)), Self.plain(line.price ?? 0), Self.plain(p.amount), p.card])
            }
        }
        return Self.join(rows)
    }

    /// "1234.50": no currency sign or grouping, so spreadsheets read it as a number.
    static func plain(_ amount: Double) -> String { String(format: "%.2f", amount) }

    static func join(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                // Quote anything with a comma, quote or line break; a leading = + - @ could run as a formula.
                var cell = cell
                if let first = cell.first, "=+-@".contains(first), Double(cell) == nil { cell = "'" + cell }
                return cell.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Files

    /// Writes the report to a file ready to share.
    @MainActor
    func file(_ format: ReportFormat) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Reports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch format {
        case .csv:
            let url = folder.appending(path: "\(fileName).csv")
            try Data(csv().utf8).write(to: url, options: .atomic)
            return url
        case .itemsCSV:
            let url = folder.appending(path: "\(fileName) Items.csv")
            try Data(itemsCSV().utf8).write(to: url, options: .atomic)
            return url
        case .pdf:
            let url = folder.appending(path: "\(fileName).pdf")
            try ReportPDF(report: self).write(to: url)
            return url
        }
    }
}

// MARK: - PDF

/// The report as US Letter pages: a summary, every payment in a table, then the receipt photos two to a page.
@MainActor
struct ReportPDF {
    let report: ExpenseReport
    static let size = CGSize(width: 612, height: 792)
    static let rowsPerPage = 19

    var paymentPages: [[Payment]] {
        stride(from: 0, to: report.payments.count, by: Self.rowsPerPage).map {
            Array(report.payments[$0..<min($0 + Self.rowsPerPage, report.payments.count)])
        }
    }

    var receiptPages: [[Payment]] {
        guard report.withPhotos else { return [] }
        let kept = report.withReceipts
        return stride(from: 0, to: kept.count, by: 2).map { Array(kept[$0..<min($0 + 2, kept.count)]) }
    }

    /// Which page each payment's receipt photo is on, so the table can point to it.
    var receiptPage: [UUID: Int] {
        var pages: [UUID: Int] = [:]
        let first = 2 + paymentPages.count
        for (index, page) in receiptPages.enumerated() { for p in page { pages[p.id] = first + index } }
        return pages
    }

    func pages() -> [AnyView] {
        let tables = paymentPages, photos = receiptPages
        let count = 1 + tables.count + photos.count
        var pages: [AnyView] = [AnyView(ReportSummaryPage(report: report))]
        let links = receiptPage
        pages += tables.enumerated().map { index, rows in
            AnyView(ReportTablePage(report: report, rows: rows, first: index == 0, links: links))
        }
        pages += photos.map { AnyView(ReportReceiptPage(report: report, payments: $0)) }
        return pages.enumerated().map { index, page in
            AnyView(ReportPage(report: report, number: index + 1, of: count) { page })
        }
    }

    func write(to url: URL) throws {
        var box = CGRect(origin: .zero, size: Self.size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [
            kCGPDFContextTitle: report.fileName, kCGPDFContextCreator: "Little Wallet",
        ] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        for page in pages() {
            let renderer = ImageRenderer(content: page.frame(width: Self.size.width, height: Self.size.height))
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}

/// Paper, a header with the wallet's mark and a footer with the page number.
private struct ReportPage<Content: View>: View {
    let report: ExpenseReport
    let number: Int
    let of: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("WalletMark").resizable().scaledToFit().frame(width: 22, height: 22)
                Text("Little Wallet").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
                Spacer()
                Text("Expense report · \(report.rangeText)").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .padding(.bottom, 10)
            Rectangle().fill(Theme.accent).frame(height: 2)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 18)
            Rectangle().fill(Theme.line).frame(height: 0.5)
            HStack {
                Text("Made with Little Wallet on \(report.made.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Text("Page \(number) of \(of)")
            }
            .font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.secondary).padding(.top, 8)
        }
        .padding(.horizontal, 42).padding(.top, 36).padding(.bottom, 28)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

private struct ReportSummaryPage: View {
    let report: ExpenseReport

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expense Report").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.ink)
                    Text(report.rangeText).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(dollars(report.total)).font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(report.yourShare ? "Your share, after friends paid back" : "Total spent")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            HStack(spacing: 10) {
                stat("Payments", "\(report.payments.count)")
                stat("Receipts attached", "\(report.withReceipts.count)")
                stat("Paid back by friends", dollars(report.paidBack))
                stat("Average payment", dollars(report.payments.isEmpty ? 0 : report.total / Double(report.payments.count)))
            }
            table("Category", report.groups.map { group in
                (AnyView(HStack(spacing: 8) {
                    CategoryIcon(category: group.category, size: 18)
                    Text(group.category.title)
                }), group.count, group.total)
            })
            if report.cards.count > 1 || report.cards.first?.name != "Not recorded" {
                table("Paid with", report.cards.prefix(6).map { card in
                    (AnyView(HStack(spacing: 8) {
                        Image(systemName: PayMethods.info(for: card.name).symbol).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        Text(card.name)
                    }), report.payments.filter { ($0.card.isEmpty ? "Not recorded" : $0.card) == card.name }.count, card.total)
                })
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 7.5, weight: .bold)).kerning(0.4).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func table(_ title: String, _ rows: [(AnyView, Int, Double)]) -> some View {
        let total = max(report.total, 0.01)
        return VStack(spacing: 0) {
            HStack {
                Text(title.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
                Text("PAYMENTS").frame(width: 70, alignment: .trailing)
                Text("SHARE").frame(width: 120, alignment: .leading).padding(.leading, 16)
                Text("TOTAL").frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .bold)).kerning(0.4).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.background)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    row.0.frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.1)").monospacedDigit().frame(width: 70, alignment: .trailing)
                    GeometryReader { geo in
                        Capsule().fill(Theme.softGreen).overlay(alignment: .leading) {
                            Capsule().fill(Theme.accent).frame(width: max(3, geo.size.width * row.2 / total))
                        }
                    }
                    .frame(width: 84, height: 5).padding(.leading, 16)
                    Text("\(Int((row.2 / total * 100).rounded()))%").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Text(dollars(row.2)).monospacedDigit().fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 11)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 7)
                Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 0.5)
            }
            HStack {
                Text("TOTAL").fontWeight(.heavy)
                Spacer()
                Text(dollars(report.total)).monospacedDigit().fontWeight(.heavy)
            }
            .font(.system(size: 12)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Theme.accent)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

private struct ReportTablePage: View {
    let report: ExpenseReport
    let rows: [Payment]
    let first: Bool
    let links: [UUID: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(first ? "Every payment" : "Every payment, continued")
                .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(Theme.ink)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("DATE").frame(width: 52, alignment: .leading)
                    Text("MERCHANT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CATEGORY").frame(width: 70, alignment: .leading)
                    Text("CARD").frame(width: 72, alignment: .leading)
                    Text("RECEIPT").frame(width: 42, alignment: .center)
                    Text(report.yourShare ? "YOUR SHARE" : "AMOUNT").frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 7.5, weight: .bold)).kerning(0.3).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Theme.background)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, p in
                    HStack(spacing: 8) {
                        Text(p.date.formatted(.dateTime.month(.abbreviated).day())).frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.merchant).fontWeight(.semibold).lineLimit(1)
                            if !p.items.isEmpty {
                                Text(p.items.map(\.name).joined(separator: ", ")).font(.system(size: 7.5))
                                    .foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(p.category.title).frame(width: 70, alignment: .leading).lineLimit(1)
                        Text(p.card.isEmpty ? "—" : p.card).frame(width: 72, alignment: .leading).lineLimit(1)
                        Group {
                            if let page = links[p.id] { Text("p. \(page)").foregroundStyle(Theme.accent).fontWeight(.semibold) }
                            else if ReceiptVault.has(p.id) { Image(systemName: "paperclip") }
                            else { Text("") }
                        }
                        .frame(width: 42, alignment: .center)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(dollars(report.amount(p))).fontWeight(.semibold).monospacedDigit()
                            if report.yourShare, let back = p.paidBack, back > 0 {
                                Text(dollars(p.amount)).font(.system(size: 7)).strikethrough().foregroundStyle(Theme.secondary)
                            }
                        }
                        .frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 9)).foregroundStyle(Theme.ink)
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .background(index.isMultiple(of: 2) ? Color.white : Theme.background.opacity(0.45))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        }
    }
}

private struct ReportReceiptPage: View {
    let report: ExpenseReport
    let payments: [Payment]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receipts").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(Theme.ink)
            HStack(alignment: .top, spacing: 20) {
                ForEach(payments) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        if let image = ReceiptVault.image(p.id) {
                            Image(uiImage: image.shrunk(to: 1400)).resizable().scaledToFit()
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 0.5))
                                .frame(maxWidth: .infinity, maxHeight: 540, alignment: .top)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.merchant).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                                Text("\(p.date.formatted(date: .abbreviated, time: .shortened)) · \(p.category.title)")
                                    .font(.system(size: 8.5)).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Text(dollars(p.amount)).font(.system(size: 12, weight: .heavy, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                if payments.count == 1 { Color.clear.frame(maxWidth: .infinity) }
            }
        }
    }
}
