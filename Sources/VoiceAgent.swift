import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What someone said they bought, understood: the shop, each thing with its price, and who's sharing it.
struct VoicePlan: Equatable {
    struct Line: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var quantity: Int = 1
        /// The whole line, in cents ("2 milks $8" is 800).
        var cents: Int

        static func == (a: Line, b: Line) -> Bool { a.name == b.name && a.quantity == b.quantity && a.cents == b.cents }
    }

    var store: String = ""
    var lines: [Line] = []
    var wantsSplit = false
    /// The other people sharing, by name. Never includes the speaker.
    var people: [String] = []
    /// "Split three ways": everyone counted, the speaker included. 0 when not said.
    var headcount = 0

    var totalCents: Int { lines.reduce(0) { $0 + $1.cents } }
    /// Everyone sharing, the speaker first.
    var sharers: Int { wantsSplit ? max(people.count + 1, headcount) : 1 }
    /// Each person's part of the total, the speaker first; always adds up to the cent.
    var shares: [Int] { SplitMath.spread(totalCents, weights: Array(repeating: 1, count: sharers)) }
    var isEmpty: Bool { lines.isEmpty }
}

/// Understands a spoken purchase on the phone. Apple's on-device language model reads it when this iPhone has
/// Apple Intelligence; `VoiceParser` reads it otherwise, and checks the model never invents a price.
enum VoiceAgent {
    enum Engine: Equatable { case appleIntelligence, parser }

    static func understand(_ text: String, friends: [String]) async -> (VoicePlan, Engine) {
        let parsed = VoiceParser.parse(text, friends: friends)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let model = await LocalModel.understand(text, friends: friends) {
            var plan = VoiceParser.tidy(model, friends: friends)
            // The model may only use prices that were said; otherwise keep the parser's lines.
            let said = Set(parsed.lines.map(\.cents) + VoiceParser.amounts(in: text))
            if plan.isEmpty || plan.lines.contains(where: { !said.contains($0.cents) }) {
                plan.lines = parsed.lines
            }
            if plan.store.isEmpty { plan.store = parsed.store }
            if !plan.isEmpty { return (plan, .appleIntelligence) }
        }
        #endif
        return (parsed, .parser)
    }

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return LocalModel.available }
        #endif
        return false
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum LocalModel {
    static let log = Logger(subsystem: "com.jiawenzhu.littlewallet", category: "voice")

    @Generable
    struct SpokenPurchase {
        @Guide(description: "The shop, only if one was named, like \"Trader Joe's\". Empty otherwise.")
        var store: String
        @Guide(description: "Each thing bought, with the price said for it.")
        var items: [SpokenItem]
        @Guide(description: "True when the speaker wants to split or share the cost with other people.")
        var wantsSplit: Bool
        @Guide(description: "First names of the other people sharing the cost. Never the speaker (me, I, myself).")
        var people: [String]
        @Guide(description: "How many people share in total, the speaker included, when a number was said (\"split three ways\"). 0 otherwise.")
        var headcount: Int
    }

    @Generable
    struct SpokenItem {
        @Guide(description: "The thing bought, short and capitalized, like \"Strawberries\" or \"Ride\". \"Payment\" when nothing was named.")
        var name: String
        @Guide(description: "How many, 1 when not said.")
        var quantity: Int
        @Guide(description: "The price for this whole line in US dollars, exactly as said. 0 when no price was said.")
        var price: Double
    }

    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func understand(_ text: String, friends: [String]) async -> VoicePlan? {
        guard available else { return nil }
        let known = friends.isEmpty ? "" : " People they often split with: \(friends.joined(separator: ", ")). Speech recognition can mishear these names; use the closest one."
        let session = LanguageModelSession(instructions: """
            You read what someone said about something they just paid for and fill in the payment. \
            Use only prices that were said; never make one up. A price said once for the whole payment belongs to one \
            line named "Payment" unless a thing was named.\(known)
            """)
        let found: SpokenPurchase
        do {
            found = try await session.respond(to: text, generating: SpokenPurchase.self).content
        } catch {
            log.error("On-device model couldn't read the purchase: \(String(describing: error), privacy: .public)")
            return nil
        }
        return VoicePlan(
            store: found.store,
            lines: found.items.map { .init(name: $0.name, quantity: max(1, $0.quantity), cents: Int(($0.price * 100).rounded())) },
            wantsSplit: found.wantsSplit,
            people: found.people,
            headcount: found.headcount)
    }
}
#endif

