import SwiftUI

/// A way to pay: a kind of card, a phone wallet, an app, the bank, pay-later, cash and more.
struct PayMethod: Identifiable, Hashable {
    var name: String
    var symbol: String
    var hex: String
    /// Drawn as a plastic card; everything else gets a flat tile.
    var isCard = false
    var id: String { name }
}

enum PayMethods {
    static let groups: [(title: String, items: [PayMethod])] = [
        ("Cards", [
            .init(name: "Credit card", symbol: "creditcard.fill", hex: "#3E5C8A", isCard: true),
            .init(name: "Debit card", symbol: "creditcard", hex: "#3E7A5C", isCard: true),
            .init(name: "Apple Card", symbol: "apple.logo", hex: "#8A8F86", isCard: true),
            .init(name: "Visa", symbol: "creditcard.fill", hex: "#1A3E8C", isCard: true),
            .init(name: "Mastercard", symbol: "creditcard.fill", hex: "#C9573A", isCard: true),
            .init(name: "American Express", symbol: "creditcard.fill", hex: "#2F7FB8", isCard: true),
            .init(name: "Discover", symbol: "creditcard.fill", hex: "#D9822B", isCard: true),
            .init(name: "Prepaid card", symbol: "creditcard.and.123", hex: "#7A6AB5", isCard: true),
            .init(name: "Store card", symbol: "storefront.fill", hex: "#B5654A", isCard: true),
            .init(name: "Gift card", symbol: "giftcard.fill", hex: "#C9637A", isCard: true),
            .init(name: "HSA / FSA card", symbol: "cross.case.fill", hex: "#3E9C94", isCard: true),
            .init(name: "Company card", symbol: "briefcase.fill", hex: "#4A4F57", isCard: true),
        ]),
        ("Phone wallets", [
            .init(name: "Apple Pay", symbol: "apple.logo", hex: "#1F2421"),
            .init(name: "Apple Cash", symbol: "dollarsign.circle.fill", hex: "#2E2E33"),
            .init(name: "Google Pay", symbol: "g.circle.fill", hex: "#4F7FB8"),
            .init(name: "Samsung Pay", symbol: "s.circle.fill", hex: "#2F4FA8"),
        ]),
        ("Apps", [
            .init(name: "PayPal", symbol: "p.circle.fill", hex: "#1F5BC4"),
            .init(name: "Venmo", symbol: "v.circle.fill", hex: "#3D95CE"),
            .init(name: "Cash App", symbol: "dollarsign.square.fill", hex: "#2E9E4F"),
            .init(name: "Zelle", symbol: "z.circle.fill", hex: "#6A3FB5"),
            .init(name: "Wise", symbol: "arrow.left.arrow.right.circle.fill", hex: "#4F9E3A"),
            .init(name: "Revolut", symbol: "r.circle.fill", hex: "#2E3A55"),
            .init(name: "WeChat Pay", symbol: "message.circle.fill", hex: "#2EA34F"),
            .init(name: "Alipay", symbol: "a.circle.fill", hex: "#2F8FE0"),
        ]),
        ("Bank", [
            .init(name: "Bank transfer", symbol: "building.columns.fill", hex: "#4A5D7A"),
            .init(name: "Direct debit", symbol: "arrow.triangle.2.circlepath", hex: "#5A6FD6"),
            .init(name: "Check", symbol: "doc.text.fill", hex: "#8C6A4F"),
            .init(name: "Wire transfer", symbol: "network", hex: "#3E5C8A"),
        ]),
        ("Pay later", [
            .init(name: "Klarna", symbol: "k.circle.fill", hex: "#E06C9F"),
            .init(name: "Afterpay", symbol: "clock.arrow.circlepath", hex: "#3E9C94"),
            .init(name: "Affirm", symbol: "calendar.badge.clock", hex: "#5A6FD6"),
            .init(name: "PayPal Pay Later", symbol: "calendar.circle.fill", hex: "#1F5BC4"),
        ]),
        ("Other", [
            .init(name: "Cash", symbol: "banknote.fill", hex: "#5E8B4A"),
            .init(name: "Store credit", symbol: "tag.fill", hex: "#D1A23B"),
            .init(name: "Points & rewards", symbol: "star.circle.fill", hex: "#D1A23B"),
            .init(name: "Crypto", symbol: "bitcoinsign.circle.fill", hex: "#E08A4F"),
            .init(name: "Someone else paid", symbol: "person.fill.checkmark", hex: "#9A6FC4"),
        ]),
    ]

    static let all: [PayMethod] = groups.flatMap(\.items)

