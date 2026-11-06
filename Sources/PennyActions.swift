import SwiftUI
import CoreImage.CIFilterBuiltins

/// Something Penny can do in PayPal, laid out for the person to check. Nothing is sent until they confirm.
struct PennyPlan: Identifiable, Equatable {
    enum Kind: Equatable { case invoice, refund, payout }

    struct Line: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var colorIndex = 1
        var cents: Int
        /// What it's for: the item on the invoice, or the note with the money.
        var note: String
        /// Email or phone. Invoices are emailed when it's an email, otherwise shared as a link.
        var to = ""
        var wallet = "PayPal"
        var splitID: String?
        var personID: String?
        /// The friend's payment, for a refund.
        var captureID: String?
        /// Ticked to send. Untick any you don't want to send now.
        var included = true
    }

    var id = UUID()
    var kind: Kind
    var lines: [Line]

    /// The lines that will be sent.
    var chosen: [Line] { lines.filter(\.included) }
    var total: Int { chosen.reduce(0) { $0 + $1.cents } }

    var title: String {
        switch kind {
        case .invoice: return lines.count == 1 ? "PayPal invoice" : "\(lines.count) PayPal invoices"
        case .refund: return "Refund with PayPal"
        case .payout: return lines.count == 1 ? "Pay back with PayPal" : "Pay \(lines.count) friends back"
        }
    }

    var symbol: String {
        switch kind {
        case .invoice: return "doc.text.fill"
        case .refund: return "arrow.uturn.backward.circle.fill"
        case .payout: return "paperplane.fill"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .invoice: return chosen.count == 1 ? "Send invoice" : "Send \(chosen.count) invoices"
        case .refund: return "Refund \(money(total))"
        case .payout: return chosen.count == lines.count ? "Send \(money(total))" : "Send \(money(total)) to \(chosen.count)"
        }
    }

    /// A payout needs somewhere to send the money; invoices and refunds don't.
    var ready: Bool { !chosen.isEmpty && (kind != .payout || chosen.allSatisfy { PennyPlanner.isAddress($0.to) }) }
}

/// Reads requests like "remind everyone who hasn't paid", "invoice Sam $45 for the Airbnb", "refund Jing $5"
/// or "pay Sam and Jing back $20 for the tickets" with plain rules, and lays out exactly what would happen.
enum PennyPlanner {
    static func isAction(_ raw: String) -> Bool { kind(of: raw.lowercased()) != nil }

    /// Also "make it $30" and "same for Alex" right after a plan.
    static func isAction(_ raw: String, context: PennyContext) -> Bool {
        isAction(raw) || (context.action != nil && isChange(raw.lowercased()))
    }

