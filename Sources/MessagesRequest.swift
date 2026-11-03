import SwiftUI
import MessageUI

/// Asking for money in Messages, where friends can pay with Apple Cash. Apple doesn't let apps fill in an
/// Apple Cash amount, so the message says what to send and the friend taps Apple Cash in the chat; their
/// Venmo / PayPal link rides along as a backup.
enum AppleCashRequest {
    /// Who to text: a saved phone number or email (iMessage takes both); nil lets the person pick in Messages.
    static func recipient(_ person: SplitPerson) -> String? {
        guard let value = person.venmo else { return nil }
        if value.count == 10, value.allSatisfy(\.isNumber) { return value }
        if value.contains("@") { return value }
        return nil
    }

    static func request(friend: String, from me: String?, title: String, emojis: String?, amount: String, link: String) -> String {
        var text = "Hi \(firstName(friend))! 🧊 Your share of \(emojis.map { $0 + " " } ?? "")\(title) is $\(amount)."
        text += " Easiest: tap + → Apple Cash right here in Messages and send $\(amount)."
        if !link.isEmpty { text += " Or pay with Venmo or PayPal: \(link)" }
        if let me, !me.isEmpty { text += " Thanks! – \(me)" }
        return text
    }

    static func firstName(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }

    /// A friendly nudge covering everything a friend still owes.
    static func reminder(friend: String, owed: Int, splits: [(title: String, date: Date)], link: String?) -> String {
        // Several splits from one shop on one day read as one ("Trader Joe's (Oct 27, 3 splits)"), not a repeated list.
        var groups: [(title: String, day: String, count: Int)] = []
        for split in splits {
            let day = split.date.formatted(.dateTime.month(.abbreviated).day())
            if let i = groups.firstIndex(where: { $0.title == split.title && $0.day == day }) { groups[i].count += 1 }
            else { groups.append((split.title, day, 1)) }
        }
        var what = groups.prefix(3).map { "\($0.title) (\($0.day)\($0.count > 1 ? ", \($0.count) splits" : ""))" }
        if groups.count > 3 { what.append("\(groups.count - 3) more") }
        var text = "Hi \(firstName(friend))! Friendly nudge 🧊 You still owe \(money(owed))"
        if !what.isEmpty { text += " for " + ListFormatter.localizedString(byJoining: what) }
        text += ". You can send it with Apple Cash right here in Messages"
        text += link.map { ", or use your link: \($0)" } ?? "."
        return text
    }
}

/// A message ready to go: who it's for, what it says and the receipt picture.
struct MessageDraft: Identifiable {
    let id = UUID()
    var recipients: [String]
    var body: String
    var image: Data?
}

/// Messages when this device can text; otherwise the share sheet with the same words and picture.
struct MessageComposer: View {
    let draft: MessageDraft
    var onSent: () -> Void = {}

    var body: some View {
        if MFMessageComposeViewController.canSendText() {
            ComposeView(draft: draft, onSent: onSent).ignoresSafeArea()
        } else {
            ShareView(items: [draft.body] + (draft.image.flatMap(UIImage.init(data:)).map { [$0] } ?? []))
                .presentationDetents([.medium, .large])
        }
    }

    private struct ComposeView: UIViewControllerRepresentable {
        let draft: MessageDraft
        let onSent: () -> Void
        @Environment(\.dismiss) private var dismiss

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIViewController(context: Context) -> MFMessageComposeViewController {
            let controller = MFMessageComposeViewController()
            controller.messageComposeDelegate = context.coordinator
            controller.recipients = draft.recipients
            controller.body = draft.body
            if let image = draft.image, MFMessageComposeViewController.canSendAttachments() {
                controller.addAttachmentData(image, typeIdentifier: "public.png", filename: "Little Fridge split.png")
            }
            return controller
        }

        func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

        final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
            let parent: ComposeView
            init(_ parent: ComposeView) { self.parent = parent }

            func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
                if result == .sent { parent.onSent() }
                parent.dismiss()
            }
        }
    }

    private struct ShareView: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
}

/// The picture that goes with a request: the food, the store and the share, like a little receipt.
struct SplitRequestCard: View {
    let title: String
    let emojis: String?
    let date: Date
    let amount: String
    let friend: String
    let from: String?
    var reminder = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("🧊").font(.system(size: 22))
                Text("Little Fridge").font(.system(size: 20, weight: .heavy, design: .rounded))
                Spacer()
                Text(reminder ? "Reminder" : "Split request").font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.22), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(spacing: 10) {
                Text(emojis.flatMap { $0.isEmpty ? nil : $0 } ?? "🛒").font(.system(size: 54))
                    .padding(.top, 18)
                Text(title).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                Text("\(AppleCashRequest.firstName(friend))'s share").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .padding(.top, 8)
                Text("$\(amount)").font(.system(size: 56, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if let from, !from.isEmpty {
                    Text("to \(from)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 22)

            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                Text("Cash in Messages  ·  Venmo  ·  PayPal")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ink.opacity(0.75))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Theme.softGreen)
            .padding(.top, 22)
        }
        .frame(width: 360)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .padding(12)
        .background(Theme.background)
    }

    /// The card as a PNG for a message.
    @MainActor
    func png() -> Data? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }
}
