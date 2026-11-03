import SwiftUI

extension SplitShare {
    var cents: Int { Int(((Double(total) ?? 0) * 100).rounded()) }
    var isPaid: Bool { status == "paid" }
}

extension SentSplit {
    var totalCents: Int { Int(((Double(total) ?? 0) * 100).rounded()) }
    /// What the person who paid keeps for their own share.
    var myCents: Int { max(0, totalCents - shares.values.reduce(0) { $0 + $1.cents }) }
}

/// One friend's running balance across every split.
struct SettleBalance: Identifiable, Equatable {
    let person: SplitPerson
    var owed = 0
    var paid = 0
    var splits = 0
    var id: String { person.id }

    /// Friends who still owe come first, biggest first; settled friends follow by name.
    static func from(_ splits: [SentSplit]) -> [SettleBalance] {
        var byID: [String: SettleBalance] = [:]
        for split in splits.sorted(by: { $0.createdAt < $1.createdAt }) {
            for person in split.people where !person.isMe {
                guard let share = split.shares[person.id] else { continue }
                var balance = byID[person.id] ?? SettleBalance(person: person)
                if share.isPaid { balance.paid += share.cents } else { balance.owed += share.cents }
                balance.splits += 1
                byID[person.id] = balance
            }
        }
        return byID.values.sorted { a, b in
            a.owed != b.owed ? a.owed > b.owed : a.person.name.localizedCompare(b.person.name) == .orderedAscending
        }
    }
}

