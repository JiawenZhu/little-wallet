import SwiftUI

/// Walks through the Shortcuts automation that sends every Apple Pay tap here: a checklist you tick off, with
/// Penny cheering you on, and a celebration when the first tap arrives.
struct TapSetupSheet: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notificationsOn = false
    /// The ready-made shortcut (Apple Pay tap trigger + Save Payment), shared from Shortcuts as an iCloud link.
    /// Opening it shows Add Shortcut; nil hides the one-tap card until a link is set.
    static let oneTapLink: URL? = URL(string: "https://www.icloud.com/shortcuts/a3febb9e37ca4c3e922bb67d54c1ecfc")

    /// Which steps you've ticked, kept between visits ("0,1,3").
    @AppStorage("tap-setup-done") private var doneRaw = ""
    @State private var open: Int?
    @State private var showSteps = false

    private struct Step {
        let icon: String
        let title: String
        /// The words to look for in Shortcuts, drawn like the buttons you'll tap.
        let taps: [String]
        let note: String
    }

    private let steps: [Step] = [
        Step(icon: "square.on.square", title: "Open Shortcuts", taps: ["Automation", "+"], note: "Use the Automation tab at the bottom — not a regular shortcut. The + is in the top corner."),
        Step(icon: "wave.3.right", title: "Choose the tap trigger", taps: ["Transaction"], note: "It has the Wallet icon."),
        Step(icon: "creditcard", title: "Pick your cards", taps: ["All your cards", "Run Immediately"], note: "Run Immediately matters — otherwise iOS waits for you and taps get skipped."),
        Step(icon: "plus.app", title: "Add Little Wallet", taps: ["Create New Shortcut", "Save Payment"], note: "Search for Save Payment (Little Wallet) and tap it."),
        Step(icon: "arrow.triangle.branch", title: "Fill the three blanks", taps: ["Merchant", "Amount", "Card or Pass"], note: "Tap each blue word → Shortcut Input → tap it again and pick the matching one."),
    ]

    private var done: Set<Int> { Set(doneRaw.split(separator: ",").compactMap { Int($0) }) }
    private var current: Int { (0..<steps.count).first { !done.contains($0) } ?? steps.count }
    private var working: Bool { store.lastTapAt != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    // Always offered: someone who removed the shortcut, or set up a new iPhone, adds it back here.
                    if let link = Self.oneTapLink { oneTap(link) }
                    if working {
                        DisclosureGroup(isExpanded: $showSteps) {
                            checklist.padding(.top, 10)
                        } label: {
                            Text("Show the steps").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        }
                        .padding(14)
                        .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        if Self.oneTapLink != nil {
                            Text("Or set it up by hand").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                                .textCase(.uppercase).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }
                        progress
                        checklist
                    }
                    notificationsRow
                    goodToKnow
                }
                .padding(.horizontal, 18).padding(.bottom, 28)
            }
            .background(backdrop)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Track Apple Pay").font(.headline) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .task { notificationsOn = await TapNotifier.isAllowed }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { notificationsOn = await TapNotifier.isAllowed } }
        }
    }

    private var backdrop: some View {
        ZStack(alignment: .top) {
            Theme.background
            RadialGradient(colors: [Color(hex: working ? "#CFE3C8" : "#F6D9C4").opacity(0.9), Theme.background.opacity(0)],
                           center: .top, startRadius: 10, endRadius: 380).frame(height: 460)
        }
        .ignoresSafeArea()
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Image(working ? "PennyHello" : "PennyChecking").resizable().scaledToFit()
                    .frame(height: 130)
                    .offset(y: reduceMotion ? 0 : sin(t * 1.6) * 4)
            }
            Text(working ? "You're all set!" : "Let's catch every tap")
                .font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.ink)
            Text(working
                 ? "Your Apple Pay taps land here by themselves. Last one \(store.lastTapAt!.formatted(.relative(presentation: .named)))."
                 : "Two minutes in Shortcuts, once. After that, every Apple Pay tap saves itself here.")
                .font(.body).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .padding(.top, 4)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: working)
    }

    private var progress: some View {
        let count = done.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(count == steps.count ? "All steps done — now pay with a tap" : "\(count) of \(steps.count) done")
                    .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Spacer()
                Label("Waiting for a tap", systemImage: "wave.3.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { geo in
                Capsule().fill(Theme.line.opacity(0.6))
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [Color(hex: "#E8875A"), Theme.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(10, geo.size.width * Double(count) / Double(steps.count)))
                    }
            }
            .frame(height: 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: count)
        }
    }

    // MARK: - One tap

    private func oneTap(_ link: URL) -> some View {
        VStack(spacing: 12) {
            Text(working ? "New iPhone, or removed the shortcut?" : "Set up in one tap")
                .font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(.white)
            Text(working ? "Add Little Wallet's tap shortcut again."
                         : "Shortcuts opens with Little Wallet's tap shortcut ready. Tap Add Shortcut.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center)
            Button { openURL(link) } label: {
                Label("Add the shortcut", systemImage: "plus.circle.fill").font(.headline).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain).accessibilityIdentifier("one-tap-setup")
            // iOS switches automation off for a shortcut added from a link; it has to be turned on once.
            VStack(alignment: .leading, spacing: 8) {
                Text("Then, one switch:").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                AutomationGuideShot()
                Label("Open it in Shortcuts and tap “When Any Card is tapped”", systemImage: "1.circle.fill")
                Label("Turn on Automation", systemImage: "2.circle.fill")
            }
            .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(18)
        .background(LinearGradient(colors: [Theme.accent, Color(hex: "#5E8B4A")], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.3), radius: 12, y: 6)
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepCard(index, step)
            }
            Button { openURL(URL(string: "shortcuts://")!) } label: {
                Label("Open Shortcuts", systemImage: "arrow.up.forward.app").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.accent.opacity(0.25), radius: 8, y: 4)
            }
            .buttonStyle(.plain).padding(.top, 4)
        }
    }

    private func stepCard(_ index: Int, _ step: Step) -> some View {
        let isDone = done.contains(index)
        let expanded = (open ?? current) == index && !isDone
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { toggle(index) } label: {
                    ZStack {
                        Circle().fill(isDone ? Theme.accent : Theme.card)
                        Circle().strokeBorder(isDone ? Theme.accent : Theme.line, lineWidth: 2)
                        if isDone {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Text("\(index + 1)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDone ? "Step \(index + 1) done. Undo" : "Mark step \(index + 1) done")

                Image(systemName: step.icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isDone ? Theme.secondary : Theme.accent).frame(width: 22)
                Text(step.title).font(.headline).foregroundStyle(isDone ? Theme.secondary : Theme.ink)
                    .strikethrough(isDone, color: Theme.secondary.opacity(0.5))
                Spacer()
                if !isDone {
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    FlowChips(words: step.taps)
                    Text(step.note).font(.subheadline).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { toggle(index) } label: {
                        Text("Done with this step").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Theme.softGreen, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 46)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(Theme.card.opacity(isDone ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(expanded ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1.5))
        .shadow(color: .black.opacity(expanded ? 0.06 : 0), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { if !isDone { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { open = index } } }
        .sensoryFeedback(.success, trigger: isDone) { _, now in now }
    }

    private func toggle(_ index: Int) {
        var set = done
        if set.contains(index) { set.remove(index) } else { set.insert(index) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            doneRaw = set.sorted().map(String.init).joined(separator: ",")
            open = nil
        }
    }

    // MARK: - Notifications

    private var notificationsRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill").font(.system(size: 18)).foregroundStyle(Color(hex: "#E8875A"))
                .frame(width: 40, height: 40).background(Color(hex: "#FBE7DA"), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Tell me when a tap is saved").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("“$13.00 at Trader Joe's — saved”").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if notificationsOn {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.accent).accessibilityLabel("On")
            } else {
                Button("Turn on") {
                    Task {
                        if await TapNotifier.requestPermission() { notificationsOn = true }
                        else if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }
                .font(.subheadline.weight(.bold)).buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Good to know

    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Good to know").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary).textCase(.uppercase)
            fact("📍", "Works when you tap your phone at a store terminal.")
            fact("📱", "App Store, in-app and website purchases aren't card taps — add those with Type it or Say it.")
            fact("🧾", "Apple Pay shares the shop, amount and card — never the items.")
            fact("✏️", "If a card doesn't share the amount, it's still saved and Penny asks you for it.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ emoji: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(emoji)
            Text(text).font(.footnote).foregroundStyle(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Words from Shortcuts, drawn like the buttons you'll tap there, joined by arrows.
private struct FlowChips: View {
    let words: [String]
    var body: some View {
        WrapLayout(spacing: 6, lineSpacing: 6, leading: true) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text(word).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Color(hex: "#3A7BD5"), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    if index < words.count - 1 {
                        Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }
}

/// The real Shortcuts screen with the two spots marked: tap the trigger, then turn on Automation.
private struct AutomationGuideShot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Image("SetupAutomationShot").resizable().scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    // ① The "When Any Card is tapped" row (in the image: x 4–96%, y 3–25%).
                    mark(RoundedRectangle(cornerRadius: 14, style: .continuous), width: w * 0.93, height: h * 0.21)
                        .position(x: w * 0.5, y: h * 0.143)
                    badge(1, "Tap here").position(x: w * 0.5, y: h * 0.31)
                    // ② The Automation switch (x 79–93%, y 65–76%).
                    mark(Capsule(), width: w * 0.17, height: h * 0.15)
                        .position(x: w * 0.861, y: h * 0.705)
                    badge(2, "Turn on").position(x: w * 0.6, y: h * 0.705)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityElement()
            .accessibilityLabel("In Shortcuts, tap When Any Card is tapped, then turn on the Automation switch.")
    }

    private func mark<S: Shape>(_ shape: S, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            shape.stroke(Color(hex: "#E8875A"), lineWidth: 3)
            shape.stroke(Color(hex: "#E8875A").opacity(pulse ? 0 : 0.5), lineWidth: pulse ? 12 : 3)
        }
        .frame(width: width, height: height)
        .scaleEffect(pulse ? 1.04 : 1)
    }

    private func badge(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text("\(number)").font(.caption.weight(.heavy)).foregroundStyle(Color(hex: "#E8875A"))
                .frame(width: 18, height: 18).background(.white, in: Circle())
            Text(text).font(.caption.weight(.bold)).foregroundStyle(.white)
        }
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 4)
        .background(Color(hex: "#E8875A"), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .fixedSize()
    }
}
