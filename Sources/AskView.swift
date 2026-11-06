import SwiftUI

/// Penny, the helper at Little Wallet's front desk: ask her about your money by tapping a question, typing, or
/// saying it, and she looks it up in your payments.
struct AskView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject private var memory = AskMemory.shared
    @ObservedObject private var splits = SplitService.shared
    @ObservedObject private var chat = PennyChat.shared
    @StateObject private var listener = VoiceListener()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var turns: [PennyTurn] { chat.turns }
    @State private var typed = ""
    @State private var listening = false
    @FocusState private var typing: Bool

    private var analyst: Analyst { Analyst(payments: splits.netted(store.transactions), balances: SettleBalance.from(splits.splits)) }
    private var suggestions: [AskQuestion] { Suggester.questions(analyst, memory: memory.interest, recent: memory.recent) }
    private var busy: Bool { turns.last.map { $0.answer == nil } ?? false }

    /// A short picture of this person for the model: what they ask about and where they spend.
    private var profile: [String] {
        var facts: [String] = []
        if !memory.favorites.isEmpty { facts.append("often asks about " + memory.favorites.joined(separator: ", ")) }
        let shops = analyst.byMerchant(.allTime).prefix(3).map(\.name)
        if !shops.isEmpty { facts.append("shops most at " + shops.joined(separator: ", ")) }
        if let top = analyst.byCategory(.thisMonth).first { facts.append("spends most on \(top.category.title.lowercased()) this month") }
        return facts
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        welcome
                        ForEach(turns) { turn in
                            YourBubble(text: turn.question)
                            if let answer = turn.answer {
                                PennyReply(insight: answer, ask: ask)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            } else {
                                PennyTyping().transition(.opacity)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns) { _, _ in withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            inputBar
        }
        .background(backdrop)
        .onChange(of: listener.phase) { _, phase in
            if phase != .listening, listening {
                listening = false
                if !listener.transcript.isEmpty { ask(listener.transcript) }
            }
        }
        .onDisappear { listener.stop() }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-penny-reset") { chat.startOver(); chat.forget(nil) }
            if let questions = UserDefaults.standard.string(forKey: "ask-text"), !questions.isEmpty {
                // Several questions in a row, split by "||", to check a whole conversation.
                for question in questions.components(separatedBy: "||") {
                    try? await Task.sleep(for: .seconds(1.2))
                    while busy { try? await Task.sleep(for: .milliseconds(200)) }
                    ask(question.trimmingCharacters(in: .whitespaces))
                }
            }
            #endif
        }
    }

    private var backdrop: some View {
        ZStack(alignment: .top) {
            Theme.background
            RadialGradient(colors: [Color(hex: "#F6D9C4").opacity(0.9), Theme.background.opacity(0)],
                           center: .top, startRadius: 10, endRadius: 420)
                .frame(height: 520)
        }
        .ignoresSafeArea()
    }

    // MARK: - Header and welcome

    private var header: some View {
        HStack(spacing: 10) {
            PennyAvatar(size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("Penny").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: "#5E8B4A")).frame(width: 7, height: 7)
                    Text("Your money helper").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            if !turns.isEmpty {
                Button { withAnimation(.snappy) { chat.startOver() } } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40).background(Theme.card, in: Circle())
                }
                .accessibilityLabel("Start over")
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40).background(Theme.card, in: Circle())
            }
            .accessibilityLabel("Close")
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            if turns.isEmpty {
                FloatingPenny().frame(height: 170).padding(.top, 8)
            }
            PennyBubble {
                Text(chat.pickUp ?? Penny.greeting(analyst)).font(.body).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if turns.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask me things like").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                        .textCase(.uppercase).padding(.leading, 4)
                    let half = (suggestions.count + 1) / 2
                    DriftingChips(questions: Array(suggestions.prefix(half)), speed: 20, ask: ask)
                        .padding(.horizontal, -16)
                    DriftingChips(questions: Array(suggestions.dropFirst(half)), speed: -16, ask: ask)
                        .padding(.horizontal, -16)
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            if listening {
                HStack(spacing: 8) {
                    ListeningBars(level: listener.level)
                    Text(listener.transcript.isEmpty ? "I'm listening…" : listener.transcript)
                        .font(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Ask Penny about your money", text: $typed, axis: .vertical)
                    .lineLimit(1...3).focused($typing).submitLabel(.send)
                    .onSubmit { ask(typed) }
                    .accessibilityIdentifier("ask-field")
            }
            if !typed.trimmingCharacters(in: .whitespaces).isEmpty && !listening {
                Button { ask(typed) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(Theme.accent, in: Circle())
                }
                .accessibilityLabel("Send")
            } else {
                Button {
                    if listening { listener.stop() } else { typing = false; listening = true; Task { await listener.start() } }
                } label: {
                    Image(systemName: listening ? "stop.fill" : "mic.fill").font(.system(size: 17, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(listening ? Color(hex: "#E8875A") : Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(listening ? "Stop listening" : "Ask out loud")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 18).padding(.trailing, 7).padding(.vertical, 7)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
        .disabled(busy)
    }

    // MARK: - Asking

    private func ask(_ question: AskQuestion) {
        guard !busy else { return }
        if case .act(let request) = question.intent { return act(question.text, request: request) }
        memory.asked(question.text, topics: question.intent.topics)
        reply(to: question.text, intent: question.intent, analyst: analyst)
    }

    private func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        typed = ""
        typing = false
        // Things she's told to remember or forget, then actions, then follow-ups, each with the conversation in mind.
        if let answer = chat.command(question) {
            start(question)
            return after(.milliseconds(500)) { finish(answer) }
        }
        if PennyPlanner.isAction(question, context: chat.context) { return act(question, request: question) }
        let analyst = self.analyst
        if let (intent, answer) = chat.budgetCheck(question, analyst: analyst) {
            start(question)
            chat.context.absorb(intent, answer: answer)
            return after(.milliseconds(reduceMotion ? 0 : 700)) { finish(answer) }
        }
        if let intent = chat.context.followUp(question, analyst: analyst) {
            memory.asked(question, topics: intent.topics)
            return reply(to: question, intent: intent, analyst: analyst)
        }
        let intent = AskRouter.intent(for: question, analyst: analyst)
        if let intent { memory.asked(question, topics: intent.topics) }
        start(question)
        let known = AskAgent.Memory(history: chat.recentHistory, context: chat.context.summary, facts: chat.facts,
                                    done: chat.done.suffix(3).map(\.text), recalled: chat.recall(question))
        Task {
            let started = Date.now
            let (insight, engine, used) = await AskAgent.answer(question, analyst: analyst, profile: profile, memory: known)
            let reply = engine == .appleIntelligence ? insight : Penny.speak(insight, intent: used ?? intent, question: question)
            let waited = Date.now.timeIntervalSince(started)
            if waited < 0.8, !reduceMotion { try? await Task.sleep(for: .milliseconds(Int((0.8 - waited) * 1000))) }
            if let used { chat.context.absorb(used, answer: insight) }
            finish(reply)
        }
    }

    /// An exact answer, and the conversation moves on to what it was about.
    private func reply(to question: String, intent: AskIntent, analyst: Analyst) {
        let insight = analyst.answer(intent)
        let spoken = Penny.speak(insight, intent: intent, question: question)
        start(question)
        chat.context.absorb(intent, answer: insight)
        // A short beat, the way a person would look it up.
        after(.milliseconds(reduceMotion ? 0 : 900)) { finish(spoken) }
    }

    private func start(_ question: String) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { chat.turns.append(PennyTurn(question: question)) }
    }

    private func after(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: delay)
            work()
        }
    }

    /// Something to do in PayPal: Penny lays it out as a card, and nothing happens until it's confirmed.
    private func act(_ shown: String, request: String) {
        typed = ""
        typing = false
        memory.asked(shown, topics: ["act"])
        let reply = PennyPlanner.reply(to: request, splits: splits, paypal: PayPalLink.shared, context: &chat.context)
        start(shown)
        after(.milliseconds(reduceMotion ? 0 : 900)) { finish(reply) }
    }

    private func finish(_ insight: Insight) {
        guard let index = chat.turns.indices.last else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { chat.turns[index].answer = insight }
        chat.save()
    }
}

// MARK: - Penny's voice

/// How Penny talks: a greeting with a real fact, and a natural opener before each answer.
enum Penny {
    static func greeting(_ analyst: Analyst) -> String {
        let hour = analyst.calendar.component(.hour, from: analyst.now)
        let hello = hour < 12 ? "Good morning!" : hour < 18 ? "Good afternoon!" : "Good evening!"
        let month = Period.monthName(analyst.now)
        let spent = analyst.total(.thisMonth)
        let fact: String
        if analyst.payments.isEmpty {
            fact = "Once you pay with Apple Pay or add a payment, I can tell you where your money goes."
        } else if spent == 0 {
            fact = "Nothing spent yet in \(month) — a quiet start."
        } else if let top = analyst.byCategory(.thisMonth).first {
            fact = "You've spent \(dollars(spent)) so far in \(month), most of it on \(top.category.title.lowercased())."
        } else {
            fact = "You've spent \(dollars(spent)) so far in \(month)."
        }
        return "\(hello) I'm Penny. \(fact) What can I look up for you?"
    }

    /// Adds a friendly opener, picked steadily from the question so the same question always sounds the same.
    static func speak(_ insight: Insight, intent: AskIntent?, question: String) -> Insight {
        let openers: [String]
        switch intent {
        case .total?: openers = ["Sure!", "Here you go.", "Let me add that up for you."]
        case .biggest?: openers = ["Found it.", "Let me see…", "Here's the big one."]
        case .categories?: openers = ["Here's where it went.", "Good question."]
        case .merchants?: openers = ["Here are your top spots.", "Let me look."]
        case .compare?: openers = ["Good question.", "Let me put them side by side."]
        case .habit?: openers = ["Let me count.", "You're a regular!"]
        case .dailyAverage?: openers = ["Here's your average.", "Let me work that out."]
        case .day?: openers = ["Here's what you bought.", "Let me check."]
        case .owed?, .owedBy?: openers = ["Let me check your splits.", "Here's who owes you."]
        case .act?: openers = ["On it."]
        case nil: openers = ["Happy to help!"]
        }
        let seed = question.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        var spoken = insight
        spoken.text = "\(openers[seed % openers.count]) \(insight.text)"
        return spoken
    }
}

// MARK: - Pieces

/// Penny's small round face.
struct PennyAvatar: View {
    var size: CGFloat
    var body: some View {
        Image("PennyFace").resizable().scaledToFill()
            .frame(width: size, height: size)
            .background(Color(hex: "#F6E3D3"))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

/// Penny waving hello, bobbing gently.
private struct FloatingPenny: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Image("PennyHello").resizable().scaledToFit()
                .offset(y: reduceMotion ? 0 : sin(t * 1.6) * 5)
                .rotationEffect(.degrees(reduceMotion ? 0 : sin(t * 1.1) * 1.5), anchor: .bottom)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

private let pennyShape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 22,
                                                topTrailingRadius: 22, style: .continuous)

/// A speech bubble from Penny, with her face beside it.
struct PennyBubble<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PennyAvatar(size: 32)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(Theme.card, in: pennyShape)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
            Spacer(minLength: 24)
        }
    }
}

