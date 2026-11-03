import SwiftUI

/// What you can do with PayPal from the PayPal & Venmo screen — the same things Penny does when asked.
enum PayPalAction: String, Identifiable, CaseIterable {
    case remind, invoice, refund, payout
    var id: String { rawValue }

    var title: String {
        switch self {
        case .remind: return "Remind"
        case .invoice: return "Send invoice"
        case .refund: return "Refund"
        case .payout: return "Pay back"
        }
    }

    var symbol: String {
        switch self {
        case .remind: return "bell.fill"
        case .invoice: return "doc.text.fill"
        case .refund: return "arrow.uturn.backward"
        case .payout: return "paperplane.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .remind: return [Color(hex: "#E08A4F"), Color(hex: "#C9637A")]
        case .invoice: return [Color(hex: "#2C6FD6"), Color(hex: "#173F8C")]
        case .refund: return [Color(hex: "#3E9C94"), Color(hex: "#2F6F6A")]
        case .payout: return [Color(hex: "#3D95CE"), Color(hex: "#5A6FD6")]
        }
    }
}

/// Four tiles under the balance: remind who owes, invoice, refund, pay back.
struct QuickActions: View {
    @ObservedObject var store: WalletStore
    @Binding var refunding: PayPalActivity?
    @ObservedObject private var splits = SplitService.shared
    @ObservedObject private var link = PayPalLink.shared
    @State private var open: PayPalAction?