    private static func isChange(_ text: String) -> Bool {
        text.range(of: #"^(actually |no,? )?(make it|change it|make that|change that)\b|\bsame for\b|\b(too|as well)[.!?]?$|^(also|and) (invoice|remind|refund|pay)\b"#, options: .regularExpression) != nil
    }

    /// Fills in who "him", "her" and "them" are from the conversation.
    private static func spoken(_ text: String) -> Bool {
        text.range(of: #"\b(him|her|them|he|she|they|that person|those people)\b"#, options: .regularExpression) != nil
    }

    /// Answers with the conversation in mind, and remembers who and what the plan was about.
    @MainActor
    static func reply(to raw: String, splits: SplitService, paypal: PayPalLink, context: inout PennyContext) -> Insight {
        let text = raw.lowercased()
        var request = raw
        let people = knownPeople(splits)
        let named = people.filter { mentions($0.name, in: text) }
        var who = named.map(\.name)
        if who.isEmpty, spoken(text) {
            who = context.people
            guard !who.isEmpty else { return Insight(text: "Who do you mean? Tell me their name and I'll take it from there.") }
            // Say their names in the request, so the plan below finds them.
            request += " " + who.joined(separator: " and ")
        }
        if let last = context.action, isChange(text) {
            let cents = amount(in: text) ?? last.cents
            let names = who.isEmpty ? last.names : who
            let verb = ["invoice": "invoice", "refund": "refund", "payout": "pay back"][last.kind] ?? "invoice"
            let dollars = cents.map { String(format: " $%.2f", Double($0) / 100) } ?? ""
            request = "\(verb) \(names.joined(separator: " and "))\(dollars)" + (last.reason.map { " for \($0)" } ?? "")
        }
        let answer = reply(to: request, splits: splits, paypal: paypal)
        if let plan = answer.plan {
            let lines = plan.lines
            let names = lines.reduce(into: [String]()) { if !$0.contains($1.name) { $0.append($1.name) } }
            context.people = names
            let single = Set(lines.map(\.cents)).count == 1 ? lines.first?.cents : nil
            let reason = lines.first?.note
            context.action = .init(kind: plan.kind.memoryName, names: names, cents: single, reason: reason)
            context.updated = .now
        }
        return answer
    }

    private enum Wanted { case remind, invoice, refund, payout }

    private static func kind(of text: String) -> Wanted? {
        let has = { (words: [String]) in words.contains { text.contains($0) } }
        if has(["refund", "give back", "give her back", "give him back", "give them back"]) { return .refund }
        if has(["remind", "nudge", "chase up", "follow up with"]) { return .remind }
        if has(["invoice", "bill ", "charge ", "request "]) || text.hasPrefix("bill") { return .invoice }
        if has(["pay back", "pay everyone", "send money", "pay them back"]) || text.range(of: #"\bpay \w+( and \w+)* back\b"#, options: .regularExpression) != nil
            || text.range(of: #"\bsend \w+ \$"#, options: .regularExpression) != nil { return .payout }
        return nil
    }

    @MainActor
    static func reply(to raw: String, splits: SplitService, paypal: PayPalLink) -> Insight {
        let text = raw.lowercased()
        let people = knownPeople(splits)
        let named = people.filter { mentions($0.name, in: text) }
        let everyone = named.isEmpty || ["everyone", "everybody", "all of them", "who hasn't", "who hasnt"].contains(where: text.contains)
        let cents = amount(in: text)
        let note = reason(in: raw)

        switch kind(of: text) {
        case .remind?:
            let lines = unpaid(splits, only: everyone ? nil : Set(named.map(\.id)), about: text)
            guard !lines.isEmpty else {
                return Insight(text: named.isEmpty ? "Everyone's paid up. Nobody to remind!" : "\(named.map(\.name).joined(separator: " and ")) doesn't owe you anything right now.")
            }
            let sum = lines.reduce(0) { $0 + $1.cents }
            return Insight(headline: money(sum),
                           text: lines.count == 1
                               ? "I can send \(lines[0].name) a PayPal invoice for \(money(lines[0].cents)). Check it, then tap send."
                               : inviteLine(shares: lines.count, people: Set(lines.map(\.name)).count),
                           plan: PennyPlan(kind: .invoice, lines: lines))

        case .invoice?:
            guard let person = named.first else { return ask("Who should I invoice? Try “Invoice Sam $45 for the Airbnb”.") }
            if let cents {
                let item = note.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Shared cost"
                // Everyone named gets their own invoice for that amount.
                return Insight(headline: money(cents * named.count),
                               text: named.count == 1 ? "Here's the invoice for \(person.name). Check it, then tap send." : "Here's an invoice for each of them. Check them, then tap send.",
                               plan: PennyPlan(kind: .invoice, lines: named.map { line($0, cents: cents, note: String(item)) }))
            }
            // No amount: what they owe from splits.
            let lines = unpaid(splits, only: [person.id], about: text)
            guard !lines.isEmpty else { return ask("How much should I invoice \(person.name) for? Try “Invoice \(person.name) $20 for dinner”.") }
            return Insight(headline: money(lines.reduce(0) { $0 + $1.cents }), text: "\(person.name) still owes you for \(lines.count == 1 ? "this" : "these"). Here's the invoice.",
                           plan: PennyPlan(kind: .invoice, lines: lines))

        case .refund?:
            guard let person = named.first else { return ask("Who should I refund? Try “Refund Jing $5”.") }
            guard let payment = lastPayment(from: person, splits: splits, paypal: paypal) else {
                return Insight(text: "I can't find a PayPal or Venmo payment from \(person.name) to refund. Refunds work on payments that came in through your payment links.")
            }
            let full = payment.cents
            let back = min(cents ?? full, full)
            var refund = line(person, cents: back, note: note.map { String($0.prefix(1).uppercased() + $0.dropFirst()) } ?? "Refund")
            refund.captureID = payment.id
            refund.wallet = payment.via
            return Insight(headline: money(back),
                           text: "\(person.name) paid you \(money(full)) by \(payment.via) on \(payment.when.formatted(.dateTime.month(.abbreviated).day())). I'll give back \(back == full ? "all of it" : money(back)).",
                           plan: PennyPlan(kind: .refund, lines: [refund]))

        case .payout?:
            guard let cents else { return ask("How much should each person get? Try “Pay Sam back $20 for the tickets”.") }
            let who = named.isEmpty ? latestPeople(splits) : named
            guard !who.isEmpty else { return ask("Who should I pay back? Try “Pay Sam back $20”.") }
            let lines = who.map { line($0, cents: cents, note: note.map { String($0.prefix(1).uppercased() + $0.dropFirst()) } ?? "Paid back") }
            let missing = lines.filter { !isAddress($0.to) }.map(\.name)
            return Insight(headline: money(cents * lines.count),
                           text: (lines.count == 1 ? "I'll send \(lines[0].name) \(money(cents)) with PayPal." : "I'll send \(money(cents)) to each of \(lines.count) friends with PayPal.")
                               + (missing.isEmpty ? "" : " Add an email or phone for \(missing.joined(separator: " and ")) first."),
                           plan: PennyPlan(kind: .payout, lines: lines))

        case nil:
            return ask("I can remind friends who owe you, send an invoice, refund a payment or pay friends back.")
        }
    }

    private static func ask(_ text: String) -> Insight { Insight(text: text) }

    /// One friend can owe for several splits, so friends and invoices are counted apart.
    static func inviteLine(shares: Int, people: Int) -> String {
        shares == people
            ? "I can send a PayPal invoice to each of the \(people) friends who still owe you. Check them, then tap send."
            : "\(people == 1 ? "1 friend still owes" : "\(people) friends still owe") you for \(shares) splits. I can send an invoice for each. Check them, then tap send."
    }

    // MARK: - Reading the request

    static func amount(in text: String) -> Int? {
        let patterns = [#"\$\s?(\d{1,6}(?:\.\d{1,2})?)"#, #"(\d{1,6}(?:\.\d{1,2})?)\s?(?:dollars|bucks|usd)\b"#]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let number = text[range].filter { $0.isNumber || $0 == "." }
                if let value = Double(number), value > 0 { return Int((value * 100).rounded()) }
            }
        }
        return nil
    }

    /// "… for his half of the Airbnb" → "half of the Airbnb".
    static func reason(in raw: String) -> String? {
        guard let range = raw.range(of: #"\bfor\b"#, options: [.regularExpression, .caseInsensitive, .backwards]) else { return nil }
        var tail = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for word in ["his ", "her ", "their ", "my ", "our "] where tail.lowercased().hasPrefix(word) { tail = String(tail.dropFirst(word.count)) }
        tail = tail.replacingOccurrences(of: #"\$\s?\d+(\.\d{1,2})?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return tail.count >= 2 && amount(in: tail.lowercased()) == nil ? String(tail.prefix(80)) : nil
    }

    static func mentions(_ name: String, in text: String) -> Bool {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let escaped = NSRegularExpression.escapedPattern(for: first.lowercased())
        return text.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
    }

    static func isAddress(_ to: String) -> Bool {
        let value = to.trimmingCharacters(in: .whitespaces)
        if value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil { return true }
        let digits = value.filter(\.isNumber)
        return digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1"))
    }

    // MARK: - Who and what

    @MainActor
    static func knownPeople(_ splits: SplitService) -> [SplitPerson] {
        var seen = Set<String>()
        return (splits.friends + splits.splits.flatMap(\.people)).filter { !$0.isMe && seen.insert($0.id).inserted }
    }

    @MainActor
    private static func latestPeople(_ splits: SplitService) -> [SplitPerson] {
        splits.splits.max { $0.createdAt < $1.createdAt }?.people.filter { !$0.isMe } ?? []
    }

    @MainActor
    static func line(_ person: SplitPerson, cents: Int, note: String) -> PennyPlan.Line {
        let contact = person.venmo ?? ""
        let phone = contact.filter(\.isNumber).count >= 10 && !contact.contains("@")
        return PennyPlan.Line(name: person.name, colorIndex: person.colorIndex, cents: cents, note: note,
                              to: isAddress(contact) ? contact : "", wallet: phone ? "Venmo" : "PayPal", personID: person.id)
    }

    /// Every share still owed, one line per person per split, newest split first.
    @MainActor
    static func unpaid(_ splits: SplitService, only people: Set<String>?, about text: String) -> [PennyPlan.Line] {
        var all = splits.splits.sorted { $0.createdAt > $1.createdAt }
        // "remind them about Trader Joe's" picks that split when its title is mentioned.
        let named = all.filter { split in
            split.title.lowercased().split(separator: " ").contains { $0.count >= 4 && text.contains($0) }
        }
        if !named.isEmpty { all = named }
        var lines: [PennyPlan.Line] = []
        for split in all {
            for person in split.people where !person.isMe && (people?.contains(person.id) ?? true) {
                guard let share = split.shares[person.id], share.status != "paid", share.cents > 0 else { continue }
                var line = line(person, cents: share.cents, note: "Your share of \(split.title)")
                line.splitID = split.id
                lines.append(line)
            }
        }
        return lines
    }

    @MainActor
    private static func lastPayment(from person: SplitPerson, splits: SplitService, paypal: PayPalLink) -> PayPalActivity? {
        paypal.activity
            .filter { $0.kind == .received }
            .first { item in
                if let ref = item.split, ref.person == person.id { return true }
                if let ref = item.split, let share = splits.splits.first(where: { $0.id == ref.id })?.shares[ref.person],
                   mentions(person.name, in: share.name.lowercased()) { return true }
                return item.name.map { mentions(person.name, in: $0.lowercased()) } ?? false
            }
    }
}

// MARK: - Doing it

/// What happened to one line once it was sent.
struct PlanOutcome: Equatable {
    var ok: Bool
    var detail: String
    var link: URL?
}

/// Sends a confirmed plan to PayPal through the split server, which holds the PayPal keys.
@MainActor
enum PennyActions {
    static func perform(_ plan: PennyPlan, splits: SplitService = .shared) async -> [UUID: PlanOutcome] {
        var results: [UUID: PlanOutcome] = [:]
        switch plan.kind {
        case .invoice:
            for line in plan.lines {
                struct Made: Decodable { var number: String?; var emailed: Bool; var link: String? }
                do {
                    let made: Made = try await post("/api/paypal/invoices", [
                        "name": line.name, "email": line.to.contains("@") ? line.to : "", "title": line.note, "note": "Sent with Little Wallet",
                        "items": [["name": line.note, "amount": Double(line.cents) / 100]],
                        // When it's paid, PayPal's webhook says whose share it was.
                        "reference": line.splitID.flatMap { split in line.personID.map { "\(split)|\($0)" } } ?? "",
                    ])
                    if let split = line.splitID, let person = line.personID { splits.markRequested(split: split, person: person) }
                    results[line.id] = PlanOutcome(ok: true, detail: "Invoice \(made.number.map { "#\($0)" } ?? "") \(made.emailed ? "emailed" : "ready to share")",
                                                   link: made.link.flatMap(URL.init(string:)))
                } catch {
                    results[line.id] = PlanOutcome(ok: false, detail: error.localizedDescription)
                }
            }
        case .refund:
            for line in plan.lines {
                struct Made: Decodable { var status: String?; var amount: String? }
                do {
                    let made: Made = try await post("/api/paypal/refunds", [
                        "captureId": line.captureID ?? "", "amount": Double(line.cents) / 100, "note": line.note,
                    ])
                    results[line.id] = PlanOutcome(ok: true, detail: "Refunded $\(made.amount ?? "") · \((made.status ?? "done").lowercased())")
                } catch {
                    results[line.id] = PlanOutcome(ok: false, detail: error.localizedDescription)
                }
            }
        case .payout:
            struct Made: Decodable { var id: String?; var status: String? }
            do {
                let made: Made = try await post("/api/paypal/payouts", [
                    "subject": "You've been paid back",
                    "items": plan.lines.map { ["name": $0.name, "to": $0.to, "amount": Double($0.cents) / 100, "note": $0.note, "wallet": $0.wallet] },
                ])
                for line in plan.lines {
                    results[line.id] = PlanOutcome(ok: true, detail: "Sent by \(line.wallet) · \((made.status ?? "pending").lowercased())")
                }
            } catch {
                for line in plan.lines { results[line.id] = PlanOutcome(ok: false, detail: error.localizedDescription) }
            }
        }
        return results
    }

    private struct Failure: Decodable { let error: String }

    private static func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var request = URLRequest(url: SplitService.shared.serverURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        SplitService.authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw SplitError(message: "Couldn't reach PayPal. Check your connection and try again.")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw SplitError(message: (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "PayPal said no. Please try again.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - The card

/// Penny's plan, to check and confirm: who, how much, what for, and where it goes. Then what happened.
struct PlanCard: View {
    @State var plan: PennyPlan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable { case checking, sending, done, cancelled }
    @State private var phase: Phase = .checking
    @State private var outcomes: [UUID: PlanOutcome] = [:]
    @State private var showingQR: UUID?
    @State private var sent = 0
    @State private var ticks = 0

    private var failed: Bool { outcomes.values.contains { !$0.ok } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if phase == .checking, plan.lines.count > 1 { chooser }
            ForEach($plan.lines) { $line in
                row($line)
                if line.id != plan.lines.last?.id { Divider() }
            }
            if plan.lines.count > 1 {
                HStack {
                    Text(plan.chosen.count == plan.lines.count ? "Total" : "Total · \(plan.chosen.count) of \(plan.lines.count)")
                        .font(.subheadline.weight(.bold)).contentTransition(.numericText())
                    Spacer()
                    Text(money(plan.total)).font(.subheadline.weight(.heavy)).monospacedDigit().contentTransition(.numericText())
                }
                .foregroundStyle(Theme.ink)
            }
            footer
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(phase == .done && !failed ? Theme.accent.opacity(0.5) : Color(hex: "#1F5BC4").opacity(0.25), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .opacity(phase == .cancelled ? 0.55 : 1)
        .sensoryFeedback(.success, trigger: sent)
        .sensoryFeedback(.selection, trigger: ticks)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: phase)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: plan.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(LinearGradient(colors: [Color(hex: "#2C6FD6"), Color(hex: "#173F8C")], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title).font(.headline).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if PayPalLink.shared.sandbox {
                Text("Sandbox").font(.caption2.weight(.bold)).foregroundStyle(Color(hex: "#1F5BC4"))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(hex: "#1F5BC4").opacity(0.1), in: Capsule())
            }
        }
    }

    /// Everyone on the card, to tick or untick all of one person's lines at once, and All / None.
    private var chooser: some View {
        let people = plan.lines.reduce(into: [(name: String, colorIndex: Int)]()) { list, line in
            if !list.contains(where: { $0.name == line.name }) { list.append((line.name, line.colorIndex)) }
        }
        let all = plan.lines.allSatisfy(\.included)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button { setAll(!all) } label: {
                    Label(all ? "None" : "All", systemImage: all ? "circle" : "checkmark.circle.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 11).frame(height: 32)
                        .background(Theme.background, in: Capsule())
                }
                ForEach(people, id: \.name) { person in
                    let mine = plan.lines.filter { $0.name == person.name }
                    let on = mine.allSatisfy(\.included)
                    let some = mine.contains(where: \.included)
                    Button { setPerson(person.name, !on) } label: {
                        HStack(spacing: 6) {
                            Text(String(person.name.prefix(1)).uppercased())
                                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(SplitPerson.fill(SplitPerson.colors(for: person.colorIndex)), in: Circle())
                            Text(person.name.split(separator: " ").first.map(String.init) ?? person.name).font(.caption.weight(.bold))
                            Text("\(mine.filter(\.included).count)/\(mine.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(Theme.secondary)
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.leading, 5).padding(.trailing, 11).frame(height: 32)
                        .background(on ? Theme.softGreen : Theme.background, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Theme.accent : some ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1.5))
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .scrollIndicators(.hidden)
    }

    private func setAll(_ on: Bool) {
        ticks += 1
        withAnimation(.snappy) { for index in plan.lines.indices { plan.lines[index].included = on } }
    }

    private func setPerson(_ name: String, _ on: Bool) {
        ticks += 1
        withAnimation(.snappy) { for index in plan.lines.indices where plan.lines[index].name == name { plan.lines[index].included = on } }
    }

    private var subtitle: String {
        switch phase {
        case .checking: return "Nothing is sent until you tap \(plan.confirmTitle.lowercased().hasPrefix("send") ? "send" : "refund")"
        case .sending: return "Sending to PayPal…"
        case .done: return failed ? "Some didn't go through" : "Done"
        case .cancelled: return "Cancelled — nothing was sent"
        }
    }

    private func row(_ line: Binding<PennyPlan.Line>) -> some View {
        let outcome = outcomes[line.wrappedValue.id]
        let on = line.wrappedValue.included
        let color = SplitPerson.colors(for: line.wrappedValue.colorIndex).first ?? Theme.accent
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if phase == .checking, plan.lines.count > 1 {
                    Button {
                        ticks += 1
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { line.wrappedValue.included.toggle() }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? color : .clear)
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(on ? color : Theme.secondary.opacity(0.45), lineWidth: 2)
                            if on {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                            }
                        }
                        .frame(width: 28, height: 28)
                        .scaleEffect(on ? 1.06 : 1)
                        .padding(.horizontal, 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(on ? "Don't send" : "Send") \(line.wrappedValue.name), \(money(line.wrappedValue.cents))")
                }
                // While choosing, the tick box in their colour stands in for the avatar.
                if !(phase == .checking && plan.lines.count > 1) {
                    Text(String(line.wrappedValue.name.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(SplitPerson.fill(SplitPerson.colors(for: line.wrappedValue.colorIndex)), in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.wrappedValue.name).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                    Text(line.wrappedValue.note).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                Text(money(line.wrappedValue.cents)).font(.body.weight(.heavy)).monospacedDigit()
                    .foregroundStyle(Theme.ink).strikethrough(!on, color: Theme.secondary)
            }
            .opacity(on ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture {
                guard phase == .checking, plan.lines.count > 1 else { return }
                ticks += 1
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { line.wrappedValue.included.toggle() }
            }
            if phase != .checking, !on {
                Label("Not sent", systemImage: "minus.circle").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                    .padding(.leading, 44)
            }
            if phase == .checking, on, plan.kind != .refund {
                HStack(spacing: 8) {
                    Image(systemName: plan.kind == .payout ? "paperplane" : "envelope").font(.caption).foregroundStyle(Theme.secondary)
                    TextField(plan.kind == .payout ? "Email or phone (needed)" : "Email (optional — or share a link)", text: line.to)
                        .font(.caption).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.leading, plan.lines.count > 1 ? 36 : 44)
                .transition(.opacity)
            }
            if let outcome {
                HStack(spacing: 6) {
                    Image(systemName: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(outcome.ok ? Theme.accent : Color(hex: "#B5654A"))
                    Text(outcome.detail).font(.caption.weight(.semibold)).foregroundStyle(outcome.ok ? Theme.accent : Color(hex: "#B5654A"))
                        .lineLimit(2)
                    Spacer()
                    if let link = outcome.link {
                        Button { withAnimation(.snappy) { showingQR = showingQR == line.wrappedValue.id ? nil : line.wrappedValue.id } } label: {
                            Image(systemName: "qrcode").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.ink)
                        .accessibilityLabel("Show QR code")
                        ShareLink(item: link, message: Text("Here's my PayPal invoice for \(line.wrappedValue.note.lowercased())")) {
                            Image(systemName: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.ink)
                    }
                }
                .padding(.leading, 44)
                .transition(.move(edge: .top).combined(with: .opacity))
                if showingQR == line.wrappedValue.id, let link = outcome.link, let code = QRCode.image(for: link.absoluteString) {
                    VStack(spacing: 6) {
                        Image(uiImage: code).interpolation(.none).resizable().scaledToFit().frame(width: 170, height: 170)
                            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text("\(line.wrappedValue.name) scans this to pay").font(.caption).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .checking:
            HStack(spacing: 10) {
                Button { phase = .cancelled } label: {
                    Text("Cancel").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Button(action: confirm) {
                    Label(plan.confirmTitle, systemImage: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.75).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Color(hex: "#1F5BC4"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!plan.ready)
                .opacity(plan.ready ? 1 : 0.5)
                .accessibilityIdentifier("plan-confirm")
            }
            .buttonStyle(.plain)
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Text("Talking to PayPal…").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 46)
        case .done:
            if failed {
                Button(action: confirm) {
                    Label("Try again", systemImage: "arrow.clockwise").font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink)
            }
        case .cancelled:
            EmptyView()
        }
    }

    private func confirm() {
        phase = .sending
        // Only ticked lines, and on a retry only what didn't go through.
        var pending = plan
        pending.lines = plan.lines.filter { $0.included && outcomes[$0.id]?.ok != true }
        Task {
            let results = await PennyActions.perform(pending)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                outcomes.merge(results) { $1 }
                phase = .done
            }
            if results.values.contains(where: \.ok) {
                sent += 1
                let lines = pending.lines.filter { results[$0.id]?.ok == true }
                PennyChat.shared.record(done: "\(pending.title) to \(lines.map(\.name).joined(separator: ", ")) · \(money(lines.reduce(0) { $0 + $1.cents }))")
            }
            if plan.kind == .refund { _ = await PayPalLink.shared.sync(store: WalletStore.shared) }
        }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension PennyPlan.Kind {
    var memoryName: String {
        switch self {
        case .invoice: return "invoice"
        case .refund: return "refund"
        case .payout: return "payout"
        }
    }
}