/// Reads a spoken purchase with plain rules: "$13 strawberries and milk 4 dollars at Trader Joe's, split with Sam and Kate".
enum VoiceParser {
    static func parse(_ raw: String, friends: [String] = []) -> VoicePlan {
        var text = " " + numbersFromWords(raw) + " "
        var plan = VoicePlan()

        // The shop: "at Trader Joe's", "from Costco".
        if let match = text.firstMatch(of: #/\s(?i:at|from)\s+((?:[A-Z][\w'’&-]*\s?){1,3})/#) {
            plan.store = String(match.1).trimmingCharacters(in: .whitespaces)
            text.replaceSubrange(match.range, with: " ")
        } else if let shop = knownStores.first(where: { text.lowercased().contains($0.lowercased()) }) {
            plan.store = shop
            text = text.replacingOccurrences(of: shop, with: " ", options: .caseInsensitive)
        }

        let lower = text.lowercased()
        plan.wantsSplit = ["split", "share", "divide", "between", " ways", "halves", "go dutch"].contains { lower.contains($0) }
        if let match = text.firstMatch(of: #/(\d+)\s*(?i:ways|people|of us|persons)/#), let count = Int(match.1) {
            plan.headcount = count
            plan.wantsSplit = true
            text.replaceSubrange(match.range, with: " ")
        }

        // Who: everything after "with", "between" or "among".
        if plan.wantsSplit, let match = text.firstMatch(of: #/\s(?i:with|between|among)\s(.+)$/#) {
            plan.people = names(in: String(match.1), friends: friends)
            text.replaceSubrange(match.range, with: " ")
        }

        plan.lines = lines(in: text)
        if plan.lines.isEmpty, let cents = amounts(in: text).first {
            plan.lines = [.init(name: "Payment", cents: cents)]
        }
        return plan
    }

    /// Cleans what the model returned: real names only, matched to friends, and no empty lines.
    static func tidy(_ plan: VoicePlan, friends: [String]) -> VoicePlan {
        var plan = plan
        plan.store = plan.store.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.people = names(in: plan.people.joined(separator: ", "), friends: friends)
        plan.lines = plan.lines.filter { $0.cents > 0 }.map { line in
            var line = line
            line.name = title(line.name)
            return line
        }
        if !plan.people.isEmpty || plan.headcount > 1 { plan.wantsSplit = true }
        return plan
    }

    /// Every amount of money said, in cents.
    static func amounts(in text: String) -> [Int] {
        let text = numbersFromWords(text)
        var found: [Int] = []
        for match in text.matches(of: #/\$\s?(\d+(?:\.\d{1,2})?)|(\d+(?:\.\d{1,2})?)\s*(?i:dollars?|bucks|usd)|(\d+)\s*(?i:cents?)/#) {
            if let dollars = match.1 ?? match.2, let value = Double(dollars) {
                found.append(Int((value * 100).rounded()))
            } else if let cents = match.3, let value = Int(cents) {
                found.append(value)
            }
        }
        return found
    }

    // MARK: - Lines