    private var owed: (people: Int, cents: Int) {
        let lines = PennyPlanner.unpaid(splits, only: nil, about: "")
        return (Set(lines.map(\.name)).count, lines.reduce(0) { $0 + $1.cents })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Do it with PayPal").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(PayPalAction.allCases) { action in
                    Button { open = action } label: { tile(action) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("paypal-action-\(action.rawValue)")
                }
            }
        }
        .sheet(item: $open) { action in ActionComposer(store: store, kind: action) }
    }

    private func detail(_ action: PayPalAction) -> String {
        switch action {
        case .remind:
            let owed = owed
            return owed.cents == 0 ? "Everyone's paid up" : "\(owed.people) \(owed.people == 1 ? "friend owes" : "friends owe") \(money(owed.cents))"
        case .invoice: return "Bill a friend for anything"
        case .refund:
            let count = link.activity.filter { $0.kind == .received }.count
            return count == 0 ? "No payments to refund" : "Give back a friend's payment"
        case .payout: return "Send money to friends"
        }
    }

    private func tile(_ action: PayPalAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: action.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: action.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text(detail(action)).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2, reservesSpace: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Fill in who, how much and what for, then check the same card Penny shows and confirm.
struct ActionComposer: View {
    @ObservedObject var store: WalletStore
    let kind: PayPalAction
    /// For a refund: the friend's payment, when picked from the list.
    var payment: PayPalActivity?
    @ObservedObject private var splits = SplitService.shared
    @ObservedObject private var link = PayPalLink.shared
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<String> = []
    @State private var newName = ""
    @State private var amount = ""
    @State private var reason = ""
    @State private var refundFrom: PayPalActivity?
    @State private var plan: PennyPlan?
    @State private var ticks = 0
    @FocusState private var typing: Bool

    private var people: [SplitPerson] { PennyPlanner.knownPeople(splits) }
    private var cents: Int { Int(((Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0) * 100).rounded()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let plan {
                        PlanCard(plan: plan).id(plan.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        if kind != .remind {
                            Button { withAnimation(.snappy) { self.plan = nil } } label: {
                                Label("Change it or send another", systemImage: "pencil").font(.subheadline.weight(.semibold))
                            }
                        }
                    } else {
                        form
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { if plan == nil && kind != .remind { reviewBar } }
        }
        .tint(Theme.accent)
        .presentationDetents([.large])
        .sensoryFeedback(.selection, trigger: ticks)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        switch kind {
        case .remind:
            let lines = PennyPlanner.unpaid(splits, only: nil, about: "")
            plan = lines.isEmpty ? nil : PennyPlan(kind: .invoice, lines: lines)
        case .refund:
            if let payment { choose(payment) }
        default: break
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        switch kind {
        case .remind:
            empty("Everyone's paid up", "When friends owe you from a split, you can send each of them a PayPal invoice from here.")
        case .refund:
            refundPicker
        case .invoice, .payout:
            whoPicker
            field(kind == .payout ? "How much each" : "How much", "0.00", text: $amount, money: true)
            field("What for", kind == .payout ? "Concert tickets" : "Half of the Airbnb", text: $reason)
        }
    }

    private var whoPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .invoice ? "Who to invoice" : "Who to pay").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            if !people.isEmpty {
                FlowChips(people: people, picked: $picked) { ticks += 1 }
            }
            HStack(spacing: 8) {
                Image(systemName: "person.badge.plus").foregroundStyle(Theme.secondary)
                TextField(people.isEmpty ? "Their name" : "Or someone new", text: $newName).focused($typing)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var refundPicker: some View {
        let received = link.activity.filter { $0.kind == .received }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Which payment").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            if received.isEmpty {
                empty("No payments yet", "Payments friends send you through PayPal or Venmo show up here to refund.")
            }
            ForEach(received.prefix(12)) { item in
                let on = refundFrom?.id == item.id
                Button { choose(item) } label: {
                    HStack(spacing: 12) {
                        ViaBadge(via: item.via, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "A friend").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                            Text("\(item.when.formatted(.dateTime.month(.abbreviated).day())) · \(item.note ?? item.via)")
                                .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(money(item.cents)).font(.subheadline.weight(.heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Theme.accent : Theme.line)
                    }
                    .padding(12)
                    .background(on ? Theme.softGreen : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if refundFrom != nil {
                field("How much to give back", "0.00", text: $amount, money: true)
                field("Note to them", "Sorry, I overcharged you", text: $reason)
            }
        }
    }

    private func choose(_ item: PayPalActivity) {
        ticks += 1
        withAnimation(.snappy) {
            refundFrom = item
            amount = String(format: "%.2f", Double(item.cents) / 100)
        }
    }

    private func field(_ title: String, _ placeholder: String, text: Binding<String>, money: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            HStack(spacing: 4) {
                if money { Text("$").font(.title3.weight(.bold)).foregroundStyle(Theme.secondary) }
                TextField(placeholder, text: text)
                    .font(money ? .title3.weight(.bold) : .body)
                    .keyboardType(money ? .decimalPad : .default)
                    .focused($typing)
            }
            .padding(.horizontal, 14).frame(height: 50)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(Theme.accent)
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            Text(detail).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(24)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Review

    private var draft: PennyPlan? {
        guard cents > 0 else { return nil }
        let note = reason.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .invoice, .payout:
            var who = people.filter { picked.contains($0.id) }
            let typed = newName.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty { who.append(SplitPerson(id: "new-\(typed.lowercased())", name: typed, colorIndex: 5)) }
            guard !who.isEmpty else { return nil }
            let lines = who.map { PennyPlanner.line($0, cents: cents, note: note.isEmpty ? (kind == .payout ? "Paid back" : "Shared cost") : note) }
            return PennyPlan(kind: kind == .payout ? .payout : .invoice, lines: lines)
        case .refund:
            guard let from = refundFrom, cents <= from.cents else { return nil }
            var line = PennyPlan.Line(name: from.name ?? "A friend", cents: cents, note: note.isEmpty ? "Refund" : note)
            line.captureID = from.id
            line.wallet = from.via
            return PennyPlan(kind: .refund, lines: [line])
        case .remind:
            return nil
        }
    }

    private var reviewBar: some View {
        let ready = draft != nil
        return Button {
            typing = false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { plan = draft }
        } label: {
            Text(hint ?? "Review").font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Color(hex: "#1F5BC4"), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.5)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("composer-review")
    }

    /// What's still missing, on the button.
    private var hint: String? {
        if kind == .refund {
            guard let from = refundFrom else { return "Pick a payment" }
            if cents > from.cents { return "That payment was \(money(from.cents))" }
        } else if picked.isEmpty && newName.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Pick who"
        }
        if cents == 0 { return "Add an amount" }
        return nil
    }
}

/// Friends as tappable chips that wrap onto new lines.
private struct FlowChips: View {
    let people: [SplitPerson]
    @Binding var picked: Set<String>
    var tapped: () -> Void

    var body: some View {
        ChipLayout(spacing: 8) {
            ForEach(people) { person in
                let on = picked.contains(person.id)
                Button {
                    tapped()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                        if on { picked.remove(person.id) } else { picked.insert(person.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(person.initial).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(person.avatar, in: Circle())
                        Text(person.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        if on { Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(Theme.accent) }
                    }
                    .padding(.leading, 5).padding(.trailing, 12).frame(height: 38)
                    .background(on ? Theme.softGreen : Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Theme.accent : Theme.line, lineWidth: on ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Lays chips out left to right, wrapping when a row is full.
private struct ChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
