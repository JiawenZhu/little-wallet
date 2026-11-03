import SwiftUI

/// Split any payment: pick who shared it, tap who had what, and send each friend a link where they pay their
/// share with Venmo or PayPal. The money goes straight to you.
struct SplitSheet: View {
    @ObservedObject var store: WalletStore
    let transactionID: UUID
    @Environment(\.openURL) private var openURL
    /// People to start with, by name ("Sam", "Kate Bell"): voice splits pick them for you.
    var presetPeople: [String] = []
    @ObservedObject private var service = SplitService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sharing: [String] = []
    @State private var assigned: [UUID: [String]] = [:]
    @State private var prices: [UUID: Double] = [:]
    @State private var sent: SentSplit?
    @State private var sending = false
    @State private var error: String?
    @State private var addingFriend = false
    @State private var venmoFor: SplitPerson?
    @State private var venmoText = ""
    @State private var venmoInvalid = false
    @State private var pricing: LineItem?
    @State private var priceText = ""
    @State private var appeared = false
    @State private var tapped = 0
    /// The name friends see on their link, when the account doesn't have one.
    @AppStorage("split-my-name") private var savedName = ""
    @State private var askingName = false
    @State private var nameDraft = ""
    /// Your own Venmo username: friends' pages open the Venmo app to you when PayPal can't show its Venmo button.
    @AppStorage("split-my-venmo") private var myVenmo = ""
    @State private var askingVenmo = false
    @State private var venmoDraft = ""
    @State private var myVenmoInvalid = false
    /// For a pile: which of its things are being split, picked like photos in Photos.
    @State private var chosen: Set<UUID> = []
    /// Share the whole bill evenly, or say who had which item.
    @State private var mode: SplitMode = .evenly
    /// By item: whose things are being ticked right now.
    @State private var focus: String?
    @State private var tears = 0
    @Namespace private var modeSpace

    private var transaction: Payment? { store.transaction(transactionID) }
    private var allItems: [LineItem] { transaction?.splitLines ?? [] }
    private var itemIDs: [UUID] { allItems.map(\.id) }
    private var items: [LineItem] { allItems.filter { chosen.contains($0.id) } }

    private var myName: String { savedName }

    private var me: SplitPerson {
        SplitPerson(id: "me", name: myName.isEmpty ? "You" : myName, colorIndex: 0, isMe: true, venmo: myVenmo.isEmpty ? nil : myVenmo)
    }

    /// You, then friends you've split with before.
    private var everyone: [SplitPerson] { [me] + service.friends }

    private var people: [SplitPerson] { everyone.filter { sharing.contains($0.id) } }

    private var title: String { transaction?.merchant ?? "Payment" }

    private func emoji(_ item: LineItem) -> String {
        let category = transaction?.category ?? .other
        return item.id == transactionID ? category.emoji : SplitService.emoji(for: item.name, category: category)
    }

    private func cents(_ item: LineItem) -> Int { Int(((prices[item.id] ?? item.price ?? 0) * 100).rounded()) }

    private var byItem: Bool { mode == .byItem && allItems.count > 1 }
    /// The whole payment as one line, for an even split of a payment with items.
    private var wholeLine: LineItem {
        let amount = transaction?.amount ?? 0
        return LineItem(id: transactionID, name: title, quantity: 1,
                        price: amount > 0 ? amount : Double(allItems.reduce(0) { $0 + cents($1) }) / 100)
    }
    /// What's being shared out: the picked items, or the whole bill.
    private var lines: [LineItem] { byItem ? items : allItems.count > 1 ? [wholeLine] : allItems }

    /// Tax, tip and fees on top of the items: by item, each line carries its part, so whoever had more pays more of it.
    private var extrasCents: Int {
        guard let transaction, allItems.count > 1 else { return 0 }
        return max(0, transaction.cents - allItems.reduce(0) { $0 + cents($1) })
    }
    private var extraShares: [UUID: Int] {
        guard byItem, extrasCents > 0 else { return [:] }
        let all = allItems.reduce(0) { $0 + cents($1) }, picked = items.reduce(0) { $0 + cents($1) }
        guard all > 0 else { return [:] }
        let part = Int((Double(extrasCents) * Double(picked) / Double(all)).rounded())
        return Dictionary(uniqueKeysWithValues: zip(items.map(\.id), SplitMath.spread(part, weights: items.map(cents))))
    }
    /// A line's price with its part of the tax and tip.
    private func charged(_ item: LineItem) -> Int { cents(item) + (extraShares[item.id] ?? 0) }