private struct YourBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(text).font(.body.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Theme.accent, in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                                                     bottomTrailingRadius: 6, topTrailingRadius: 22, style: .continuous))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Penny's answer: what she says, the number, a small receipt of what's behind it, and quick replies.
private struct PennyReply: View {
    let insight: Insight
    let ask: (AskQuestion) -> Void
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PennyBubble {
                Text(insight.text).font(.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                if let headline = insight.headline, headline.hasPrefix("$") || headline.hasPrefix("+") || headline.hasPrefix("−") || headline.hasSuffix("×") {
                    Text(headline).font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.ink).minimumScaleFactor(0.6).lineLimit(1)
                }
                if !insight.rows.isEmpty { receipt }
            }
            if let plan = insight.plan {
                PlanCard(plan: plan).padding(.leading, 40)
            } else if let closed = insight.closedPlan {
                Label("\(closed) · ask again to send", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                    .padding(.leading, 44)
            }
            if !insight.followUps.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(insight.followUps) { question in
                            Button { ask(question) } label: {
                                HStack(spacing: 6) {
                                    Text(question.emoji)
                                    Text(question.text).font(.subheadline.weight(.semibold))
                                }
                                .padding(.horizontal, 13).frame(height: 38)
                                .background(Theme.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35)))
                                .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 40)
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear { shown = true }
    }

    private var receipt: some View {
        VStack(spacing: 0) {
            ForEach(Array(insight.rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 10) {
                    Group {
                        if let image = row.image { Image(image).resizable().scaledToFit() }
                        else { Text(row.emoji ?? "•").font(.title3) }
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
                            Spacer(minLength: 6)
                            Text(row.value).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                        }
                        if let share = row.share {
                            GeometryReader { geo in
                                Capsule().fill(Theme.line.opacity(0.6))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Theme.accent.opacity(0.75)).frame(width: geo.size.width * (shown ? share : 0))
                                    }
                            }
                            .frame(height: 5)
                            .animation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.2 + 0.06 * Double(index)), value: shown)
                        }
                    }
                }
                .padding(.vertical, 8)
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
                .animation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.1 + 0.07 * Double(index)), value: shown)
                if index < insight.rows.count - 1 {
                    DashedLine().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

/// Penny reading a receipt, with three dots bouncing like someone typing.
private struct PennyTyping: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Image("PennyChecking").resizable().scaledToFit().frame(width: 52, height: 52)
            HStack(spacing: 10) {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 5) {
                        ForEach(0..<3) { i in
                            Circle().fill(Theme.secondary.opacity(0.7)).frame(width: 8, height: 8)
                                .offset(y: reduceMotion ? 0 : -abs(sin(t * 5 - Double(i) * 0.6)) * 5)
                        }
                    }
                }
                Text("Checking your payments").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(Theme.card, in: pennyShape)
            Spacer()
        }
        .accessibilityElement().accessibilityLabel("Penny is checking your payments")
    }
}

