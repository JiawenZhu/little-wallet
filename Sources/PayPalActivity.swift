import SwiftUI

/// One line of PayPal account activity, as the Little Fridge Split server reads it with Transaction Search.
struct PayPalActivity: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case received, sent, refund, transfer }

    struct Item: Codable, Equatable {
        var name: String
        var quantity: Int?
        var amount: String?
    }

    struct SplitRef: Codable, Equatable {
        var id: String
        var person: String
    }

    var id: String
    var date: String
    var kind: Kind
    var amount: String
    var fee: String?
    var currency: String?
    /// "Venmo", "PayPal" or "Card".
    var via: String
    var name: String?
    var note: String?
    var items: [Item]
    var split: SplitRef?
    var pending: Bool?

    var when: Date { (try? Date(date, strategy: .iso8601)) ?? .now }
    var cents: Int { Int(((Double(amount) ?? 0) * 100).rounded()) }
    var feeCents: Int { Int(((Double(fee ?? "0") ?? 0) * 100).rounded()) }
    var isIn: Bool { kind == .received || kind == .refund && cents > 0 }

    var title: String {
        switch kind {
        case .transfer: return "To your bank"
        case .refund: return "Refund\(name.map { " · \($0)" } ?? "")"
        default: return name ?? note ?? "PayPal payment"
        }
    }

    /// Money out, as a payment in the wallet.
    var payment: Payment {
        let merchant = name ?? note ?? "PayPal"
        let lines = items.map { LineItem(name: $0.name, quantity: max(1, $0.quantity ?? 1), price: $0.amount.flatMap(Double.init)) }
        return Payment(date: when, merchant: merchant, amount: Double(cents) / 100, card: via, category: .guess(merchant: merchant, items: lines.map(\.name)),
                       source: .paypal, items: lines, note: note == merchant ? nil : note, externalID: "paypal:\(id)")
    }
}

/// The PayPal account linked through the split server: what came in from friends, what went out, and the balance.
/// Money friends sent for a split marks their share paid; PayPal spending lands in the wallet like any payment.
@MainActor
final class PayPalLink: ObservableObject {
    static let shared = PayPalLink()

    @Published private(set) var activity: [PayPalActivity] = []
    @Published private(set) var balance: String?
    @Published private(set) var sandbox = true
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    @Published private(set) var problem: String?
    @Published private(set) var connected: Bool

    private let defaults: UserDefaults
    private let key = "little-wallet-paypal-v1"

    private struct Saved: Codable {
        var activity: [PayPalActivity]
        var balance: String?
        var sandbox: Bool
        var lastSync: Date?
    }

    private struct Response: Decodable {
        var activity: [PayPalActivity]
        var balance: String?
        var env: String?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        connected = defaults.bool(forKey: key + "-on")
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            activity = saved.activity
            balance = saved.balance
            sandbox = saved.sandbox
            lastSync = saved.lastSync
        }
    }

    /// What friends sent in the last `days` days.
    func cameIn(days: Int = 30) -> Int {
        let since = Date.now.addingTimeInterval(-Double(days) * 86_400)
        return activity.filter { $0.kind == .received && $0.when >= since }.reduce(0) { $0 + $1.cents }
    }

    func connect() {
        connected = true
        defaults.set(true, forKey: key + "-on")
    }

    func disconnect() {
        connected = false
        activity = []
        balance = nil
        lastSync = nil
        problem = nil
        defaults.set(false, forKey: key + "-on")
        defaults.removeObject(forKey: key)
    }

    /// Reads the last 90 days. Returns how many PayPal payments were added to the wallet and how many shares it marked paid.
    @discardableResult
    func sync(store: WalletStore, splits: SplitService = .shared) async -> (added: Int, settled: Int) {
        guard connected, !syncing else { return (0, 0) }
        syncing = true
        defer { syncing = false }
        do {
            var request = URLRequest(url: splits.serverURL.appending(path: "/api/paypal/activity").appending(queryItems: [.init(name: "days", value: "90")]))
            request.timeoutInterval = 30
            SplitService.authorize(&request)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                struct Failure: Decodable { let error: String }
                problem = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "PayPal didn't answer (\(status))."
                return (0, 0)
            }
            let result = try JSONDecoder().decode(Response.self, from: data)
            activity = result.activity
            balance = result.balance
            sandbox = result.env != "live"
            lastSync = .now
            problem = nil
            save()
            return apply(to: store, splits: splits)
        } catch {
            problem = "Couldn't reach PayPal. Check your connection and try again."
            return (0, 0)
        }
    }

    /// Spending becomes payments; a friend's payment for a split marks their share paid.
    @discardableResult
    func apply(to store: WalletStore, splits: SplitService) -> (added: Int, settled: Int) {
        let added = store.importPayments(activity.filter { $0.kind == .sent && $0.pending != true }.map(\.payment))
        var settled = 0
        for item in activity where item.kind == .received {
            guard let ref = item.split, let split = splits.splits.first(where: { $0.id == ref.id }),
                  let share = split.shares[ref.person], share.status != "paid" else { continue }
            splits.markPaidByHand(split: ref.id, person: ref.person, via: item.via)
            settled += 1
        }
        return (added, settled)
    }

    /// The split a friend's payment was for, when it's on this phone.
    func split(for item: PayPalActivity, in splits: SplitService) -> SentSplit? {
        item.split.flatMap { ref in splits.splits.first { $0.id == ref.id } }
    }

    private func save() {
        let saved = Saved(activity: activity, balance: balance, sandbox: sandbox, lastSync: lastSync)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }

    #if DEBUG
    /// Screenshots without a server.
    func preview(_ items: [PayPalActivity], balance: String) {
        connected = true
        activity = items
        self.balance = balance
        lastSync = .now
    }
    #endif
}