    /// Who pays for a line. By item, a thing nobody has claimed is shared by everyone, so nothing goes unpaid.
    private func who(_ item: LineItem) -> [String] {
        guard byItem else { return sharing }
        let claimed = claimers(item)
        return claimed.isEmpty ? sharing : claimed
    }
    private func claimers(_ item: LineItem) -> [String] { sharingOrder((assigned[item.id] ?? []).filter(sharing.contains)) }
    private var totals: [String: Int] {
        SplitMath.totals(lines: lines.map { (charged($0), sharingOrder(who($0))) }, people: sharing)
    }
    /// The server splits each item in the order people are listed; keep that order so totals match exactly.
    private func sharingOrder(_ ids: [String]) -> [String] { everyone.map(\.id).filter(ids.contains) }
    private var grandTotal: Int { lines.reduce(0) { $0 + charged($1) } }
    private var owedToMe: Int { totals.filter { $0.key != me.id }.values.reduce(0, +) }
    /// PayPal and Venmo (and the split server) take at most $10,000 for one item.
    static let maxLineCents = 1_000_000
    private var tooBig: Bool { lines.contains { charged($0) > Self.maxLineCents } }
    private var canSend: Bool {
        sharing.count > 1 && grandTotal > 0 && lines.allSatisfy { !who($0).isEmpty } && owedToMe > 0 && !tooBig
    }

