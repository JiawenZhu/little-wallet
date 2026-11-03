import Foundation
import OSLog
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A receipt, read: the shop, each thing on it with its price, and what was paid in the end.
struct ReceiptScan: Equatable {
    struct Line: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var quantity: Int = 1
        /// The whole line, in cents.
        var cents: Int

        static func == (a: Line, b: Line) -> Bool { a.name == b.name && a.quantity == b.quantity && a.cents == b.cents }
    }

    var merchant = ""
    var date: Date?
    var lines: [Line] = []
    var subtotalCents = 0
    var taxCents = 0
    var tipCents = 0
    /// What was paid, tax and tip included.
    var totalCents = 0

    var itemsCents: Int { lines.reduce(0) { $0 + $1.cents } }
    /// Tax, tip and anything else on top of the items.
    var extrasCents: Int { max(0, totalCents - itemsCents) }
    var isEmpty: Bool { lines.isEmpty && totalCents == 0 }

    /// "Tax", "Tip", "Tax & tip": whatever the receipt said was added on top.
    var extrasLabel: String {
        switch (taxCents > 0, tipCents > 0) {
        case (true, true): return "Tax & tip"
        case (true, false): return "Tax"
        case (false, true): return "Tip"
        default: return "Tax & fees"
        }
    }
}

/// Where a piece of text sat on the photo, so the scan can light up what it read.
struct ReceiptMark: Equatable {
    enum Kind { case item, total, other }
    /// Normalized, top-left origin.
    var rect: CGRect
    var kind: Kind
}

/// Reads a receipt photo or screenshot on the phone: Vision finds the text, `ReceiptParser` lines names up with
/// prices, and Apple's on-device model steps in when the prices don't add up.
enum ReceiptReader {
    enum Engine: Equatable { case appleIntelligence, parser }

    static func scan(_ image: UIImage) async -> (ReceiptScan, [ReceiptMark], Engine) {
        let rows = await recognize(image)
        var scan = ReceiptParser.parse(rows.map(\.text))
        let marks = rows.map { row -> ReceiptMark in
            ReceiptMark(rect: row.rect, kind: ReceiptParser.kind(of: row.text))
        }
        if ReceiptParser.addsUp(scan) { return (ReceiptParser.unpacked(scan), marks, .parser) }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let model = await LocalReceiptModel.read(rows.map(\.text)) {
            // The model may only use prices printed on the receipt, and its items must add up better.
            let printed = Set(rows.flatMap { ReceiptParser.amounts(in: $0.text) })
            let honest = !model.lines.isEmpty && model.lines.allSatisfy { printed.contains($0.cents) || printed.contains($0.cents / max(1, $0.quantity)) }
            var better = model
            better.subtotalCents = scan.subtotalCents
            better.taxCents = scan.taxCents
            better.tipCents = scan.tipCents
            better.totalCents = scan.totalCents
            better.date = scan.date
            if better.merchant.isEmpty { better.merchant = scan.merchant }
            if honest && (ReceiptParser.addsUp(better) || scan.lines.isEmpty) {
                return (ReceiptParser.unpacked(better), marks, .appleIntelligence)
            }
            if scan.merchant.isEmpty { scan.merchant = model.merchant }
        }
        #endif
        return (ReceiptParser.unpacked(scan), marks, .parser)
    }

    /// The receipt's text, one string per printed row, top to bottom.
    static func recognize(_ image: UIImage) async -> [(text: String, rect: CGRect)] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                try? handler.perform([request])
                let pieces = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let box = observation.boundingBox
                    return (text, CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
                }
                continuation.resume(returning: rows(from: pieces))
            }
        }
    }

    /// Joins pieces of text that sit on one printed line: a name on the left, its price on the right.
    static func rows(from pieces: [(String, CGRect)]) -> [(text: String, rect: CGRect)] {
        var rows: [[(String, CGRect)]] = []
        for piece in pieces.sorted(by: { $0.1.midY < $1.1.midY }) {
            if let last = rows.indices.last, let anchor = rows[last].first?.1,
               abs(piece.1.midY - anchor.midY) < min(piece.1.height, anchor.height) * 0.55 {
                rows[last].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.1.minX < $1.1.minX }
            return (sorted.map(\.0).joined(separator: "  "), sorted.map(\.1).reduce(sorted[0].1) { $0.union($1) })
        }
    }
}