// MARK: - Screens

/// PayPal and Venmo at a glance on the home screen.
struct PayPalCard: View {
    @ObservedObject var link: PayPalLink
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                MoneyAppBadges(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.connected ? "PayPal & Venmo" : "Connect PayPal").font(.headline).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                if link.syncing { ProgressView() } else {
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paypal-card")
    }

    private var subtitle: String {
        guard link.connected else { return "See what friends send you, and PayPal spending" }
        let came = link.cameIn()
        if came > 0 { return "\(money(came)) came in this month" }
        if let sync = link.lastSync { return "Up to date · \(sync.formatted(.relative(presentation: .named)))" }
        return "Tap to sync"
    }
}

/// A PayPal "P" and a Venmo "V", overlapping, in the app's own style.
struct MoneyAppBadges: View {
    var size: CGFloat = 46

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text("P").font(.system(size: size * 0.46, weight: .heavy, design: .rounded)).italic()
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [Color(hex: "#2C6FD6"), Color(hex: "#173F8C")], startPoint: .top, endPoint: .bottom), in: Circle())
            ViaBadge(via: "Venmo", size: size * 0.48).offset(x: size * 0.1, y: size * 0.06)
        }
        .accessibilityHidden(true)
    }
}

/// A small round mark for how money moved.
struct ViaBadge: View {
    let via: String
    var size: CGFloat = 18

