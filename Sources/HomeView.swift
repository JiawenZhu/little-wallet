import SwiftUI

/// The month at a glance: what you spent, on what, with which card, and every payment by day.
struct HomeView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject private var splits = SplitService.shared
    @ObservedObject private var paypal = PayPalLink.shared
    @ObservedObject private var categories = CategoryLibrary.shared
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!.start
    @State private var filter: SpendCategory?
    @State private var adding = false
    @State private var speaking = false
    @State private var scanning = false
    @State private var settling = false
    @State private var settingUp = false
    @State private var asking = false
    @State private var reporting = false
    @State private var paypalOpen = false
    @State private var editingCategories = false
    @State private var pickingMonth = false
    @State private var openCategory: SpendCategory?
    @State private var opened: Payment?
    @State private var editing: Payment?
    @State private var splitting: Payment?
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { .current }
    private var monthPayments: [Payment] {
        payments.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
    }
    private var shown: [Payment] { monthPayments.filter { filter == nil || $0.category == filter } }
    /// Every payment with what friends paid back taken off, so totals show what you really spent.
    private var payments: [Payment] { splits.netted(store.transactions) }
    private var total: Double { monthPayments.reduce(0) { $0 + $1.spent } }
    private var byCategory: [SpendCategory: Double] {
        monthPayments.reduce(into: [:]) { $0[$1.category, default: 0] += $1.spent }
    }
    private var owed: (name: String, cents: Int, people: Int)? {
        let open = SettleBalance.from(splits.splits).filter { $0.owed > 0 }
        guard let top = open.first else { return nil }
        return (top.person.name, open.reduce(0) { $0 + $1.owed }, open.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                totalBlock
                categoryChart
                askCard
                if !cards.isEmpty { cardStrip }
                if store.lastTapAt == nil { setupBanner }
                if let owed { settleBanner(owed) }
                PayPalCard(link: paypal) { paypalOpen = true }
                if shown.isEmpty { emptyState } else { paymentList }
            }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .bottom) { bottomBar }
        .sheet(isPresented: $adding) { AddPaymentSheet(store: store) }
        .sheet(isPresented: $scanning) { ReceiptScanSheet(store: store) }
        .fullScreenCover(isPresented: $speaking) { VoiceAddSheet(store: store) }
        .sheet(isPresented: $settling) {
            SettleUpPane(flipNext: { settling = false }).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $settingUp) { TapSetupSheet(store: store) }
        .fullScreenCover(isPresented: $asking) { AskView(store: store) }
        .sheet(isPresented: $reporting) { ReportSheet(store: store, month: month) }
        .sheet(isPresented: $paypalOpen) { PayPalSheet(store: store) }
        .sheet(isPresented: $editingCategories) { CategoriesSheet(store: store) }
        .sheet(isPresented: $pickingMonth) {
            MonthPicker(payments: payments, month: Binding(get: { month }, set: { new in
                withAnimation(.snappy) { month = new; filter = nil }
                grown = false
                withAnimation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.75).delay(0.15)) { grown = true }
            }))
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $openCategory) { category in
            CategoryMonthSheet(store: store, category: category, month: month)
                .presentationDetents([.large])
        }
        .task {
            // New PayPal and Venmo payments arrive quietly each time the app opens.
            if paypal.connected { await paypal.sync(store: store) }
        }
        .sheet(item: $opened) { tx in PaymentDetailSheet(store: store, transactionID: tx.id) }
        .sheet(item: $editing) { tx in AddPaymentSheet(store: store, editing: tx) }
        .sheet(item: $splitting) { tx in SplitSheet(store: store, transactionID: tx.id) }
        .onChange(of: store.openRequest) { _, id in
            // A tapped "saved" notification opens its payment.
            guard let id, let tx = store.transaction(id) else { return }
            store.openRequest = nil
            opened = tx
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.75).delay(0.1)) { grown = true }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-open-voice") { speaking = true }
            if ProcessInfo.processInfo.arguments.contains("-open-add") { adding = true }
            if ProcessInfo.processInfo.arguments.contains("-open-scan") { scanning = true }
            if ProcessInfo.processInfo.arguments.contains("-open-setup") { settingUp = true }
            if ProcessInfo.processInfo.arguments.contains("-open-ask") { asking = true }
            if ProcessInfo.processInfo.arguments.contains("-open-report") { reporting = true }
            if ProcessInfo.processInfo.arguments.contains("-open-paypal") { paypalOpen = true }
            if ProcessInfo.processInfo.arguments.contains("-open-categories") { editingCategories = true }
            if ProcessInfo.processInfo.arguments.contains("-open-month") { pickingMonth = true }
            if ProcessInfo.processInfo.arguments.contains("-open-groceries") { openCategory = .groceries }
            #endif
        }
    }

    // MARK: - Header and total

    private var header: some View {
        HStack(spacing: 12) {
            Image("WalletMark").resizable().scaledToFit().frame(width: 46, height: 46)
                .accessibilityHidden(true)
            Text("Little Wallet").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.ink)
            Spacer()
            Button { settingUp = true } label: {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 46).background(Theme.card, in: Circle())
            }
            .accessibilityLabel("Apple Pay tracking setup")
            Button { reporting = true } label: {
                Image(systemName: "doc.text.below.ecg").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 46).background(Theme.card, in: Circle())
            }
            .accessibilityLabel("Reports")
            .accessibilityIdentifier("open-reports")
            Button { adding = true } label: {
                Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(Theme.accent, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 8, y: 4)
            }
            .accessibilityLabel("Add a payment").accessibilityIdentifier("add-payment")
        }
        .buttonStyle(.plain)
    }

    private var totalBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dollars(total))
                .font(.system(size: 50, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.ink).contentTransition(.numericText())
                .minimumScaleFactor(0.6).lineLimit(1)
            HStack(spacing: 6) {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Button { pickingMonth = true } label: {
                    HStack(spacing: 4) {
                        Text(monthTitle)
                        Image(systemName: "chevron.down").font(.caption.weight(.heavy))
                    }
                    .font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("\(monthTitle). Pick a month")
                .accessibilityIdentifier("pick-month")
                if !calendar.isDate(month, equalTo: .now, toGranularity: .month) {
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next month")
                }
                Spacer()
                Button { editingCategories = true } label: {
                    Label("Categories", systemImage: "square.grid.2x2")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line))
                }
                .accessibilityIdentifier("edit-categories")
            }
            .font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary).buttonStyle(.plain)
        }
        .animation(.snappy, value: total)
    }

    /// "November spending", with the year when it isn't this year.
    private var monthTitle: String {
        let sameYear = calendar.isDate(month, equalTo: .now, toGranularity: .year)
        return (sameYear ? month.formatted(.dateTime.month(.wide)) : month.formatted(.dateTime.month(.wide).year())) + " spending"
    }

    private func shiftMonth(_ by: Int) {
        guard let next = calendar.date(byAdding: .month, value: by, to: month) else { return }
        withAnimation(.snappy) { month = next; filter = nil }
        grown = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.75).delay(0.05)) { grown = true }
    }

    // MARK: - Categories

    private var categoryChart: some View {
        let all = categories.visible.map(\.category)
        let top = max(byCategory.values.max() ?? 0, 1)
        // Up to eight share the width; more scroll sideways.
        let fits = all.count <= 8
        // Narrow enough when scrolling that part of the next column peeks in.
        let columns = HStack(alignment: .top, spacing: fits ? 8 : 6) {
            ForEach(Array(all.enumerated()), id: \.element) { index, category in
                chartColumn(category, index: index, top: top)
                    .frame(width: fits ? nil : 44)
                    .frame(maxWidth: fits ? .infinity : nil)
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            if fits {
                columns
            } else {
                ScrollView(.horizontal) { columns.padding(.horizontal, 2) }.scrollIndicators(.hidden)
            }
        }
        .overlay(alignment: .top) {
            // The baseline under the bars, across every column.
            Rectangle().fill(Theme.line).frame(height: 1).offset(y: 165).allowsHitTesting(false)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }

    private func chartColumn(_ category: SpendCategory, index: Int, top: Double) -> some View {
        let value = byCategory[category] ?? 0
        let on = openCategory == nil || openCategory == category
        return VStack(spacing: 0) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                if value > 0 {
                    Text(shortDollars(value)).font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        .opacity(grown ? 1 : 0)
                }
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(category.barColor.gradient)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .frame(height: grown ? max(10, 130 * value / top) : 10)
                    .opacity(on ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.7).delay(Double(index) * 0.04), value: grown)
            }
            .frame(height: 160)
            VStack(spacing: 4) {
                CategoryIcon(category: category, size: 36)
                Text(category.short).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.top, 11)
            .opacity(on ? 1 : 0.35)
        }
        .contentShape(Rectangle())
        .onTapGesture { openCategory = category }
        .accessibilityElement()
        .accessibilityLabel("\(category.title), \(dollars(value))")
        .accessibilityHint("Shows its payments")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Ask

    private var askCard: some View {
        let analyst = Analyst(payments: payments, balances: SettleBalance.from(splits.splits))
        let first = Suggester.questions(analyst, memory: AskMemory.shared.interest, recent: AskMemory.shared.recent, limit: 1).first
        return Button { asking = true } label: {
            HStack(spacing: 12) {
                PennyAvatar(size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask Penny").font(.headline).foregroundStyle(Theme.ink)
                    Text(first.map { "“\($0.text)”" } ?? "Questions about your spending")
                        .font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ask-open")
    }

    // MARK: - Cards

    private var cards: [(name: String, spent: Double)] {
        let names = Set(monthPayments.map(\.card)).filter { !$0.isEmpty }
        return names.map { name in (name, monthPayments.filter { $0.card == name }.reduce(0) { $0 + $1.spent }) }
            .sorted { $0.spent > $1.spent }
    }

    private var cardStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(cards.enumerated()), id: \.element.name) { index, card in
                    CardFace(name: card.name, detail: dollars(card.spent), style: index)
                        .frame(width: 168)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -18)
    }

    // MARK: - Banners

    private var setupBanner: some View {
        Button { settingUp = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "wave.3.right.circle.fill").font(.system(size: 30)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Track every Apple Pay tap").font(.headline)
                    Text("A two-minute setup in Shortcuts").font(.subheadline).opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white).padding(16)
            .background(LinearGradient(colors: [Color(hex: "#E8875A"), Color(hex: "#D9806B"), Color(hex: "#B98AA0")],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityIdentifier("setup-banner")
    }

    private func settleBanner(_ owed: (name: String, cents: Int, people: Int)) -> some View {
        Button { settling = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                    .frame(width: 50, height: 50).background(Theme.card, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settle up").font(.headline).foregroundStyle(Theme.ink)
                    Text(owed.people == 1 ? "\(owed.name) owes you \(money(owed.cents))" : "\(owed.people) friends owe you \(money(owed.cents))")
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
            }
            .padding(14).background(Theme.softGreen, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Payments

    private var days: [(day: Date, payments: [Payment])] {
        Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    private var paymentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let filter {
                HStack {
                    Text(filter.title).font(.headline).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Show all") { withAnimation(.snappy) { self.filter = nil } }.font(.subheadline.weight(.semibold))
                }
                .padding(.bottom, 8)
            }
            ForEach(days, id: \.day) { group in
                HStack {
                    Text(dayTitle(group.day)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(dollars(group.payments.reduce(0) { $0 + $1.spent })).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 14).padding(.bottom, 4)
                ForEach(group.payments) { tx in
                    PaymentRow(tx: tx, split: splits.mark(for: tx.splitIDs))
                        .contentShape(Rectangle())
                        // A tap with no amount goes straight to filling it in.
                        .onTapGesture { if tx.cents == 0 { editing = tx } else { opened = tx } }
                        .contextMenu {
                            Button(tx.cents == 0 ? "Add amount" : "Edit", systemImage: "pencil") { editing = tx }
                            Button("Split the bill", systemImage: "person.2") { splitting = tx }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { withAnimation { store.delete(tx.id) } }
                        }
                    if tx.id != group.payments.last?.id { Divider().padding(.leading, 62) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image("CatOther").resizable().scaledToFit().frame(width: 84, height: 84)
            Text(filter == nil ? "No payments yet this month" : "No \(filter!.title.lowercased()) this month")
                .font(.headline).foregroundStyle(Theme.ink)
            Text("Pay with Apple Pay, tap + to add one, or just say it.")
                .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func dayTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: - Bottom bar

    private func barButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).frame(height: 60)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { speaking = true } label: {
                Label("Say it", systemImage: "mic.fill").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .accessibilityIdentifier("voice-add")
            barButton("Scan", icon: "doc.text.viewfinder") { scanning = true }
                .accessibilityIdentifier("scan-receipt")
            barButton("Type it", icon: "keyboard") { adding = true }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
        .background(Theme.background.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 24).offset(y: -24).allowsHitTesting(false)
        }
    }
}

/// One payment in the list.
struct PaymentRow: View {
    let tx: Payment
    var split: SplitMark?

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: tx.category, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    // A receipt photo is kept with this payment.
                    if ReceiptVault.has(tx.id) {
                        ReceiptThumb(id: tx.id, width: 18).rotationEffect(.degrees(8)).offset(x: 6, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.merchant).font(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if tx.cents == 0 {
                    Text("Add amount").font(.subheadline.weight(.bold)).foregroundStyle(Color(hex: "#D9734A"))
                } else if let back = tx.paidBack, back > 0 {
                    // Friends paid some back: your share, with the full price crossed out under it.
                    Text(dollars(tx.spent)).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(tx.formattedAmount).font(.caption.weight(.semibold)).monospacedDigit()
                        .strikethrough().foregroundStyle(Theme.secondary)
                } else {
                    Text(tx.formattedAmount).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                }
                if let split {
                    Label(split == .settled ? "Settled" : "Split", systemImage: split == .settled ? "checkmark" : "person.2.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.softGreen, in: Capsule())
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if let back = tx.paidBack, back > 0 { return "\(dollars(back)) paid back · your share" }
        var parts = [tx.category.title]
        if !tx.card.isEmpty { parts.append(tx.card) } else if tx.source != .manual { parts.append(tx.source.label) }
        if tx.items.count > 1 { parts.append("\(tx.items.count) items") }
        return parts.joined(separator: " · ")
    }
}

/// A payment card from the Codex set, with its name and what it spent.
struct CardFace: View {
    let name: String
    var detail: String = ""
    let style: Int

    private static let faces = ["CardLeaf", "CardPinstripe", "CardWave", "CardStitch"]
    private var light: Bool { style % Self.faces.count == 1 }

    var body: some View {
        let method = PayMethods.info(for: name)
        if method.isCard { card } else { tile(method) }
    }

    /// Cash, apps, the bank and pay-later get a flat tile with their mark instead of a plastic card.
    private func tile(_ method: PayMethod) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: method.hex).opacity(0.85), Color(hex: method.hex)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .aspectRatio(1.586, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                Image(systemName: method.symbol).font(.system(size: 54, weight: .bold)).foregroundStyle(.white.opacity(0.16))
                    .offset(x: 10, y: -6).clipped()
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: method.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline.weight(.bold)).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption.weight(.semibold)).monospacedDigit().opacity(0.85) }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            .accessibilityElement(children: .combine)
    }

    private var card: some View {
        Image(Self.faces[style % Self.faces.count]).resizable().scaledToFit()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline.weight(.bold)).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption.weight(.semibold)).monospacedDigit().opacity(0.85) }
                }
                .foregroundStyle(light ? Theme.ink : .white)
                .padding(12)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            .accessibilityElement(children: .combine)
    }
}

/// "$1,284.60"
func dollars(_ amount: Double) -> String {
    amount.formatted(.currency(code: "USD"))
}

/// "$1.2k" for the chart's small labels.
func shortDollars(_ amount: Double) -> String {
    amount >= 1000 ? String(format: "$%.1fk", amount / 1000) : String(format: "$%.0f", amount)
}