    /// Ready to pick in a new payment before you've used anything.
    static let starters = ["Apple Pay", "Credit card", "Debit card", "Cash"]

    private static let kindsKey = "little-wallet-pay-kinds-v1"

    /// The kind you gave a card you named yourself, like "Chase Sapphire" → "Credit card".
    static func kind(of name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: kindsKey) as? [String: String])?[name]
    }

    static func remember(_ name: String, as kind: String) {
        var kinds = (UserDefaults.standard.dictionary(forKey: kindsKey) as? [String: String]) ?? [:]
        kinds[name] = kind
        UserDefaults.standard.set(kinds, forKey: kindsKey)
    }

    /// How to draw a way to pay, from its name: a known one, a card you named, or a good guess.
    static func info(for name: String) -> PayMethod {
        if let known = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return known }
        if let kind = kind(of: name), var base = all.first(where: { $0.name == kind }) {
            base.name = name
            return base
        }
        let lower = name.lowercased()
        let hints: [(String, [String])] = [
            ("Debit card", ["debit", "checking"]),
            ("Cash", ["cash"]),
            ("Visa", ["visa"]), ("Mastercard", ["mastercard", "master card"]), ("American Express", ["amex", "american express"]),
            ("Discover", ["discover"]), ("Gift card", ["gift"]), ("Bank transfer", ["bank", "ach"]),
            ("Credit card", ["credit", "sapphire", "freedom", "chase", "citi", "capital one", "venture", "quicksilver", "platinum", "gold", "card"]),
        ]
        for (kind, words) in hints where words.contains(where: lower.contains) {
            var base = all.first { $0.name == kind }!
            base.name = name
            return base
        }
        return PayMethod(name: name, symbol: "wallet.pass.fill", hex: "#6E7A70", isCard: true)
    }
}

/// A way to pay, as a small round mark.
struct PayMethodIcon: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        let method = PayMethods.info(for: name)
        Image(systemName: method.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: method.hex).gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Every way to pay, to search and pick from, and a place to name your own card.
struct PayMethodPicker: View {
    @Binding var selection: String
    var used: [String] = []
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var cardName = ""
    @State private var cardKind = "Credit card"
    @State private var ticks = 0
    @FocusState private var naming: Bool

    private let kinds = ["Credit card", "Debit card", "Prepaid card", "Store card", "Gift card", "Company card"]

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if query.isEmpty { nameYourCard }
                    let mine = used.filter { query.isEmpty || $0.lowercased().contains(query) }
                    if !mine.isEmpty { group("You've used", mine.map(PayMethods.info)) }
                    ForEach(PayMethods.groups, id: \.title) { group in
                        let items = group.items.filter { query.isEmpty || $0.name.lowercased().contains(query) }
                        if !items.isEmpty { self.group(group.title, items) }
                    }
                    if !query.isEmpty {
                        Button { choose(search.trimmingCharacters(in: .whitespaces)) } label: {
                            Label("Use “\(search.trimmingCharacters(in: .whitespaces))”", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Visa, Venmo, Klarna…")
            .navigationTitle("Paid with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(Theme.accent)
        .sensoryFeedback(.selection, trigger: ticks)
    }

    private var nameYourCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name your card").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                PayMethodIcon(name: cardKind, size: 38)
                TextField("Chase Sapphire, Amex Gold…", text: $cardName)
                    .focused($naming)
                    .submitLabel(.done)
                    .onSubmit(addCard)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(kinds, id: \.self) { kind in
                        Button {
                            ticks += 1
                            withAnimation(.snappy) { cardKind = kind }
                        } label: {
                            Text(kind).font(.caption.weight(.semibold))
                                .padding(.horizontal, 11).frame(height: 30)
                                .background(cardKind == kind ? Theme.accent : Theme.background, in: Capsule())
                                .foregroundStyle(cardKind == kind ? .white : Theme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(action: addCard) {
                Text("Add card").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(cardName.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(cardName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func group(_ title: String, _ items: [PayMethod]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(items) { method in
                    let on = method.name == selection
                    Button { choose(method.name) } label: {
                        VStack(spacing: 8) {
                            PayMethodIcon(name: method.name, size: 40)
                            Text(method.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).frame(height: 96)
                        .background(on ? Theme.softGreen : Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func addCard() {
        let name = String(cardName.trimmingCharacters(in: .whitespaces).prefix(30))
        guard !name.isEmpty else { return }
        PayMethods.remember(name, as: cardKind)
        choose(name)
    }

    private func choose(_ name: String) {
        guard !name.isEmpty else { return }
        ticks += 1
        selection = name
        dismiss()
    }
}
