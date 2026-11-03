import SwiftUI

/// Add any payment the way Venmo takes an amount: a big number that builds as you tap your own keypad, then the
/// details — what for, category, card, when. Also edits a saved payment (straight to the details).
struct AddPaymentSheet: View {
    @ObservedObject var store: WalletStore
    var editing: Payment?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step { case amount, details }
    @State private var step: Step = .amount
    @State private var amountText = ""
    @State private var merchant = ""
    /// The name filled in from a category, so picking another category can replace it until you type your own.
    @State private var autoName: String?
    @State private var category: SpendCategory = .other
    @State private var pickedCategory = false
    @State private var card = ""
    @State private var date = Date.now
    @State private var note = ""
    @State private var items: [LineItem] = []
    @State private var itemPrices: [UUID: String] = [:]
    @State private var splitAfter = false
    @State private var splitting: UUID?
    @State private var askingCard = false
    @State private var pickingDate = false
    // Haptics and the "no" shake.
    @State private var keyTaps = 0
    @State private var refusals = 0
    @State private var picks = 0
    @State private var saves = 0
    @FocusState private var focus: Field?
    private enum Field: Hashable { case merchant, note }

    private var amount: Double { WalletStore.amount(amountText) }
    private var canSave: Bool { amount > 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty }
    private var shownAmount: String { amountText.isEmpty ? "0" : amountText }
    private var cardChoices: [String] {
        var list = store.cards
        for extra in PayMethods.starters where !list.contains(extra) { list.append(extra) }
        if !card.isEmpty && !list.contains(card) { list.insert(card, at: 0) }
        return list
    }

