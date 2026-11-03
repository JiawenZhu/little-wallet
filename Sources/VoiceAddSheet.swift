import SwiftUI

/// Say what you paid for — "$13 strawberries at Trader Joe's, split with Sam and Kate" — and it's saved as a
/// payment with its items. When it's shared, the split sheet opens with those people already picked.
struct VoiceAddSheet: View {
    @ObservedObject var store: WalletStore
    @StateObject private var listener = VoiceListener()
    @ObservedObject private var service = SplitService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Equatable { case listening, typing, thinking, review, split(UUID) }
    @State private var step: Step = .listening
    @State private var typed = ""
    @State private var heard = ""
    @State private var plan = VoicePlan()
    @State private var engine: VoiceAgent.Engine = .parser
    @State private var priceTexts: [UUID: String] = [:]
    @State private var revealed = false
    /// Debug demos: a sentence played in word by word, as if spoken.
    @State private var demoText: String?
    @State private var demoLevel: Double = 0
    @FocusState private var typingFocused: Bool

    /// Friends you've split with, so "Kit" can become Kate.
    private var knownPeople: [String] { service.friends.map(\.name) }

    var body: some View {
        Group {
            switch step {
            case .listening, .typing: capture
            case .thinking: thinking
            case .review: review
            case .split(let id): SplitSheet(store: store, transactionID: id, presetPeople: plan.people)
            }
        }
        .background {
            switch step {
            case .listening, .typing, .thinking: VoiceAura(level: level, listening: step == .listening)
            default: Theme.background.ignoresSafeArea()
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: step)
        .task {
            #if DEBUG
            // Simulator checks: understand a sentence without a microphone.
            if let text = UserDefaults.standard.string(forKey: "voice-text"), !text.isEmpty {
                understand(text)
                return
            }
            if let text = UserDefaults.standard.string(forKey: "voice-demo"), !text.isEmpty {
                await playDemo(text)
                return
            }
            #endif
            listener.hints = knownPeople
            await listener.start()
            if listener.phase != .listening { step = .typing }
        }
        .onDisappear { listener.stop() }
    }

    // MARK: - Capture

    private var capture: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                circleButton("xmark", label: "Close") { dismiss() }
            }
            .padding(.horizontal, 20).padding(.top, 14)

            Spacer()
            if step == .typing {
                VStack(alignment: .leading, spacing: 12) {
                    Text(listener.phase == .denied ? "Turn on the microphone and speech recognition in Settings to talk, or type it here."
                         : "Type what you paid for")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                    TextField("$13 strawberries, split with Sam and Kate", text: $typed, axis: .vertical)
                        .font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                        .lineLimit(1...5).focused($typingFocused).submitLabel(.done)
                        .onSubmit { understand(typed) }
                        .accessibilityIdentifier("voice-typed")
                }
                .padding(.horizontal, 28)
                .onAppear { typingFocused = true }
            } else {
                ZStack {
                    VStack(spacing: 18) {
                        ScatteringText(text: "Tell me what you paid for", gone: !liveText.isEmpty)
                            .foregroundStyle(Theme.ink.opacity(0.38))
                        VStack(spacing: 8) {
                            example("“$13 strawberries at Trader Joe's”")
                            example("“Uber 18 dollars”")
                            example("“Split $13 strawberries with Sam and Kate”")
                        }
                        .opacity(liveText.isEmpty ? 1 : 0)
                        .offset(y: liveText.isEmpty ? 0 : 24)
                        .animation(.easeOut(duration: 0.4), value: liveText.isEmpty)
                    }
                    if !liveText.isEmpty {
                        LiveLetters(text: liveText, level: level)
                            .foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("voice-transcript")
                    }
                }
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            }
            Spacer()

            HStack(alignment: .center) {
                circleButton(step == .typing ? "mic.fill" : "keyboard", label: step == .typing ? "Talk instead" : "Type instead") {
                    if step == .typing {
                        step = .listening
                        Task { await listener.start() }
                    } else {
                        listener.stop()
                        typed = listener.transcript
                        step = .typing
                    }
                }
                Spacer()
                if step == .listening { listeningRing }
                Spacer()
                Button {
                    understand(step == .typing ? typed : liveText)
                } label: {
                    Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain).disabled(currentText.isEmpty).opacity(currentText.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Done").accessibilityIdentifier("voice-done")
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
        }
    }

    private var liveText: String { demoText ?? listener.transcript }
    private var level: Double { demoText == nil ? listener.level : demoLevel }