/// Bills you split with friends: who owes you, and who has paid.
struct SettleUpPane: View {
    var sideBySide = false
    var flipNext: () -> Void
    @ObservedObject private var service = SplitService.shared
    @State private var opened: SentSplit?
    @State private var composing: MessageDraft?
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var splits: [SentSplit] { service.splits.sorted { $0.createdAt > $1.createdAt } }
    private var balances: [SettleBalance] { SettleBalance.from(service.splits) }
    private var owed: Int { balances.reduce(0) { $0 + $1.owed } }
    private var paid: Int { balances.reduce(0) { $0 + $1.paid } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if splits.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary
                        peopleSection
                        splitsSection
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, 14)
        .background(Theme.background.ignoresSafeArea())
        .clipped()
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.8).delay(0.15)) { grown = true }
        }
        .task {
            // Catch up on anyone who paid while the app was closed.
            for split in splits where !split.isSettled { await service.refresh(split.id) }
        }
        .sheet(item: $opened) { split in
            NavigationStack {
                SentSplitView(split: split)
                    .background(Theme.background.ignoresSafeArea())
                    .navigationTitle(split.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { opened = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $composing) { MessageComposer(draft: $0) }
    }

    /// Unpaid shares for one friend, newest first.
    private func unpaid(_ person: SplitPerson) -> [(split: SentSplit, share: SplitShare)] {
        splits.compactMap { split in split.shares[person.id].flatMap { $0.isPaid ? nil : (split, $0) } }
    }

    private func remind(_ balance: SettleBalance) {
        let open = unpaid(balance.person)
        let saved = service.friends.first { $0.id == balance.person.id } ?? balance.person
        let card = SplitRequestCard(title: open.count == 1 ? open[0].split.title : "\(open.count) grocery splits",
                                    emojis: open.first?.split.emojis, date: open.first?.split.createdAt ?? .now,
                                    amount: String(format: "%.2f", Double(balance.owed) / 100), friend: balance.person.name,
                                    from: open.first?.split.people.first(where: \.isMe)?.name, reminder: true)
        composing = MessageDraft(recipients: AppleCashRequest.recipient(saved).map { [$0] } ?? [],
                                 body: AppleCashRequest.reminder(friend: balance.person.name, owed: balance.owed,
                                                                 splits: open.map { ($0.split.title, $0.split.createdAt) },
                                                                 link: open.first?.share.link),
                                 image: card.png())
    }

    private func markAllPaid(_ person: SplitPerson, via: String) {
        withAnimation(.spring) {
            for item in unpaid(person) { service.markPaidByHand(split: item.split.id, person: person.id, via: via) }
        }
    }

    // MARK: - Header

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: flipNext) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Settle up").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Color(red: 0.31, green: 0.5, blue: 0.72)).frame(width: 6, height: 6)
                        Text("Bills split with friends & family").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Settle up. Show your fridge")
            .accessibilityIdentifier("settle-title")
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.2.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                .frame(width: 76, height: 76).background(Theme.softGreen, in: Circle())
            Text("No splits yet").font(.headline).foregroundStyle(Theme.ink)
            Text("Open food you bought with Apple Pay and tap Split bill. Who owes what shows up here.")
                .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Summary

    private var summary: some View {
        let total = owed + paid
        let fraction = total == 0 ? 0 : Double(paid) / Double(total)
        return VStack(alignment: .leading, spacing: 10) {
            Text(owed > 0 ? "Owed to you" : "All settled").font(.subheadline).foregroundStyle(Theme.secondary)
            Text(money(owed))
                .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(owed > 0 ? Theme.ink : Theme.accent)
                .contentTransition(.numericText())
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Theme.accent.gradient).frame(width: max(8, g.size.width * (grown ? fraction : 0)))
                }
            }
            .frame(height: 8)
            HStack {
                Label("\(money(paid)) paid back", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text("\(splits.count) \(splits.count == 1 ? "split" : "splits") · \(balances.count) \(balances.count == 1 ? "person" : "people")")
                    .foregroundStyle(Theme.secondary)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.line.opacity(0.7), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settle-summary")
    }

    // MARK: - People

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("People")
            VStack(spacing: 0) {
                ForEach(Array(balances.enumerated()), id: \.element.id) { index, balance in
                    if index > 0 { Divider().padding(.leading, 58) }
                    personRow(balance)
                }
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func personRow(_ balance: SettleBalance) -> some View {
        HStack(spacing: 12) {
            Avatar(person: balance.person, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(balance.person.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("\(balance.splits) \(balance.splits == 1 ? "split" : "splits")\(balance.paid > 0 ? " · \(money(balance.paid)) paid" : "")")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if balance.owed > 0 {
                Button { remind(balance) } label: {
                    Image(systemName: "bell.badge.fill").font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 32, height: 32).background(Theme.background, in: Circle())
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remind \(balance.person.name) in Messages")
                .accessibilityIdentifier("settle-remind-\(balance.person.name)")
                VStack(alignment: .trailing, spacing: 1) {
                    Text("owes you").font(.caption2).foregroundStyle(Theme.secondary)
                    Text(money(balance.owed)).font(.subheadline.weight(.bold)).monospacedDigit()
                        .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.2))
                }
            } else {
                Label("Settled", systemImage: "checkmark.circle.fill").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            if balance.owed > 0 {
                Button("Remind in Messages", systemImage: "bell") { remind(balance) }
                Button("Paid me with Apple Cash", systemImage: "apple.logo") { markAllPaid(balance.person, via: "Apple Cash") }
                Button("Mark all paid", systemImage: "checkmark.circle") { markAllPaid(balance.person, via: "marked by you") }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settle-person-\(balance.person.name)")
    }

    // MARK: - Splits

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Splits")
            ForEach(Array(splits.enumerated()), id: \.element.id) { index, split in
                Button { opened = split } label: { splitCard(split) }
                    .buttonStyle(.plain)
                    .offset(y: grown ? 0 : 24).opacity(grown ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05 * Double(min(index, 6))), value: grown)
                    .accessibilityIdentifier("settle-split-\(index)")
            }
        }
    }

    private func splitCard(_ split: SentSplit) -> some View {
        let me = split.people.first(where: \.isMe)
        let friends = split.people.filter { !$0.isMe && split.shares[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(split.emojis.flatMap { $0.isEmpty ? nil : $0 } ?? "🛒").font(.system(size: 20)).lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: 40, height: 40).background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(split.title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(split.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(split.method)")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(money(split.totalCents)).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(split.isSettled ? "Settled" : "\(split.paidCount) of \(split.shares.count) paid")
                        .font(.caption2.weight(.semibold)).foregroundStyle(split.isSettled ? Theme.accent : Theme.secondary)
                }
            }
            VStack(spacing: 6) {
                shareRow(person: me ?? SplitPerson(id: "me", name: "You", colorIndex: 0, isMe: true),
                         amount: split.myCents, status: nil)
                ForEach(friends) { person in
                    if let share = split.shares[person.id] { shareRow(person: person, amount: share.cents, status: share) }
                }
            }
            .padding(10)
            .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private func shareRow(person: SplitPerson, amount: Int, status: SplitShare?) -> some View {
        HStack(spacing: 8) {
            Avatar(person: person, size: 24)
            Text(person.isMe ? "You · your share" : person.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 6)
            if let status { StatusChip(share: status) }
            Text(money(amount)).font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(person.isMe ? Theme.secondary : Theme.ink)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink).padding(.leading, 2)
    }
}

private struct Avatar: View {
    let person: SplitPerson
    let size: CGFloat

    var body: some View {
        Text(person.initial)
            .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
            .frame(width: size, height: size)
            .background(person.avatar, in: Circle())
            .foregroundStyle(.white)
            .overlay(alignment: .bottomTrailing) {
                if person.venmo != nil && size > 30 {
                    Image(systemName: "v.circle.fill").font(.system(size: size * 0.38))
                        .foregroundStyle(.white, Color(red: 0, green: 0.55, blue: 1))
                        .background(Circle().fill(.white).padding(1))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct StatusChip: View {
    let share: SplitShare

    var body: some View {
        let (label, icon, color): (String, String, Color) = switch share.status {
        case "paid": (share.paidVia.flatMap { $0 == "marked by you" ? nil : "Paid · \($0 == "Apple Cash" ? $0 : $0.capitalized)" } ?? "Paid", "checkmark", Theme.accent)
        case "opened": ("Opened", "eye", Color(red: 0.31, green: 0.5, blue: 0.72))
        default: ("Requested", "paperplane", Theme.secondary)
        }
        return Label(label, systemImage: icon)
            .font(.system(size: 10, weight: .bold)).lineLimit(1)
            .padding(.horizontal, 7).frame(height: 20)
            .background(color.opacity(0.13), in: Capsule())
            .foregroundStyle(color)
    }
}