/// Reads receipt text with plain rules: rows ending in a price are things bought until the subtotal; tax, tip and
/// total rows are kept apart; payment and change rows are ignored.
enum ReceiptParser {
    static func parse(_ rows: [String]) -> ReceiptScan {
        var scan = ReceiptScan()
        var pendingName: String?
        var pendingCount: (count: Int, unit: Int)?
        var totals: [Int] = []
        var finished = false
        var merchantRow: Int?

        for (index, raw) in rows.enumerated() {
            let row = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !row.isEmpty else { continue }
            let lower = row.lowercased()
            if scan.date == nil, let date = date(in: row) { scan.date = date }
            let price = trailingPrice(in: row)

            switch kind(of: row) {
            case .total where price != nil:
                let cents = price!.cents
                if lower.contains("sub") { scan.subtotalCents = cents }
                else if isTax(lower) { scan.taxCents += cents }
                else if isTip(lower) { scan.tipCents += cents }
                else { totals.append(cents); finished = true }
                pendingName = nil
                continue
            case .other where price != nil:
                // Payment, change, savings: never a thing bought. A discount comes off the item above it.
                if isDiscount(lower), price!.negative || lower.contains("-"), let last = scan.lines.indices.last {
                    scan.lines[last].cents = max(0, scan.lines[last].cents - price!.cents)
                }
                pendingName = nil
                continue
            default: break
            }

            if let price {
                guard !finished else { continue }
                if price.negative {
                    if let last = scan.lines.indices.last { scan.lines[last].cents = max(0, scan.lines[last].cents - price.cents) }
                    continue
                }
                // "1581460   2 @9.99" under "K-SNAP OUTLET  19.98": how many of the thing above were bought.
                if let (count, unit) = countAtPrice(row), cleanName(price.rest).0 == nil {
                    if let last = scan.lines.indices.last, abs(scan.lines[last].cents - count * unit) <= 1 {
                        scan.lines[last].quantity = count
                    } else {
                        pendingCount = (count, unit)
                    }
                    continue
                }
                var (name, quantity) = cleanName(price.rest)
                // Printed above its line instead: "2 @ 9.99" then "OUTLET  19.98".
                if let pending = pendingCount, abs(price.cents - pending.count * pending.unit) <= 1 { quantity = pending.count }
                pendingCount = nil
                // "2.34 lb @ 0.59/lb  1.38" or a lone price belongs to the name on the row above.
                if let pending = pendingName, name == nil || isWeightLine(price.rest) {
                    name = pending
                    if let count = leadingCount(price.rest) { quantity = count }
                }
                pendingName = nil
                guard let name, price.cents > 0 else { continue }
                scan.lines.append(.init(name: name, quantity: quantity, cents: price.cents))
            } else if !finished {
                let (name, _) = cleanName(row)
                if merchantRow == nil, scan.lines.isEmpty, index < 8, let name, looksLikeShop(row) {
                    scan.merchant = name
                    merchantRow = index
                } else if !scan.lines.isEmpty || merchantRow != nil, let name, !isHeader(lower) {
                    pendingName = name
                }
            }
        }

        if let known = knownShop(in: rows) { scan.merchant = known }
        let extras = scan.taxCents + scan.tipCents
        if let total = totals.max() {
            scan.totalCents = total
        } else if scan.subtotalCents > 0 {
            scan.totalCents = scan.subtotalCents + extras
        } else {
            scan.totalCents = scan.itemsCents + extras
        }
        // A total smaller than the items means a line was misread as an item; trust the total.
        return scan
    }

    /// One line per thing bought, so "2 × Outlet  19.98" becomes two 9.99 outlets that two people can each claim.
    /// Big counts, like 24 cans, stay as one line.
    static func unpacked(_ scan: ReceiptScan) -> ReceiptScan {
        var unpacked = scan
        unpacked.lines = scan.lines.flatMap { line -> [ReceiptScan.Line] in
            guard (2...10).contains(line.quantity) else { return [line] }
            let each = line.cents / line.quantity, extra = line.cents % line.quantity
            return (0..<line.quantity).map { i in .init(name: line.name, quantity: 1, cents: each + (i < extra ? 1 : 0)) }
        }
        return unpacked
    }