    private var currentText: String {
        (step == .typing ? typed : liveText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plays a sentence in word by word with a voice-like level, then understands it.
    private func playDemo(_ text: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        var shown: [Substring] = []
        for word in text.split(separator: " ") {
            shown.append(word)
            demoText = shown.joined(separator: " ")
            for tick in 0..<8 {
                demoLevel = 0.35 + 0.45 * abs(sin(Double(tick) * 0.9 + Double(shown.count)))
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
        demoLevel = 0
        try? await Task.sleep(for: .seconds(1.1))
        understand(text)
    }

    private var listeningRing: some View {
        ZStack {
            Circle().fill(Theme.card.opacity(0.45)).frame(width: 92, height: 92)
                .scaleEffect(reduceMotion ? 1 : 0.8 + level * 0.6)
            Circle().fill(Theme.card.opacity(0.8)).frame(width: 66, height: 66)
                .scaleEffect(reduceMotion ? 1 : 0.9 + level * 0.3)
            Image(systemName: "waveform").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel(listener.phase == .listening ? "Listening" : "Not listening")
    }

    private func example(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.card, in: Capsule())
    }

    // MARK: - Thinking

    private var thinking: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("“\(heard)”").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink.opacity(0.55))
                .multilineTextAlignment(.center).padding(.horizontal, 28)
                .transition(.scale(scale: 1.6).combined(with: .opacity))
            Text("Writing it down…").font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                .shimmering()
            Label("Stays on your iPhone", systemImage: "lock.iphone")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func understand(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        listener.stop()
        heard = text
        step = .thinking
        Task {
            let (found, used) = await VoiceAgent.understand(text, friends: knownPeople)
            plan = found
            engine = used
            priceTexts = Dictionary(uniqueKeysWithValues: found.lines.map { ($0.id, money($0.cents, symbol: false)) })
            revealed = false
            step = .review
            try? await Task.sleep(for: .milliseconds(80))
            revealed = true
        }
    }

    // MARK: - Review

    private var review: some View {
        VStack(spacing: 0) {
            HStack {
                circleButton("arrow.counterclockwise", label: "Say it again") {
                    plan = VoicePlan()
                    step = .listening
                    Task { await listener.start() }
                }
                Spacer()
                circleButton("xmark", label: "Close") { dismiss() }
            }
            .padding(.horizontal, 20).padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("“\(heard)”").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                        Label("Here's what I heard — fix anything before saving", systemImage: "checkmark.bubble")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    if plan.isEmpty {
                        Text("I didn't catch a price. Try “strawberries, 13 dollars”.")
                            .font(.headline).foregroundStyle(Theme.ink)
                    } else {
                        receipt.modifier(Reveal(on: revealed, delay: 0))
                        splitCard.modifier(Reveal(on: revealed, delay: 0.12 + Double(plan.lines.count) * 0.06))
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)

            if !plan.isEmpty {
                Button(action: save) {
                    Label(plan.wantsSplit ? "Add & split \(plan.sharers > 1 ? "\(plan.sharers) ways" : "")" : "Save payment",
                          systemImage: plan.wantsSplit ? "person.2.fill" : "checkmark")
                        .font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain).disabled(plan.totalCents == 0)
                .padding(.horizontal, 20).padding(.bottom, 14)
                .accessibilityIdentifier("voice-save")
            }
        }
    }

    private var receipt: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bag.fill").foregroundStyle(.white).frame(width: 36, height: 36)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                TextField("Shop", text: $plan.store).font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Divider()
            ForEach($plan.lines) { $line in
                let order = Double(plan.lines.firstIndex(where: { $0.id == line.id }) ?? 0)
                HStack(spacing: 10) {
                    Text(SplitService.emoji(for: line.name, category: .guess(merchant: plan.store, items: [line.name]))).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        TextField("Item", text: $line.name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        if line.quantity > 1 { Text("×\(line.quantity)").font(.caption).foregroundStyle(Theme.secondary) }
                    }
                    Spacer()
                    HStack(spacing: 1) {
                        Text("$").foregroundStyle(Theme.secondary)
                        TextField("0.00", text: priceBinding(line.id)).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing).frame(width: 64)
                    }
                    .font(.body.weight(.bold).monospacedDigit())
                    Button { plan.lines.removeAll { $0.id == line.id } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(line.name)")
                }
                .modifier(Reveal(on: revealed, delay: 0.08 + order * 0.06))
            }
            Divider()
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text(money(plan.totalCents)).font(.title3.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(Theme.ink)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var splitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $plan.wantsSplit.animation()) {
                Label("Split the cost", systemImage: "person.2").font(.headline).foregroundStyle(Theme.ink)
            }
            .tint(Theme.accent)
            if plan.wantsSplit {
                let names = ["You"] + plan.people + Array(repeating: "Someone", count: max(0, plan.sharers - plan.people.count - 1))
                ForEach(Array(zip(names.indices, names)), id: \.0) { index, name in
                    HStack(spacing: 10) {
                        Text(String(name.prefix(1))).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(SplitPerson.palette[index % SplitPerson.palette.count], in: Circle())
                        Text(name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        if index > 0 && index <= plan.people.count {
                            Button { plan.people.remove(at: index - 1) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(name)")
                        }
                        Spacer()
                        Text(money(plan.shares[safe: index] ?? 0)).font(.body.weight(.bold).monospacedDigit())
                            .foregroundStyle(index == 0 ? Theme.secondary : Theme.ink)
                    }
                }
                Text(plan.people.isEmpty ? "You'll pick who's sharing next." : "Each share is exact to the cent. You'll send links next.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func priceBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { priceTexts[id] ?? "" }, set: { text in
            priceTexts[id] = text
            if let index = plan.lines.firstIndex(where: { $0.id == id }) {
                plan.lines[index].cents = Int(((Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0) * 100).rounded())
            }
        })
    }

    // MARK: - Save

    private func save() {
        let items = plan.lines.map { LineItem(name: $0.name, quantity: $0.quantity, price: Double($0.cents) / 100) }
        let saved = store.add(merchant: plan.store.isEmpty ? (items.count == 1 ? items[0].name : "Payment") : plan.store,
                              amount: Double(plan.totalCents) / 100, source: .voice, items: items)
        if plan.wantsSplit { step = .split(saved.id) } else { dismiss() }
    }

    // MARK: - Pieces

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44).background(Theme.card, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func money(_ cents: Int, symbol: Bool = true) -> String {
        (symbol ? "$" : "") + String(format: "%d.%02d", cents / 100, cents % 100)
    }
}

/// Slides a piece of the review up into place, a beat after the piece before it.
private struct Reveal: ViewModifier {
    let on: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : 18)
            .blur(radius: on || reduceMotion ? 0 : 4)
            .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(delay), value: on)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