    var body: some View {
        Text(via == "Venmo" ? "V" : via == "Card" ? "" : "P")
            .font(.system(size: size * 0.56, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(via == "Venmo" ? Color(hex: "#3D95CE") : Color(hex: "#2C6FD6"), in: Circle())
            .overlay {
                if via == "Card" { Image(systemName: "creditcard.fill").font(.system(size: size * 0.45)).foregroundStyle(.white) }
            }
            .overlay(Circle().strokeBorder(.white, lineWidth: max(1.5, size * 0.09)))
    }
}

struct PayPalSheet: View {
    @ObservedObject var store: WalletStore
    @ObservedObject private var link = PayPalLink.shared
    @ObservedObject private var splits = SplitService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", came = "Came in", went = "Went out"
        var id: Self { self }
    }

    @State private var filter: Filter = .all
    @State private var news: String?
    @State private var landed = 0
    @State private var confirmingDisconnect = false

    private var shown: [PayPalActivity] {
        link.activity.filter { item in
            switch filter {
            case .all: return true
            case .came: return item.isIn
            case .went: return !item.isIn
            }
        }
    }

    private var days: [(day: Date, items: [PayPalActivity])] {
        Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.when) }
            .map { ($0.key, $0.value.sorted { $0.when > $1.when }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if link.connected { connected } else { intro }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("PayPal & Venmo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if link.connected {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Sync now", systemImage: "arrow.clockwise") { sync() }
                            Button("Disconnect", systemImage: "link.badge.plus", role: .destructive) { confirmingDisconnect = true }
                        } label: {
                            if link.syncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .accessibilityLabel("Sync")
                    }
                }
            }
            .confirmationDialog("Disconnect PayPal?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { link.disconnect() }
            } message: {
                Text("Payments already added to your wallet stay.")
            }
        }
        .tint(Theme.accent)
        .sensoryFeedback(.success, trigger: landed)
        .task { if link.connected && (link.lastSync.map { Date.now.timeIntervalSince($0) > 60 } ?? true) { sync() } }
    }

    // MARK: - Not connected

    private var intro: some View {
        ScrollView {
            VStack(spacing: 22) {
                MoneyAppBadges(size: 92).padding(.top, 24)
                VStack(spacing: 8) {
                    Text("Your PayPal, in your wallet").font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                    Text("Little Wallet reads your PayPal activity, including Venmo payments that come through PayPal.")
                        .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 14) {
                    benefit("checkmark.seal.fill", "Splits settle themselves", "When a friend pays their share by Venmo or PayPal, it's marked paid.")
                    benefit("bag.fill", "PayPal spending, counted", "Money you send or spend with PayPal joins this month's total.")
                    benefit("lock.fill", "Read only", "Little Wallet only reads. Your PayPal keys stay on your Little Fridge Split server.")
                }
                .padding(18)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button {
                    link.connect()
                    sync()
                } label: {
                    Text("Connect PayPal").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(Color(hex: "#1F5BC4"), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paypal-connect")
            }
            .padding(20)
        }
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: - Connected

    private var connected: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let news {
                    Label(news, systemImage: "sparkles").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.softGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let problem = link.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Color(hex: "#9A5B12"))
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "#FBEBD3"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Picker("Show", selection: $filter.animation(.snappy)) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if shown.isEmpty { empty } else { list }
                Text("Read with PayPal Transaction Search. New payments can take a few hours to show up.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(18)
        }
        .refreshable { await syncNow() }
    }

    private var header: some View {
        let since = Date.now.addingTimeInterval(-30 * 86_400)
        let recent = link.activity.filter { $0.when >= since }
        let came = recent.filter { $0.kind == .received }.reduce(0) { $0 + $1.cents }
        let went = recent.filter { $0.kind == .sent }.reduce(0) { $0 + $1.cents }
        let fees = recent.reduce(0) { $0 + $1.feeCents }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PayPal balance").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    Text(link.balance.flatMap(Double.init).map(dollars) ?? "—")
                        .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                Spacer()
                if link.sandbox {
                    Text("Sandbox").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                stat("Came in", came, icon: "arrow.down.left")
                stat("Went out", went, icon: "arrow.up.right")
                stat("Fees", fees, icon: "percent")
            }
            Text(link.lastSync.map { "Last 30 days · synced \($0.formatted(.relative(presentation: .named)))" } ?? "Last 30 days")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Color(hex: "#1F5BC4"), Color(hex: "#173F8C"), Color(hex: "#2E7FBF")], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Circle().fill(.white.opacity(0.07)).frame(width: 160, height: 160).offset(x: 50, y: -60).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color(hex: "#173F8C").opacity(0.25), radius: 14, y: 6)
        .animation(.snappy, value: link.balance)
    }

    private func stat(_ label: String, _ cents: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: icon).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.8))
            Text(money(cents)).font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: link.syncing ? "hourglass" : "tray").font(.title).foregroundStyle(Theme.secondary)
            Text(link.syncing ? "Reading your PayPal…" : "Nothing here in the last 90 days").font(.subheadline).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity).padding(30)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(days, id: \.day) { group in
                Text(dayTitle(group.day)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
                    .padding(.top, 14).padding(.bottom, 4)
                ForEach(group.items) { item in
                    row(item)
                    if item.id != group.items.last?.id { Divider().padding(.leading, 58) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(reduceMotion ? nil : .snappy, value: filter)
    }

    private func row(_ item: PayPalActivity) -> some View {
        let split = link.split(for: item, in: splits)
        return HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if item.kind == .transfer {
                        Image(systemName: "building.columns.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .frame(width: 44, height: 44).background(Theme.background, in: Circle())
                    } else {
                        Text(String((item.name ?? "?").trimmingCharacters(in: .punctuationCharacters).prefix(1)).uppercased())
                            .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(SplitPerson.palette[(item.name ?? "").unicodeScalars.reduce(0) { $0 + Int($1.value) } % SplitPerson.palette.count].gradient, in: Circle())
                    }
                }
                if item.kind != .transfer { ViaBadge(via: item.via, size: 18).offset(x: 3, y: 3) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if let note = item.note {
                    Text(note).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(2)
                } else if item.kind == .transfer {
                    Text("Moved out of PayPal").font(.subheadline).foregroundStyle(Theme.secondary)
                }
                if let split {
                    let paid = split.shares[item.split!.person]?.status == "paid"
                    Label(paid ? "\(split.title) · share paid" : split.title, systemImage: paid ? "checkmark.circle.fill" : "person.2.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.softGreen, in: Capsule())
                } else if item.split != nil {
                    Label("Paid a split share", systemImage: "person.2.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text((item.isIn ? "+" : "−") + money(item.cents))
                    .font(.body.weight(.bold)).monospacedDigit()
                    .foregroundStyle(item.isIn ? Theme.accent : Theme.ink)
                if item.feeCents > 0 {
                    Text("fee \(money(item.feeCents))").font(.caption2).foregroundStyle(Theme.secondary)
                }
                if item.pending == true {
                    Text("Pending").font(.caption2.weight(.bold)).foregroundStyle(Color(hex: "#9A5B12"))
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func sync() { Task { await syncNow() } }

    private func syncNow() async {
        let (added, settled) = await link.sync(store: store)
        var parts: [String] = []
        if added > 0 { parts.append("\(added) PayPal \(added == 1 ? "payment" : "payments") added to your wallet") }
        if settled > 0 { parts.append("\(settled) split \(settled == 1 ? "share" : "shares") marked paid") }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { news = parts.isEmpty ? nil : parts.joined(separator: " · ") }
        if !parts.isEmpty { landed += 1 }
    }
}