    /// "2 @9.99", "2 @ $9.99 ea", "3 X 1.50": how many and the price of one, in cents.
    static func countAtPrice(_ row: String) -> (count: Int, unit: Int)? {
        guard let match = row.firstMatch(of: #/\b(\d{1,2})\s*(?:@|[xX]\s)\s*\$?(\d{1,4})[.,](\d{2})/#),
              let count = Int(match.1), count > 1, let dollars = Int(match.2), let cents = Int(match.3) else { return nil }
        return (count, dollars * 100 + cents)
    }

    /// Whether the items match the subtotal, or the total less tax and tip, to the cent.
    static func addsUp(_ scan: ReceiptScan) -> Bool {
        guard !scan.lines.isEmpty else { return false }
        if scan.subtotalCents > 0 { return scan.itemsCents == scan.subtotalCents }
        return scan.itemsCents + scan.taxCents + scan.tipCents == scan.totalCents
    }

    static func kind(of row: String) -> ReceiptMark.Kind {
        let lower = row.lowercased()
        if lower.contains("total") && !lower.contains("saving") && !lower.contains("items") && !lower.contains("discount")
            || lower.contains("amount due") || lower.contains("balance due") || isTax(lower) || isTip(lower) {
            return .total
        }
        let ignored = ["visa", "mastercard", "master card", "amex", "american express", "discover", "debit", "credit", "cash",
                       "change", "tender", "card #", "card no", "auth", "approval", "approved", "payment", "balance", "loyalty",
                       "points", "you saved", "saving", "item count", "items sold", "# of items", "apple pay", "chip", "contactless",
                       "ref #", "trans", "invoice", "order #", "table", "server", "guest", "check #"]
        // Whole words only, so "Cashews" stays a thing bought.
        let hit = ignored.contains { word in
            word.allSatisfy(\.isLetter) ? lower.range(of: "\\b\(word)\\b", options: .regularExpression) != nil : lower.contains(word)
        }
        if isDiscount(lower) || hit { return .other }
        return trailingPrice(in: row) != nil ? .item : .other
    }

    /// Every amount of money printed in a row, in cents.
    static func amounts(in row: String) -> [Int] {
        row.matches(of: #/(\d{1,3}(?:,\d{3})+|\d+)[.,](\d{2})(?!\d)/#).compactMap { match in
            guard let dollars = Int(match.1.replacingOccurrences(of: ",", with: "")), let cents = Int(match.2) else { return nil }
            return dollars * 100 + cents
        }
    }

    // MARK: - Pieces

    /// The price a row ends with ("4.99", "$12.50 T", "1.00-") and the words before it.
    static func trailingPrice(in row: String) -> (cents: Int, negative: Bool, rest: String)? {
        guard let match = row.firstMatch(of: #/(-)?\s?\$?\s?(\d{1,3}(?:,\d{3})+|\d{1,5})[.,](\d{2})\s?(-)?\s?(?:[A-Za-z]{1,2}|\*)?\s*$/#),
              let dollars = Int(match.2.replacingOccurrences(of: ",", with: "")), let cents = Int(match.3) else { return nil }
        let rest = String(row[row.startIndex..<match.range.lowerBound])
        return (dollars * 100 + cents, match.1 != nil || match.4 != nil, rest)
    }

    /// A tidy item name from a receipt row, and how many were bought: "2 X ORG BANANAS 4011" is ("Org Bananas", 2).
    static func cleanName(_ text: String) -> (String?, Int) {
        var rest = text
        var quantity = 1
        if let match = rest.firstMatch(of: #/^\s*(\d{1,2})\s*(?:[xX@]|(?i:qty|ea))\s*/#), let count = Int(match.1), count > 0 {
            quantity = count
            rest.replaceSubrange(match.range, with: "")
        } else if let match = rest.firstMatch(of: #/(\d{1,2})\s*@\s*\$?\d+[.,]\d{2}/#), let count = Int(match.1), count > 0 {
            quantity = count
            rest.replaceSubrange(match.range, with: " ")
        }
        // Drop codes, stray prices and symbols: SKUs, "@ 3.99", "$".
        rest = rest.replacing(#/\$?\d+[.,]\d{2}/#, with: " ")
        rest = rest.replacing(#/\b\d{4,}\b/#, with: " ")
        rest = rest.replacing(#/[@$#*=_|:]/#, with: " ")
        let words = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { word in word.contains(where: \.isLetter) || word.count <= 3 && Int(word) != nil }
        let joined = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -.,"))
        guard joined.filter(\.isLetter).count >= 2 else { return (nil, quantity) }
        return (pretty(joined), quantity)
    }

    /// "ORGANIC BANANAS" → "Organic Bananas"; names already in mixed case stay as they are.
    static func pretty(_ name: String) -> String {
        guard name == name.uppercased() else { return name }
        return name.lowercased().split(separator: " ").map { word in
            word.count <= 2 && !["oz", "lb", "ct", "pk"].contains(word) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func isTax(_ lower: String) -> Bool {
        lower.range(of: #"\b(tax|hst|gst|pst|vat)\b"#, options: .regularExpression) != nil
    }

    private static func isTip(_ lower: String) -> Bool {
        lower.range(of: #"\b(tip|gratuity|service charge)\b"#, options: .regularExpression) != nil
    }

    private static func isDiscount(_ lower: String) -> Bool {
        ["discount", "coupon", "promo", "markdown", "member savings", "instant savings"].contains(where: lower.contains)
    }

    private static func isWeightLine(_ text: String) -> Bool {
        text.range(of: #"(\d\s*(lb|lbs|kg|oz)\b)|(/\s*(lb|kg|oz))|@"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func leadingCount(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: #/^\s*(\d{1,2})\s*@/#) else { return nil }
        return Int(match.1)
    }

    private static func isHeader(_ lower: String) -> Bool {
        ["receipt", "welcome", "thank", "store", "www", ".com", "phone", "tel", "cashier", "register", "member", "date", "time"]
            .contains(where: lower.contains)
    }

    /// The shop's name sits near the top, in words, not an address, phone number or date.
    private static func looksLikeShop(_ row: String) -> Bool {
        let lower = row.lowercased()
        guard row.filter(\.isLetter).count >= 3, !isHeader(lower) else { return false }
        if row.first?.isNumber == true { return false }
        if row.range(of: #"\(?\d{3}\)?[-. ]\d{3}[-. ]\d{4}"#, options: .regularExpression) != nil { return false }
        if row.range(of: #"\b[A-Z]{2}\s+\d{5}\b"#, options: .regularExpression) != nil { return false }
        return row.filter(\.isNumber).count <= 3
    }

    private static func knownShop(in rows: [String]) -> String? {
        let text = rows.prefix(12).joined(separator: " ").lowercased()
        return shops.first { text.contains($0.lowercased()) || text.contains($0.lowercased().replacingOccurrences(of: "'", with: "")) }
    }

    private static let shops = ["Trader Joe's", "Whole Foods", "Costco", "Target", "Walmart", "Safeway", "Kroger", "Aldi", "Sprouts",
                                "H-E-B", "Publix", "Wegmans", "CVS", "Walgreens", "Starbucks", "Chipotle", "IKEA", "Best Buy",
                                "Home Depot", "Lowe's", "Sephora", "Uniqlo", "In-N-Out", "Panera", "Sweetgreen", "Shake Shack"]

    static func date(in row: String) -> Date? {
        guard let match = row.firstMatch(of: #/\b(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\b/#),
              let month = Int(match.1), let day = Int(match.2), var year = Int(match.3),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        if year < 100 { year += 2000 }
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        // A receipt from the future, or from long ago, is a misread number.
        guard let date, date <= .now.addingTimeInterval(86_400), date > .now.addingTimeInterval(-86_400 * 400) else { return nil }
        return date
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum LocalReceiptModel {
    static let log = Logger(subsystem: "com.jiawenzhu.littlewallet", category: "receipt")

    @Generable
    struct ReadReceipt {
        @Guide(description: "The shop's name as printed at the top, like \"Trader Joe's\". Empty if not printed.")
        var merchant: String
        @Guide(description: "Each thing bought, in order. Never tax, tip, subtotal, total, payment, change or discounts.")
        var items: [ReadItem]
    }

    @Generable
    struct ReadItem {
        @Guide(description: "The thing bought, in plain words with abbreviations spelled out, like \"Organic Bananas\".")
        var name: String
        @Guide(description: "How many, 1 when not printed.")
        var quantity: Int
        @Guide(description: "The price printed for this whole line, in US dollars.")
        var price: Double
    }

    static func read(_ rows: [String]) async -> ReceiptScan? {
        guard case .available = SystemLanguageModel.default.availability, !rows.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You read the text of a shop receipt, one printed line per row, and list what was bought. \
            Use only prices printed on the receipt; never make one up. Skip tax, tip, subtotal, total, payment, \
            card, change and savings lines.
            """)
        do {
            let found = try await session.respond(to: rows.joined(separator: "\n"), generating: ReadReceipt.self).content
            return ReceiptScan(
                merchant: found.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                lines: found.items.filter { $0.price > 0 }.map {
                    .init(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), quantity: max(1, $0.quantity), cents: Int(($0.price * 100).rounded()))
                })
        } catch {
            log.error("On-device model couldn't read the receipt: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
