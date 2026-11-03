import SwiftUI
import UserNotifications
import OSLog

/// Keeps a line open to the split server while Little Wallet is open, so a friend's payment shows up the moment
/// PayPal tells the server: their share turns paid, the phone buzzes, and a banner says who paid.
@MainActor
final class LiveUpdates: ObservableObject {
    static let shared = LiveUpdates()

    @Published private(set) var connected = false
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "com.jiawenzhu.littlewallet", category: "live")

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        connected = false
    }

    /// When the server last said anything, heartbeats included.
    private var lastHeard = Date.now

    /// Reconnects with growing pauses when the server can't be reached, never more than 30 seconds apart.
    private func run() async {
        var pause = 1.0
        while !Task.isCancelled {
            lastHeard = .now
            // A dropped connection doesn't always end the stream, so a watchdog gives up when the
            // 25-second heartbeat stops arriving.
            let heard = await withTaskGroup(of: Bool.self) { group in
                group.addTask { @MainActor in
                    do { try await self.listen(); self.log.notice("Live line closed by the server") }
                    catch { self.log.notice("Live line dropped: \(error.localizedDescription, privacy: .public)") }
                    return self.connected
                }
                group.addTask { @MainActor in
                    while !Task.isCancelled, Date.now.timeIntervalSince(self.lastHeard) < 40 {
                        try? await Task.sleep(for: .seconds(5))
                    }
                    self.log.notice("Live line went quiet; reconnecting")
                    return self.connected
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            connected = false
            if heard { pause = 1 }
            try? await Task.sleep(for: .seconds(pause))
            pause = heard ? 1 : min(pause * 2, 30)
        }
    }

    private func listen() async throws {
        var request = URLRequest(url: SplitService.shared.serverURL.appending(path: "/api/events"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        SplitService.authorize(&request)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        connected = true
        lastHeard = .now
        log.notice("Live line open")
        var event = ""
        for try await line in bytes.lines {
            lastHeard = .now
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                handle(event, Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))
                event = ""
            }
        }
    }

    struct Paid: Decodable {
        var split: String
        var person: String
        var name: String?
        var title: String?
        var amount: String?
        var via: String?
    }

    func handle(_ event: String, _ data: Data) {
        switch event {
        case "share.paid":
            guard let paid = try? JSONDecoder().decode(Paid.self, from: data) else { return }
            Self.settle(paid, splits: .shared)
        case "activity":
            Task { await PayPalLink.shared.sync(store: WalletStore.shared) }
        default:
            break
        }
    }

    /// Marks the share paid on this phone and says so. Returns false when it was already paid or isn't here.
    @discardableResult
    static func settle(_ paid: Paid, splits: SplitService, notify: Bool = true) -> Bool {
        guard let split = splits.splits.first(where: { $0.id == paid.split }),
              let share = split.shares[paid.person], share.status != "paid" else { return false }
        splits.markPaidByHand(split: paid.split, person: paid.person, via: paid.via ?? "PayPal")
        if notify { Task { await announce(name: share.name, amount: paid.amount ?? share.total, title: split.title, via: paid.via) } }
        return true
    }

    /// A banner — shown even while the app is open — and a buzz.
    private static func announce(name: String, amount: String, title: String, via: String?) async {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        let first = name.split(separator: " ").first.map(String.init) ?? name
        content.title = "\(first) paid you $\(amount) 🎉"
        content.body = "Their share of \(title) is settled\(via.map { " · \($0)" } ?? "")."
        content.sound = .default
        content.threadIdentifier = "paid"
        try? await center.add(UNNotificationRequest(identifier: "paid-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