/// Little bars that move with your voice while Penny listens.
private struct ListeningBars: View {
    let level: Double
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                Capsule().fill(Color(hex: "#E8875A"))
                    .frame(width: 4, height: 6 + level * 16 * (i % 2 == 0 ? 1 : 0.6))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .frame(width: 26, height: 24)
    }
}

/// A row of question chips that drifts sideways on its own, like a slow ticker; tap one to ask it.
struct DriftingChips: View {
    let questions: [AskQuestion]
    /// Points per second; negative drifts the other way.
    let speed: Double
    let ask: (AskQuestion) -> Void
    @State private var width: CGFloat = 0
    @State private var started = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || questions.count < 2 {
            ScrollView(.horizontal) { chips.padding(.horizontal, 16) }.scrollIndicators(.hidden)
        } else {
            // The moving row lives in an overlay, so its width never stretches the screen.
            Color.clear.frame(maxWidth: .infinity).frame(height: 50)
                .overlay(alignment: .leading) {
                    TimelineView(.animation) { context in
                        let travelled = context.date.timeIntervalSince(started) * speed
                        let offset = width > 0 ? CGFloat(travelled.truncatingRemainder(dividingBy: Double(width))) : 0
                        HStack(spacing: 0) { chips; chips }
                            .fixedSize()
                            .offset(x: speed > 0 ? -offset : -width - offset)
                    }
                }
                .clipped()
        }
    }

    private var chips: some View {
        HStack(spacing: 10) {
            ForEach(questions) { question in
                Button { ask(question) } label: {
                    HStack(spacing: 8) {
                        Text(question.emoji).font(.system(size: 18))
                            .frame(width: 34, height: 34).background(Theme.softGreen, in: Circle())
                        Text(question.text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(1).fixedSize()
                    }
                    .padding(.leading, 7).padding(.trailing, 16).frame(height: 48)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(question.text)
            }
        }
        .padding(.trailing, 10)
        .fixedSize()
        .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width } })
    }
}

extension AskQuestion {
    /// A friendly picture for the chip.
    var emoji: String {
        switch intent {
        case let .total(_, category, merchant):
            if merchant != nil { return "🏪" }
            return category?.emoji ?? "💵"
        case .biggest: return "👑"
        case .categories: return "🧺"
        case .merchants: return "🏪"
        case .compare: return "📊"
        case .habit: return "🔁"
        case .dailyAverage: return "📆"
        case .day: return "🕒"
        case .owed, .owedBy: return "🤝"
        case .act: return "🔔"
        }
    }
}