    var body: some View {
        Group {
            if let splitting {
                SplitSheet(store: store, transactionID: splitting)
            } else {
                NavigationStack {
                    ZStack {
                        Theme.background.ignoresSafeArea()
                        switch step {
                        case .amount: amountStep.transition(.move(edge: .leading).combined(with: .opacity))
                        case .details: detailsStep.transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .navigationTitle(editing == nil ? "New payment" : "Edit payment")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            if step == .details && editing == nil {
                                Button { go(.amount) } label: { Label("Amount", systemImage: "chevron.left") }
                            } else {
                                Button("Cancel") { dismiss() }
                            }
                        }
                    }
                    .sheet(isPresented: $askingCard) {
                        PayMethodPicker(selection: Binding(get: { card }, set: { card = $0; picks += 1 }), used: store.cards)
                    }
                }
                .tint(Theme.accent)
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: keyTaps)
        .sensoryFeedback(.error, trigger: refusals)
        .sensoryFeedback(.selection, trigger: picks)
        .sensoryFeedback(.success, trigger: saves)
        .onAppear(perform: load)
    }

    private func go(_ next: Step) {
        focus = nil
        withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)) { step = next }
    }

    // MARK: - Step 1: the amount

    private var amountStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("$").font(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(Theme.secondary)
                Text(shownAmount)
                    .font(.system(size: shownAmount.count > 9 ? 56 : shownAmount.count > 6 ? 68 : 84, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(amountText.isEmpty ? Theme.secondary.opacity(0.4) : Theme.ink)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: amountText)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .modifier(Shake(times: CGFloat(refusals)))
            .animation(.linear(duration: 0.35), value: refusals)
            .padding(.horizontal, 24)
            .accessibilityElement().accessibilityLabel("Amount \(dollars(amount))")

            Text(amountHint).font(.subheadline).foregroundStyle(Theme.secondary).padding(.top, 8)
                .contentTransition(.opacity)
            Spacer(minLength: 10)

            Keypad { key in press(key) }
                .padding(.horizontal, 18)

            Button { go(.details) } label: {
                Text("Next").font(.title3.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 58)
                    .background(Theme.accent.opacity(amount > 0 ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain).disabled(amount <= 0)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            .accessibilityIdentifier("amount-next")
        }
    }

    private var amountHint: String {
        if amount <= 0 { return "How much did you spend?" }
        if amount >= 1000 { return "That's a big one!" }
        return "Tap Next to say what it was for"
    }

    /// One key from the keypad: builds the amount, or shakes "no" when it can't take another digit.
    private func press(_ key: Keypad.Key) {
        let before = amountText
        switch key {
        case .delete:
            guard !amountText.isEmpty else { refusals += 1; return }
            amountText = WalletStore.typing(String(amountText.dropLast()))
            keyTaps += 1
        case .point, .digit:
            let next = WalletStore.typing(before + (key == .point ? "." : String(key.digit)))
            // A key that changes nothing is refused: a third decimal, a second point, or past $9,999,999.99.
            guard next != before else { refusals += 1; return }
            amountText = next
            keyTaps += 1
        }
    }

    // MARK: - Step 2: the details

    private var detailsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    amountPill
                    field("What for") {
                        TextField(category == .other ? "Trader Joe's, Uber, rent…" : category.title, text: $merchant)
                            .font(.title3.weight(.semibold)).focused($focus, equals: .merchant)
                            .textInputAutocapitalization(.words).submitLabel(.done)
                            .onChange(of: merchant) { _, name in
                                if name != autoName { autoName = nil }
                                if !pickedCategory && autoName == nil { category = .guess(merchant: name, items: items.map(\.name)) }
                            }
                            .accessibilityIdentifier("payment-merchant")
                    }
                    categoryPicker
                    cardPicker
                    whenPicker
                    itemsSection
                    field("Note") {
                        TextField("Optional", text: $note, axis: .vertical).lineLimit(1...3).focused($focus, equals: .note)
                    }
                    if editing == nil { splitToggle }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            saveButton
        }
    }

    private var amountPill: some View {
        Button { if editing == nil { go(.amount) } } label: {
            HStack(spacing: 10) {
                CategoryIcon(category: category, size: 44)
                    .id(category).transition(.scale.combined(with: .opacity))
                Text("$" + shownAmount).font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                if editing == nil {
                    Image(systemName: "pencil").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: category)
        .accessibilityLabel("Amount \(dollars(amount)). Change")
    }

    private var categoryPicker: some View {
        field("Category") {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(SpendCategory.allCases) { option in
                        let on = option == category
                        Button { choose(option) } label: {
                            VStack(spacing: 4) {
                                CategoryIcon(category: option, size: 42)
                                    .scaleEffect(on ? 1.12 : 1)
                                Text(option.short).font(.caption.weight(.semibold)).lineLimit(1)
                            }
                            .frame(width: 80, height: 82)
                            .background(on ? Theme.softGreen : Theme.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                            .foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: on)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Picking a category fills "What for" with its name, unless you've written your own.
    private func choose(_ option: SpendCategory) {
        category = option
        pickedCategory = true
        picks += 1
        let trimmed = merchant.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == autoName {
            autoName = option.title
            merchant = option.title
        }
    }

    private var cardPicker: some View {
        field("Paid with") {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(cardChoices.enumerated()), id: \.element) { index, name in
                        let on = name == card
                        Button {
                            card = on ? "" : name
                            picks += 1
                        } label: {
                            CardFace(name: name, style: index)
                                .frame(width: 128)
                                .overlay(alignment: .topTrailing) {
                                    if on {
                                        Image(systemName: "checkmark.circle.fill").font(.title3)
                                            .foregroundStyle(.white, Theme.accent).padding(6)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .scaleEffect(on ? 1.05 : card.isEmpty ? 1 : 0.94)
                                .opacity(on || card.isEmpty ? 1 : 0.6)
                                .rotationEffect(.degrees(on ? -2 : 0))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: card)
                        .accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
                    }
                    Button { askingCard = true } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "ellipsis").font(.title3.weight(.bold))
                            Text("More").font(.caption.weight(.semibold))
                        }
                        .frame(width: 64, height: 80)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
                        .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("More ways to pay")
                }
                .padding(.vertical, 6).padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var whenPicker: some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(date), isYesterday = calendar.isDateInYesterday(date)
        return field("When") {
            HStack(spacing: 8) {
                chip("Today", on: isToday && !pickingDate) { date = .now; pickingDate = false }
                chip("Yesterday", on: isYesterday && !pickingDate) {
                    date = calendar.date(byAdding: .day, value: -1, to: .now)!
                    pickingDate = false
                }
                chip(isToday || isYesterday ? "Pick a day" : date.formatted(.dateTime.month(.abbreviated).day()),
                     on: pickingDate || (!isToday && !isYesterday), symbol: "calendar") { pickingDate.toggle() }
            }
            // The calendar opens right here at full width, and closes once a day is picked.
            if pickingDate {
                DatePicker("Date", selection: Binding(get: { date }, set: { picked in
                    date = picked
                    picks += 1
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { pickingDate = false }
                }), in: ...Date.now.addingTimeInterval(3600), displayedComponents: .date)
                .datePickerStyle(.graphical).tint(Theme.accent).labelsHidden()
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: pickingDate)
    }

    private func chip(_ title: String, on: Bool, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            picks += 1
        } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).frame(height: 38)
            .background(on ? Theme.accent : Theme.background, in: Capsule())
            .foregroundStyle(on ? .white : Theme.ink)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }

    private var itemsSection: some View {
        field("Items") {
            VStack(spacing: 8) {
                ForEach($items) { $item in
                    HStack(spacing: 8) {
                        TextField("Item", text: $item.name).font(.body.weight(.semibold))
                        HStack(spacing: 1) {
                            Text("$").foregroundStyle(Theme.secondary)
                            TextField("0.00", text: Binding(
                                get: { itemPrices[item.id] ?? "" },
                                set: { itemPrices[item.id] = $0; item.price = $0.isEmpty ? nil : WalletStore.amount($0) }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        }
                        .monospacedDigit()
                        Button { withAnimation(.snappy) { items.removeAll { $0.id == item.id } } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(Theme.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Remove \(item.name)")
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Button { withAnimation(.snappy) { items.append(LineItem(name: "")) }; picks += 1 } label: {
                    Label(items.isEmpty ? "Add what you bought (optional)" : "Add another item", systemImage: "plus")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                if !items.isEmpty {
                    Text("Items let friends pay only for what they had.").font(.caption).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var splitToggle: some View {
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { splitAfter.toggle() }; picks += 1 } label: {
            HStack(spacing: 12) {
                Image("PennyFace").resizable().scaledToFill().frame(width: 44, height: 44).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split it with friends").font(.headline).foregroundStyle(Theme.ink)
                    Text(splitAfter ? "Penny will help you send the links next." : "Shared this one? Get paid back.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: splitAfter ? "checkmark.circle.fill" : "circle").font(.title2)
                    .foregroundStyle(splitAfter ? Theme.accent : Theme.line)
                    .scaleEffect(splitAfter ? 1.1 : 1)
            }
            .padding(14)
            .background(splitAfter ? Theme.softGreen : Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button(action: save) {
            Text(canSave ? "Save $\(shownAmount)" : merchant.isEmpty ? "Say what it was for" : "Add an amount")
                .font(.title3.weight(.bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 58)
                .background(Theme.accent.opacity(canSave ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain).disabled(!canSave)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.background)
        .accessibilityIdentifier("payment-save")
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary).textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Load and save

    private func load() {
        guard let tx = editing else { return }
        step = .details
        amountText = tx.amount > 0 ? WalletStore.typing(String(format: "%.2f", tx.amount)) : ""
        merchant = tx.merchant
        category = tx.category
        pickedCategory = true
        card = tx.card
        date = tx.date
        note = tx.note ?? ""
        items = tx.items
        itemPrices = Dictionary(uniqueKeysWithValues: tx.items.map { ($0.id, $0.price.map { String(format: "%.2f", $0) } ?? "") })
        if tx.cents == 0 { step = .amount }
    }

    private func save() {
        guard canSave else { refusals += 1; return }
        saves += 1
        let kept = items.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if var tx = editing {
            tx.amount = amount
            tx.merchant = merchant.trimmingCharacters(in: .whitespaces)
            tx.category = category
            tx.card = card
            tx.date = date
            tx.note = cleanNote.isEmpty ? nil : cleanNote
            tx.items = kept
            store.update(tx)
            dismiss()
            return
        }
        let saved = store.add(merchant: merchant, amount: amount, date: date, card: card, category: category,
                              source: .manual, items: kept, note: cleanNote.isEmpty ? nil : cleanNote)
        if splitAfter { withAnimation { splitting = saved.id } } else { dismiss() }
    }
}

/// Little Wallet's own number pad: big round keys, like Venmo's.
struct Keypad: View {
    enum Key: Equatable {
        case digit(Int), point, delete
        var digit: Int { if case let .digit(d) = self { return d }; return 0 }
    }
    let press: (Key) -> Void

    private let rows: [[Key]] = [[.digit(1), .digit(2), .digit(3)], [.digit(4), .digit(5), .digit(6)],
                                 [.digit(7), .digit(8), .digit(9)], [.point, .digit(0), .delete]]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        KeyButton(key: rows[row][column], press: press)
                    }
                }
            }
        }
    }

    private struct KeyButton: View {
        let key: Key
        let press: (Key) -> Void
        @State private var down = false

        var body: some View {
            Button { press(key) } label: {
                Group {
                    switch key {
                    case .digit(let d): Text("\(d)").font(.system(size: 30, weight: .semibold, design: .rounded))
                    case .point: Text(".").font(.system(size: 34, weight: .heavy, design: .rounded))
                    case .delete: Image(systemName: "delete.left").font(.system(size: 22, weight: .semibold))
                    }
                }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 62)
                .background(key == .delete || key == .point ? Color.clear : Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(key == .delete ? "Delete" : key == .point ? "Decimal point" : "\(key.digit)")
        }
    }
}

/// Keys sink a little under your finger.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A quick side-to-side "no", like a wrong passcode.
private struct Shake: GeometryEffect {
    var times: CGFloat
    var animatableData: CGFloat {
        get { times }
        set { times = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(times * .pi * 4), y: 0))
    }
}