    private static func lines(in text: String) -> [VoicePlan.Line] {
        // "4 dollars and 50 cents" is $4.50, and "dollars" becomes a "$" so every price looks the same.
        var text = text.replacing(#/(\d+)\s*(?i:dollars?)\s*(?i:and)\s*(\d{1,2})\s*(?i:cents?)/#) { match in
            "$\(match.1).\(String(format: "%02d", Int(match.2) ?? 0))"
        }
        text = text.replacing(#/(\d+(?:\.\d{1,2})?)\s*(?i:dollars?|bucks|usd)/#) { "$\($0.1)" }
        let pieces = text.split(separator: #/,|;|\s+(?i:and|plus|then)\s+/#).map(String.init)

        var lines: [VoicePlan.Line] = []
        var pendingName: String?
        var pendingPrice: (cents: Int, quantity: Int)?
        for piece in pieces {
            let (name, cents, quantity) = read(piece)
            switch (name, cents) {
            case let (name?, cents?):
                // Words with no price just before belong to this one: "milk and eggs, $6".
                let full = pendingName.map { "\($0) and \(name.lowercased())" } ?? name
                lines.append(.init(name: full, quantity: quantity, cents: cents))
                pendingName = nil
            case let (name?, nil):
                if let price = pendingPrice {
                    lines.append(.init(name: name, quantity: price.quantity, cents: price.cents))
                    pendingPrice = nil
                } else {
                    // "Mac and cheese $5" was cut at "and": keep the words for the next price.
                    pendingName = pendingName.map { "\($0) and \(name.lowercased())" } ?? name
                }
            case let (nil, cents?):
                if let name = pendingName {
                    lines.append(.init(name: title(name), quantity: quantity, cents: cents))
                    pendingName = nil
                } else {
                    pendingPrice = (cents, quantity)
                }
            case (nil, nil): break
            }
        }
        if let price = pendingPrice { lines.append(.init(name: "Payment", quantity: price.quantity, cents: price.cents)) }
        return lines
    }

    /// One piece like "2 milks $4 each": the food, its whole price and how many.
    private static func read(_ piece: String) -> (String?, Int?, Int) {
        var rest = piece
        var cents: Int?
        if let match = rest.firstMatch(of: #/\$\s?(\d+(?:\.\d{1,2})?)/#), let value = Double(match.1) {
            cents = Int((value * 100).rounded())
            rest.replaceSubrange(match.range, with: " ")
        } else if let match = rest.firstMatch(of: #/(\d+)\s*(?i:cents?)/#), let value = Int(match.1) {
            cents = value
            rest.replaceSubrange(match.range, with: " ")
        }
        var quantity = 1
        let bare = rest.matches(of: #/\b(\d+(?:\.\d{1,2})?)\b/#)
        if cents == nil, bare.count == 1, let value = Double(bare[0].1) {
            // A lone number with no "$" is still money here: "13 strawberry".
            cents = Int((value * 100).rounded())
            rest.replaceSubrange(bare[0].range, with: " ")
        } else if let first = bare.first, let count = Int(first.1), count > 0, count < 100 {
            quantity = count
            rest.replaceSubrange(first.range, with: " ")
        }
        if rest.range(of: #"\beach\b"#, options: [.regularExpression, .caseInsensitive]) != nil, let each = cents {
            cents = each * quantity
        }
        let words = rest.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" })
            .map(String.init).filter { !fillers.contains($0) }
        return (words.isEmpty ? nil : title(words.joined(separator: " ")), cents, quantity)
    }

    // MARK: - People

    private static func names(in text: String, friends: [String]) -> [String] {
        var seen: Set<String> = []
        return text.split(separator: #/,|&|\s+(?i:and|plus)\s+/#)
            .map { $0.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init) }
            .compactMap { words -> String? in
                let words = words.filter { !notNames.contains($0.lowercased()) }
                guard let first = words.first, words.count <= 2 else { return nil }
                return match(first, in: friends) ?? title(words.joined(separator: " "))
            }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// The friend a heard name most likely means: "Kit" is Kate, "Sam" is Sam.
    static func match(_ heard: String, in friends: [String]) -> String? {
        let heard = heard.lowercased()
        var best: (name: String, distance: Int)?
        for friend in friends {
            let first = friend.split(separator: " ").first.map { String($0).lowercased() } ?? ""
            guard !first.isEmpty, first.first == heard.first else { continue }
            let distance = first == heard ? 0 : edits(heard, first)
            if distance <= (first.count <= 3 ? 1 : 2), distance < (best?.distance ?? .max) { best = (friend, distance) }
        }
        return best?.name
    }

    private static func edits(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    // MARK: - Words

    private static func title(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.prefix(1).uppercased() + clean.dropFirst()
    }

    /// "seven dollars" → "7 dollars", "twenty five" → "25".
    static func numbersFromWords(_ text: String) -> String {
        let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                     "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
                     "seventeen": 17, "eighteen": 18, "nineteen": 19]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        var out: [String] = []
        var number: Int?
        func flush() { if let n = number { out.append(String(n)); number = nil } }
        for token in text.split(separator: " ").map(String.init) {
            let word = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let trailing = token.last.map { $0.isPunctuation && $0 != "'" ? String($0) : "" } ?? ""
            if let ten = tens[word] {
                flush(); number = ten
            } else if let unit = units[word] {
                if let n = number, n >= 20, n % 10 == 0, unit < 10 { number = n + unit } else { flush(); number = unit }
            } else if word == "hundred", let n = number {
                number = n * 100
            } else {
                flush(); out.append(token); continue
            }
            if !trailing.isEmpty { flush(); out[out.count - 1] += trailing }
        }
        flush()
        return out.joined(separator: " ")
    }

    private static let knownStores = ["Trader Joe's", "Costco", "Whole Foods", "Target", "Walmart", "Safeway", "Kroger", "Aldi",
                                      "Sprouts", "H-E-B", "Publix", "Wegmans", "Instacart", "Amazon Fresh"]
    private static let fillers: Set<String> = [
        "i", "we", "me", "my", "our", "just", "bought", "buy", "got", "get", "picked", "grabbed", "paid", "spent", "add", "added",
        "a", "an", "the", "some", "of", "for", "on", "in", "it", "that", "this", "was", "were", "is", "are", "cost", "costs",
        "split", "splitting", "share", "sharing", "divide", "up", "please", "each", "total", "dollar", "dollars", "bucks",
        "cents", "cent", "and", "with", "today", "also", "um", "uh", "so", "okay", "ok", "evenly", "equally", "bill", "ways"]
    private static let notNames: Set<String> = ["me", "myself", "i", "us", "we", "you", "and", "the", "my", "friends", "friend",
                                                "roommates", "roommate", "evenly", "equally", "please", "too", "also"]
}