    var body: some View {
        NavigationStack {
            Group {
                if let sent {
                    SentSplitView(split: sent, onNewSplit: { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { self.sent = nil } })
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                } else {
                    compose.transition(.opacity)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(sent == nil ? "Split the bill" : "Payment links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear(perform: start)
        .sheet(isPresented: $addingFriend) {
            FriendPicker(added: Set(sharing)) { person in
                if !sharing.contains(person.id) { toggle(person) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("\(venmoFor?.name ?? "Friend") on Venmo", isPresented: Binding(get: { venmoFor != nil }, set: { if !$0 { venmoFor = nil } })) {
            TextField("@username or phone", text: $venmoText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") {
                if let person = venmoFor, !service.setVenmo(venmoText, for: person.id) { venmoInvalid = true }
                venmoFor = nil
            }
            Button("Cancel", role: .cancel) { venmoFor = nil }
        } message: {
            Text("Venmo requests will go straight to them.")
        }
        .alert("That doesn't look like a Venmo username or phone number.", isPresented: $venmoInvalid) { Button("OK") {} }
        .alert("Price of \(pricing?.name ?? "item")", isPresented: Binding(get: { pricing != nil }, set: { if !$0 { pricing = nil } })) {
            TextField("0.00", text: $priceText).keyboardType(.decimalPad)
            Button("Save") { savePrice() }
            Button("Cancel", role: .cancel) { pricing = nil }
        } message: {
            Text("Check your receipt for the exact price.")
        }
        .alert("Your Venmo username", isPresented: $askingVenmo) {
            TextField("@username", text: $venmoDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") {
                let handle = venmoDraft.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["@"])
                if handle.isEmpty { myVenmo = "" }
                else if handle.count >= 5, handle.count <= 30, handle.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), handle.allSatisfy(\.isASCII) { myVenmo = handle }
                else { myVenmoInvalid = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If a friend's phone can't show PayPal's Venmo button, their link opens the Venmo app to you instead.")
        }
        .alert("That doesn't look like a Venmo username.", isPresented: $myVenmoInvalid) { Button("OK") {} }
        .alert("Your name", isPresented: $askingName) {
            TextField("First name", text: $nameDraft).textInputAutocapitalization(.words)
            Button("Send") {
                savedName = String(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                if !savedName.isEmpty { send() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Friends see who they're paying back.")
        }
        .sensoryFeedback(.selection, trigger: tapped)
    }

    // MARK: - Compose

    private var compose: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ReceiptHeader(title: title, transaction: transaction, total: grandTotal, count: byItem ? items.count : allItems.count)
                    .scaleEffect(appeared ? 1 : 0.94).opacity(appeared ? 1 : 0)

                if allItems.count > 1 { modePicker }

                if sharing.count > 1 {
                    TearingReceipt(pieces: pieces, total: grandTotal, tears: tears)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }


                section("Who's sharing?", detail: sharing.count > 1 ? "\(sharing.count) people" : "Add someone") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(Array(everyone.enumerated()), id: \.element.id) { index, person in
                                PersonBubble(person: person, selected: sharing.contains(person.id), amount: totals[person.id])
                                    .onTapGesture { toggle(person) }
                                    .contextMenu {
                                        if !person.isMe && service.friends.contains(person) {
                                            Button(person.venmo == nil ? "Add Venmo username" : "Venmo: \(Venmo.label(person.venmo!))", systemImage: "at") {
                                                venmoText = person.venmo.map { $0.allSatisfy(\.isNumber) ? $0 : "@" + $0 } ?? ""
                                                venmoFor = person
                                            }
                                            Button("Forget \(person.name)", systemImage: "person.badge.minus", role: .destructive) {
                                                sharing.removeAll { $0 == person.id }
                                                service.forget(person)
                                            }
                                        }
                                    }
                                    .offset(y: appeared ? 0 : 24).opacity(appeared ? 1 : 0)
                                    .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.05 * Double(index) + 0.1), value: appeared)
                            }
                            Button { addingFriend = true } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .semibold))
                                        .frame(width: 54, height: 54)
                                        .background(Circle().strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
                                        .foregroundStyle(Theme.accent)
                                    Text("Add").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                                    Text(" ").font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Search friends")
                            .accessibilityIdentifier("split-add-friend")
                        }
                        .padding(.horizontal, 4).padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
                    // Selected people glow; don't cut the glow off at the row's edges.
                    .scrollClipDisabled()
                    myVenmoRow
                }

                if byItem && !items.isEmpty && sharing.count > 1 {
                    section("Who had what?", detail: "Tick each person's things") { checklist }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !byItem, lines.count == 1, let line = lines.first {
                    evenNote(line)
                }

                if tooBig {
                    Label("PayPal and Venmo take up to \(money(Self.maxLineCents)) per item. Lower the price, or split it into smaller items.",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.footnote).foregroundStyle(Color(red: 0.6, green: 0.38, blue: 0.1))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.99, green: 0.94, blue: 0.84), in: RoundedRectangle(cornerRadius: 14))
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Color(red: 0.71, green: 0.28, blue: 0.24))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.97, green: 0.89, blue: 0.87), in: RoundedRectangle(cornerRadius: 14))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { sendBar }
    }

    private var myVenmoRow: some View {
        Button {
            venmoDraft = myVenmo.isEmpty ? "" : "@" + myVenmo
            askingVenmo = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "v.circle.fill").font(.system(size: 18))
                    .foregroundStyle(.white, Color(red: 0, green: 0.55, blue: 1))
                Text(myVenmo.isEmpty ? "Add your Venmo so friends can pay you there" : "Friends can pay your Venmo @\(myVenmo)")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: myVenmo.isEmpty ? "plus" : "pencil").font(.caption2.weight(.bold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("split-my-venmo")
    }

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
            }
            content()
        }
    }

    private var sendBar: some View {
        VStack(spacing: 10) {
            if sharing.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(people) { person in
                            HStack(spacing: 6) {
                                Circle().fill(person.color).frame(width: 8, height: 8)
                                Text(person.isMe ? "You keep" : person.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                                Text(money(totals[person.id] ?? 0)).font(.caption.weight(.bold)).monospacedDigit()
                                    .contentTransition(.numericText())
                                    .foregroundStyle(Theme.ink)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Theme.card, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button(action: send) {
                HStack(spacing: 10) {
                    if sending { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
                    Text(sending ? "Making links…" : owedToMe > 0 ? "Send links · get back \(money(owedToMe))" : "Send payment links")
                        .contentTransition(.numericText())
                }
                .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                .background(canSend ? Theme.accent : Theme.secondary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSend || sending)
            .accessibilityIdentifier("split-send")
            Button(action: requestWithVenmo) {
                HStack(spacing: 8) {
                    Text("V").font(.system(size: 15, weight: .black, design: .rounded))
                        .frame(width: 22, height: 22).background(.white, in: Circle()).foregroundStyle(Self.venmoBlue)
                    Text(people.count > 2 ? "Request each in Venmo" : "Request in Venmo")
                }
                .font(.headline).frame(maxWidth: .infinity).frame(height: 50)
                .background(canSend ? Self.venmoBlue : Theme.secondary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSend || sending)
            .accessibilityHint("Opens Venmo with each friend's exact share filled in")
            .accessibilityIdentifier("split-venmo")
            Text("Links: friends pay with Apple Cash, Venmo or PayPal. Venmo: you request each share right in Venmo.")
                .font(.caption2).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sharing.count > 1)
        .animation(.snappy, value: totals)
    }

    // MARK: - Actions

    private func start() {
        if sharing.isEmpty {
            sharing = [me.id]
            for name in presetPeople {
                let first = name.split(separator: " ").first.map(String.init) ?? name
                let person = everyone.first { !$0.isMe && ($0.name.caseInsensitiveCompare(name) == .orderedSame
                    || $0.name.split(separator: " ").first.map(String.init)?.caseInsensitiveCompare(first) == .orderedSame) }
                    ?? service.rememberFriend(named: name)
                if let person, !sharing.contains(person.id) { sharing.append(person.id) }
            }
            sharing = everyone.map(\.id).filter(sharing.contains)
        }
        if chosen.isEmpty { chosen = Set(itemIDs) }
        for item in allItems where prices[item.id] == nil { prices[item.id] = item.price ?? 0 }
        // Pick up where you left off if these items were split already.
        if sent == nil, let latest = service.splits(for: itemIDs + [transactionID]).first { sent = latest }
        // A receipt's even split was filed under the payment; one by item, under its things.
        if let sent, allItems.count > 1, !sent.itemIDs.contains(transactionID) { mode = .byItem }
        withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
    }

    private func toggle(_ person: SplitPerson) {
        tapped += 1
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if sharing.contains(person.id) {
                guard !person.isMe else { return }
                sharing.removeAll { $0 == person.id }
                for key in assigned.keys { assigned[key]?.removeAll { $0 == person.id } }
                if focus == person.id { focus = nil }
            } else {
                sharing = everyone.map(\.id).filter { sharing.contains($0) || $0 == person.id }
                if byItem { focus = person.id }
            }
            tears += 1
            error = nil
        }
    }

    /// Ticks or unticks a thing for someone. Ticked by two people, they share it; ticked by nobody, everyone does.
    private func toggle(_ person: SplitPerson, on item: LineItem) {
        tapped += 1
        var list = claimers(item)
        if list.contains(person.id) { list.removeAll { $0 == person.id } } else { list.append(person.id) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            assigned[item.id] = list.isEmpty ? nil : sharingOrder(list)
        }
    }

    private func savePrice() {
        guard let item = pricing else { return }
        let value = Double(priceText.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }) ?? 0
        withAnimation(.snappy) { prices[item.id] = max(0, min(value, 10_000)) }
        store.setPrice(value > 0 ? value : nil, line: item.id, in: transactionID)
        pricing = nil
    }

    private func send() {
        guard canSend else { return }
        guard !myName.isEmpty else { nameDraft = ""; askingName = true; return }
        sending = true
        error = nil
        let lines = lines.map { SplitService.Line(item: $0, price: Double(charged($0)) / 100, people: sharingOrder(who($0)), emoji: emoji($0)) }
        Task {
            do {
                let result = try await service.send(title: title, method: transaction.map(Self.method) ?? "Apple Pay", paidAt: transaction?.date ?? .now,
                                                    me: me, people: people, lines: lines)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { sent = result }
            } catch {
                withAnimation(.snappy) { self.error = error.localizedDescription }
            }
            sending = false
        }
    }

    private func name(_ id: String) -> String { everyone.first { $0.id == id }?.name ?? "" }

    // MARK: - Evenly or by item

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(SplitMode.allCases, id: \.self) { option in
                Button {
                    guard mode != option else { return }
                    tapped += 1
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        mode = option
                        if option == .byItem, focus == nil { focus = people.first(where: { !$0.isMe })?.id ?? me.id }
                        tears += 1
                        error = nil
                    }
                } label: {
                    VStack(spacing: 2) {
                        Label(option.title, systemImage: option.icon).font(.subheadline.weight(.bold))
                        Text(option.detail).font(.caption2).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .foregroundStyle(mode == option ? .white : Theme.ink)
                    .background {
                        if mode == option {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent)
                                .matchedGeometryEffect(id: "mode", in: modeSpace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
                .accessibilityIdentifier("split-mode-\(option.rawValue)")
            }
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }

    /// Each person's piece of the torn receipt: what they pay and, by item, what they had.
    private var pieces: [TearingReceipt.Piece] {
        people.map { person in
            let had = byItem ? items.filter { claimers($0).contains(person.id) }.map(emoji) : []
            return TearingReceipt.Piece(id: person.id, name: person.isMe ? "You" : person.name, initial: person.initial,
                                        color: person.color, colors: person.colors, cents: totals[person.id] ?? 0, emojis: had)
        }
    }

    /// By item: pick a person, then tick what they had, like a checklist.
    private var checklist: some View {
        let current = people.first { $0.id == focus } ?? people.first!
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(people) { person in
                        let on = person.id == current.id
                        let count = items.filter { claimers($0).contains(person.id) }.count
                        Button {
                            tapped += 1
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { focus = person.id }
                        } label: {
                            HStack(spacing: 6) {
                                Text(person.initial).font(.caption.weight(.heavy))
                                    .frame(width: 24, height: 24).background(person.avatar, in: Circle()).foregroundStyle(.white)
                                Text(person.isMe ? "You" : person.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if count > 0 {
                                    Text("\(count)").font(.caption2.weight(.heavy)).monospacedDigit()
                                        .padding(.horizontal, 6).frame(height: 18)
                                        .background(on ? Color.white.opacity(0.3) : person.color.opacity(0.18), in: Capsule())
                                        .contentTransition(.numericText())
                                }
                            }
                            .padding(.leading, 5).padding(.trailing, 12).frame(height: 36)
                            .background(on ? person.color : Theme.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? .clear : Theme.line))
                            .foregroundStyle(on ? .white : Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("split-focus-\(person.isMe ? "you" : person.name)")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Text("What did \(current.isMe ? "you" : current.name) have?")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    checkRow(item, for: current)
                    if item.id != items.last?.id { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
            if extrasCents > 0 {
                Label("The \(money(extrasCents)) tax and tip are shared by how much each person had.", systemImage: "percent")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Label("Anything nobody ticks is shared by everyone.", systemImage: "person.3")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private func checkRow(_ item: LineItem, for person: SplitPerson) -> some View {
        let claimed = claimers(item)
        let on = claimed.contains(person.id)
        return Button { toggle(person, on: item) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? person.color : Color.clear)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(on ? person.color : Theme.secondary.opacity(0.45), lineWidth: 2)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(width: 28, height: 28)
                .scaleEffect(on ? 1.06 : 1)
                Text(emoji(item)).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name)
                        .font(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Group {
                        if claimed.isEmpty { Text("Shared by everyone") }
                        else if claimed.count == 1 { Text(claimed[0] == me.id ? "Yours" : "\(name(claimed[0]))'s") }
                        else { Text(claimed.map { $0 == me.id ? "You" : name($0) }.joined(separator: " & ") + " · \(money(cents(item) / claimed.count)) each") }
                    }
                    .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: -6) {
                    ForEach(claimed.compactMap { id in people.first { $0.id == id } }) { owner in
                        Circle().fill(owner.avatar).frame(width: 18, height: 18)
                            .overlay(Text(owner.initial).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white))
                            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.5))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(money(cents(item))).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .onTapGesture { priceText = String(format: "%.2f", Double(cents(item)) / 100); pricing = item }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: on)
        .accessibilityLabel("\(person.isMe ? "You" : person.name) had \(item.name)")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("split-item-\(item.name)")
    }

    /// Splitting evenly: the bill, how many ways, and a way to fix the amount.
    private func evenNote(_ line: LineItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "equal.circle.fill").font(.title3).foregroundStyle(Theme.accent)
            Text(sharing.count > 1 ? "\(money(charged(line))) split \(sharing.count) ways" : "Add who's sharing to split \(money(charged(line)))")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Spacer()
            Button("Edit") { priceText = String(format: "%.2f", Double(cents(line)) / 100); pricing = line }
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static let venmoBlue = Color(red: 0, green: 0.55, blue: 1)

    /// Requests each friend's exact share in Venmo, no server needed. Venmo's own group split can only share one
    /// amount evenly (and counts you again), so each friend gets their own request; with one friend Venmo opens now.
    private func requestWithVenmo() {
        guard canSend else { return }
        let emojis = String((byItem ? items : allItems).map { emoji($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(4).joined())
        let split = service.recordVenmo(title: title, method: transaction.map(Self.method) ?? "Apple Pay", people: people,
                                        itemIDs: lines.map(\.id), emojis: emojis, totals: totals)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { sent = split }
        if split.shares.count == 1, let (id, share) = split.shares.first, let person = people.first(where: { $0.id == id }) {
            let recipient = service.friends.first { $0.id == id }?.venmo ?? person.venmo
            if let url = Venmo.requestURL(recipient: recipient, amount: share.total, note: Venmo.note(title: split.title, emojis: split.emojis)) {
                openURL(url)
                service.markRequested(split: split.id, person: id)
            }
        }
    }

    /// How the payment was made, as friends see it: "Apple Pay", the card's name, or where it came from.
    static func method(_ tx: Payment) -> String {
        tx.source == .tap ? "Apple Pay" : (tx.card.isEmpty ? tx.source.label : tx.card)
    }
}

// MARK: - Pieces

/// The purchase being split, drawn like a receipt with a torn edge.
private struct ReceiptHeader: View {
    let title: String
    let transaction: Payment?
    let total: Int
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CategoryIcon(category: (transaction?.category ?? .other), size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                HStack(spacing: 4) {
                    if let transaction {
                        if transaction.source == .tap {
                            Image(systemName: "apple.logo").font(.caption2)
                            Text("Pay").font(.caption.weight(.semibold))
                        } else {
                            Text(SplitSheet.method(transaction)).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                        }
                        Text("· \(transaction.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    }
                }
                .font(.caption).foregroundStyle(Theme.secondary)
                Text("\(count) \(count == 1 ? "item" : "items") to split").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(money(total)).font(.system(.title2, design: .rounded).weight(.heavy)).monospacedDigit()
                    .contentTransition(.numericText()).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.55)
                if let transaction, transaction.cents != total {
                    Text("of \(transaction.formattedAmount)").font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(16).padding(.bottom, 8)
        .background(Theme.card, in: TornEdge())
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .animation(.snappy, value: total)
    }
}

/// A rounded card whose bottom edge is torn like a till receipt.
struct TornEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 18, tooth: CGFloat = 7, depth: CGFloat = 6
        path.move(to: CGPoint(x: 0, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        var x = rect.maxX
        var down = true
        while x > 0 {
            x = max(0, x - tooth)
            path.addLine(to: CGPoint(x: x, y: down ? rect.maxY : rect.maxY - depth))
            down.toggle()
        }
        path.closeSubpath()
        return path
    }
}


private struct PersonBubble: View {
    let person: SplitPerson
    let selected: Bool
    let amount: Int?

    var body: some View {
        VStack(spacing: 6) {
            Text(person.initial)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .frame(width: 54, height: 54)
                .background(selected ? person.avatar : AnyShapeStyle(person.color.opacity(0.25)), in: Circle())
                .foregroundStyle(.white)
                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 3 : 0))
                .shadow(color: selected ? person.color.opacity(0.45) : .clear, radius: 8, y: 3)
                .overlay(alignment: .topTrailing) {
                    if person.venmo != nil {
                        Image(systemName: "v.circle.fill").font(.system(size: 16))
                            .foregroundStyle(.white, Color(red: 0, green: 0.55, blue: 1))
                            .background(Circle().fill(.white).padding(1))
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                            .foregroundStyle(.white, Theme.accent)
                            .background(Circle().fill(.white).padding(2))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(selected ? 1.06 : 0.94)
            Text(person.isMe ? "You" : person.name).font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Theme.ink : Theme.secondary).lineLimit(1)
            Text(selected && !person.isMe ? money(amount ?? 0) : " ")
                .font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(person.color)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: 76)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: selected)
        .animation(.snappy, value: amount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(person.isMe ? "You" : person.name)
        .accessibilityValue(selected ? "Sharing" : "Not sharing")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("split-person-\(person.name)")
    }
}

// MARK: - After sending

/// Each friend's link, with live status: Sent, Opened, Paid.
struct SentSplitView: View {
    let split: SentSplit
    var onNewSplit: (() -> Void)? = nil
    @ObservedObject private var service = SplitService.shared
    @Environment(\.openURL) private var openURL
    @State private var shown = false
    @State private var copied: String?
    @State private var composing: MessageDraft?

    private var current: SentSplit { service.splits.first { $0.id == split.id } ?? split }
    private var isVenmo: Bool { current.id.hasPrefix(SplitService.venmoPrefix) }
    /// The friend to ask next in Venmo: the first one not asked yet.
    private var nextUp: String? { friends.first { current.shares[$0.id]?.status == "sent" }?.id }
    private var friends: [SplitPerson] { current.people.filter { !$0.isMe && current.shares[$0.id] != nil } }
    private var paidCents: Int {
        current.shares.values.filter { $0.status == "paid" }.reduce(0) { $0 + Int(((Double($1.total) ?? 0) * 100).rounded()) }
    }
    private var owedCents: Int { current.shares.values.reduce(0) { $0 + Int(((Double($1.total) ?? 0) * 100).rounded()) } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                progress
                VStack(spacing: 12) {
                    ForEach(Array(friends.enumerated()), id: \.element.id) { index, person in
                        if let share = current.shares[person.id] {
                            card(person, share)
                                .offset(y: shown ? 0 : 40).opacity(shown ? 1 : 0)
                                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08 * Double(index) + 0.15), value: shown)
                        }
                    }
                }
                Text(isVenmo
                     ? "Venmo doesn't tell other apps when you're paid. When a friend's payment arrives in Venmo, tap ⋯ › Mark as paid."
                     : "Request in Messages and friends can pay with Apple Cash right in the chat. Their link also takes Venmo, PayPal or a card, and those show up here.")
                    .font(.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).padding(.horizontal, 12)
                if let onNewSplit {
                    Button("Split again", systemImage: "arrow.counterclockwise", action: onNewSplit)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(16)
        }
        .onAppear { withAnimation { shown = true } }
        .task(id: split.id) {
            // Follow payments while this screen is open.
            while !Task.isCancelled {
                await service.refresh(split.id)
                if current.isSettled { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sensoryFeedback(.success, trigger: current.paidCount)
        .sheet(item: $composing) { MessageComposer(draft: $0) }
    }

    /// Opens Messages to this friend with what they owe, the receipt picture and their link; they pay with Apple Cash there.
    private func requestInMessages(_ person: SplitPerson, _ share: SplitShare) {
        let saved = service.friends.first { $0.id == person.id } ?? person
        let me = current.people.first(where: \.isMe)?.name
        let card = SplitRequestCard(title: current.title, emojis: current.emojis, date: current.createdAt,
                                    amount: share.total, friend: person.name, from: me)
        composing = MessageDraft(recipients: AppleCashRequest.recipient(saved).map { [$0] } ?? [],
                                 body: AppleCashRequest.request(friend: person.name, from: me, title: current.title,
                                                                emojis: current.emojis, amount: share.total, link: share.link),
                                 image: card.png())
    }

    private var progress: some View {
        let fraction = owedCents == 0 ? 0 : Double(paidCents) / Double(owedCents)
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 8)
                Circle().trim(from: 0, to: shown ? fraction : 0)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.8, dampingFraction: 0.8), value: fraction)
                Image(systemName: current.isSettled ? "checkmark" : "arrow.down.left")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(current.isSettled ? "All settled up" : "\(money(paidCents)) of \(money(owedCents)) back")
                    .font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text("\(current.title) · \(current.paidCount) of \(current.shares.count) paid")
                    .font(.caption).foregroundStyle(Theme.secondary).contentTransition(.numericText())
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func card(_ person: SplitPerson, _ share: SplitShare) -> some View {
        let paid = share.status == "paid"
        let message = "Hi \(person.name)! \(current.emojis ?? "🛒") Your share of \(current.title) is $\(share.total). You can pay me back with Venmo or PayPal here: \(share.link)"
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(person.initial).font(.system(size: 18, weight: .heavy, design: .rounded))
                    .frame(width: 44, height: 44).background(person.avatar, in: Circle()).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.headline).foregroundStyle(Theme.ink)
                    StatusPill(status: share.status, via: share.paidVia, venmo: isVenmo)
                }
                Spacer()
                Text("$\(share.total)").font(.system(.title3, design: .rounded).weight(.heavy)).monospacedDigit()
                    .foregroundStyle(paid ? Theme.accent : Theme.ink)
                    .strikethrough(paid, color: Theme.accent.opacity(0.6))
            }
            if !paid && isVenmo {
                let next = nextUp == person.id
                HStack(spacing: 8) {
                    Button { requestInVenmo(person, share) } label: {
                        HStack(spacing: 6) {
                            Text("V").font(.system(size: 13, weight: .black, design: .rounded))
                                .frame(width: 18, height: 18).background(.white, in: Circle()).foregroundStyle(SplitSheet.venmoBlue)
                            Text(share.status == "requested" ? "Request again" : "Request $\(share.total) in Venmo")
                        }
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(share.status == "requested" ? SplitSheet.venmoBlue.opacity(0.5) : SplitSheet.venmoBlue, in: Capsule())
                        .foregroundStyle(.white)
                        .scaleEffect(next ? 1.02 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("venmo-request-\(person.name)")
                    Menu {
                        Button("Paid in Venmo", systemImage: "checkmark.circle") {
                            withAnimation(.spring) { service.markPaidByHand(split: current.id, person: person.id, via: "Venmo") }
                        }
                        Button("Paid with Apple Cash", systemImage: "apple.logo") {
                            withAnimation(.spring) { service.markPaidByHand(split: current.id, person: person.id, via: "Apple Cash") }
                        }
                        Button("Paid another way", systemImage: "checkmark.seal") {
                            withAnimation(.spring) { service.markPaidByHand(split: current.id, person: person.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 40, height: 40)
                            .background(Theme.background, in: Circle()).foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Mark \(person.name) paid")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if !paid {
                HStack(spacing: 8) {
                    Button { requestInMessages(person, share) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "message.fill")
                            Text("Request in Messages")
                        }
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Messages, where \(person.name) can pay you with Apple Cash")
                    .accessibilityIdentifier("split-send-\(person.name)")
                    Button {
                        UIPasteboard.general.string = share.link
                        withAnimation(.snappy) { copied = person.id }
                    } label: {
                        Image(systemName: copied == person.id ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 40, height: 40).background(Theme.softGreen, in: Circle()).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Copy \(person.name)'s link")
                    Menu {
                        if let url = URL(string: share.link) {
                            ShareLink(item: url, message: Text(message)) { Label("Share payment link", systemImage: "square.and.arrow.up") }
                        }
                        Button(venmo(person).map { "Request from \(Venmo.label($0)) in Venmo" } ?? "Request in Venmo (free)", systemImage: "v.circle") {
                            requestInVenmo(person, share)
                        }
                        Divider()
                        Button("Paid with Apple Cash", systemImage: "apple.logo") {
                            withAnimation(.spring) { service.markPaidByHand(split: current.id, person: person.id, via: "Apple Cash") }
                        }
                        Button("Mark as paid", systemImage: "checkmark.circle") {
                            withAnimation(.spring) { service.markPaidByHand(split: current.id, person: person.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 40, height: 40)
                            .background(Theme.background, in: Circle()).foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("More for \(person.name)")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .padding(14)
        .background(paid ? Theme.softGreen : Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(
            paid ? Theme.accent.opacity(0.35) : (isVenmo && nextUp == person.id ? SplitSheet.venmoBlue.opacity(0.6) : .clear),
            lineWidth: isVenmo && nextUp == person.id && !paid ? 2 : 1))
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: paid)
        .accessibilityIdentifier("split-share-\(person.name)")
    }

    /// Their Venmo, as saved now (it may have been added after the split was sent).
    private func venmo(_ person: SplitPerson) -> String? { service.friends.first { $0.id == person.id }?.venmo ?? person.venmo }

    /// Opens Venmo with the friend, amount and an emoji note filled in. Free, but the app can't see it, so you mark it paid.
    private func requestInVenmo(_ person: SplitPerson, _ share: SplitShare) {
        let note = Venmo.note(title: current.title, emojis: current.emojis)
        guard let app = Venmo.requestURL(recipient: venmo(person), amount: share.total, note: note) else { return }
        openURL(app) { accepted in
            if !accepted, let web = URL(string: "https://venmo.com/") { openURL(web) }
        }
        service.markRequested(split: current.id, person: person.id)
    }
}

private struct StatusPill: View {
    let status: String
    let via: String?
    var venmo = false

    var body: some View {
        let (label, icon, color): (String, String, Color) = switch status {
        case "paid": ("Paid\(via.map { " · \($0)" } ?? "")", "checkmark.circle.fill", Theme.accent)
        case "opened": ("Opened", "eye.fill", Color(red: 0.82, green: 0.55, blue: 0.2))
        case "requested": ("Requested in Venmo", "paperplane.fill", SplitSheet.venmoBlue)
        default: venmo ? ("Not asked yet", "clock", Theme.secondary) : ("Link ready", "link", Theme.secondary)
        }
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: status)
    }
}

/// Two ways to split: the whole bill in equal parts, or each item to whoever had it.
enum SplitMode: String, CaseIterable {
    case evenly, byItem

    var title: String { self == .evenly ? "Evenly" : "By item" }
    var detail: String { self == .evenly ? "Everyone pays the same" : "Pay for what you had" }
    var icon: String { self == .evenly ? "equal.square.fill" : "checklist" }
}

/// The receipt torn into one piece per person, each as wide as their share: a cut runs down between them, then
/// the pieces spring apart.
struct TearingReceipt: View {
    struct Piece: Identifiable, Equatable {
        var id: String
        var name: String
        var initial: String
        var color: Color
        var colors: [Color]
        var cents: Int
        var emojis: [String]
    }

    let pieces: [Piece]
    let total: Int
    /// Changes when the receipt should tear again: a new way of splitting.
    let tears: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var apart = false
    @State private var cut: CGFloat = 0
    @State private var snips = 0

    var body: some View {
        GeometryReader { geo in
            let n = CGFloat(max(1, pieces.count))
            let gap: CGFloat = apart ? 10 : 0
            let room = geo.size.width - gap * (n - 1)
            let sum = CGFloat(max(1, pieces.reduce(0) { $0 + max(0, $1.cents) }))
            // Part equal, part by share, so a small share still has room for its name.
            let widths = pieces.map { room * (0.4 / n + 0.6 * CGFloat(max(0, $0.cents)) / sum) }
            ZStack(alignment: .topLeading) {
                HStack(spacing: gap) {
                    ForEach(Array(pieces.enumerated()), id: \.element.id) { index, piece in
                        pieceView(piece, first: index == 0, last: index == pieces.count - 1)
                            .frame(width: max(0, widths[index]))
                            .rotationEffect(.degrees(apart ? (index.isMultiple(of: 2) ? -2.2 : 1.8) : 0), anchor: .top)
                            .offset(y: apart ? (index.isMultiple(of: 2) ? 5 : -1) : 0)
                    }
                }
                // Where the scissors go: dashed lines drawn down each seam before the pieces part.
                ForEach(1..<max(1, pieces.count), id: \.self) { index in
                    let x = widths.prefix(index).reduce(0, +)
                    Path { $0.move(to: CGPoint(x: x, y: 4)); $0.addLine(to: CGPoint(x: x, y: geo.size.height - 4)) }
                        .trim(from: 0, to: cut)
                        .stroke(Theme.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .opacity(apart ? 0 : 1)
                    Image(systemName: "scissors").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                        .rotationEffect(.degrees(90))
                        .position(x: x, y: 4 + (geo.size.height - 8) * cut)
                        .opacity(apart || cut == 0 ? 0 : 1)
                }
            }
        }
        .frame(height: 138)
        .padding(.vertical, 4)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: pieces)
        .sensoryFeedback(.impact(weight: .medium), trigger: snips)
        .onAppear { tear(delay: 0.35) }
        .onChange(of: tears) { _, _ in tear() }
        .onChange(of: pieces.count) { _, _ in tear() }
        .accessibilityElement(children: .combine)
    }

    private func pieceView(_ piece: Piece, first: Bool, last: Bool) -> some View {
        VStack(spacing: 5) {
            Text(piece.initial).font(.system(size: 13, weight: .heavy))
                .frame(width: 28, height: 28).background(SplitPerson.fill(piece.colors), in: Circle()).foregroundStyle(.white)
            Text(piece.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
            Text(money(piece.cents)).font(.system(.headline, design: .rounded).weight(.heavy)).monospacedDigit()
                .foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(piece.emojis.prefix(4).joined()).font(.caption).lineLimit(1).frame(height: 16)
        }
        .padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                RippedPiece(leftTorn: !first, rightTorn: !last).fill(Color.white)
                piece.color.frame(height: 5).clipShape(RippedPiece(leftTorn: !first, rightTorn: !last))
            }
            .shadow(color: .black.opacity(apart ? 0.12 : 0.05), radius: apart ? 8 : 3, y: apart ? 4 : 1)
        }
    }

    private func tear(delay: Double = 0) {
        guard pieces.count > 1, !reduceMotion else { apart = pieces.count > 1; cut = 0; return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { apart = false; cut = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeInOut(duration: 0.32)) { cut = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.5)) { apart = true }
                snips += 1
            }
        }
    }
}

/// A piece of receipt: straight top and bottom, zigzag where it was torn from its neighbours.
private struct RippedPiece: Shape {
    var leftTorn: Bool
    var rightTorn: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 12, tooth: CGFloat = 6, depth: CGFloat = 3.5
        let tl = leftTorn ? 0 : r, tr = rightTorn ? 0 : r
        path.move(to: CGPoint(x: tl, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: 0))
        if rightTorn {
            var y: CGFloat = 0, out = false
            while y < rect.maxY {
                y = min(rect.maxY, y + tooth)
                path.addLine(to: CGPoint(x: rect.maxX - (out ? 0 : depth), y: y))
                out.toggle()
            }
        } else {
            path.addArc(center: CGPoint(x: rect.maxX - r, y: r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: leftTorn ? 0 : r, y: rect.maxY))
        if leftTorn {
            var y = rect.maxY, out = false
            while y > 0 {
                y = max(0, y - tooth)
                path.addLine(to: CGPoint(x: out ? 0 : depth, y: y))
                out.toggle()
            }
        } else {
            path.addArc(center: CGPoint(x: r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: 0, y: r))
            path.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}
