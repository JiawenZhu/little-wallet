import SwiftUI

/// The listening screen's backdrop: warm light that drifts on its own, and a glow around the screen's edge
/// that swells while you talk.
struct VoiceAura: View {
    /// 0...1, how loud the voice is.
    var level: Double
    var listening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let blobs: [(Color, CGFloat, Double, Double)] = [
        (Color(red: 0.98, green: 0.74, blue: 0.56), 1.15, 0.00, 0.13),  // peach
        (Color(red: 0.64, green: 0.79, blue: 0.62), 1.05, 2.10, 0.11),  // sage
        (Color(red: 0.99, green: 0.88, blue: 0.70), 0.95, 4.20, 0.17),  // butter
        (Color(red: 0.86, green: 0.62, blue: 0.62), 0.80, 1.30, 0.09),  // rose
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Theme.background
                    ForEach(Self.blobs.indices, id: \.self) { i in
                        let (color, size, phase, speed) = Self.blobs[i]
                        Circle()
                            .fill(color)
                            .frame(width: w * size, height: w * size)
                            .position(x: w * (0.5 + 0.38 * cos(t * speed + phase)),
                                      y: h * (0.5 + 0.34 * sin(t * speed * 0.8 + phase * 1.7)))
                            .scaleEffect(1 + level * 0.12)
                            .opacity(0.75)
                    }
                }
                .blur(radius: 70)
                .overlay { edgeGlow(t: t) }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func edgeGlow(t: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 56, style: .continuous)
        let colors = [Color.white, Color(red: 0.98, green: 0.70, blue: 0.52), Theme.accent.opacity(0.7),
                      Color(red: 1, green: 0.9, blue: 0.75), Color.white]
        let gradient = AngularGradient(colors: colors, center: .center, angle: .degrees(reduceMotion ? 0 : t * 40))
        let strength = listening ? 0.55 + level * 0.45 : 0.3
        return ZStack {
            shape.stroke(gradient, lineWidth: 10 + level * 14).blur(radius: 18)
            shape.stroke(gradient, lineWidth: 2.5).blur(radius: 1.5)
        }
        .opacity(strength)
        .animation(.easeOut(duration: 0.15), value: level)
    }
}

/// What you're saying, letter by letter: each one springs in out of a blur, a beat after the one before, and
/// the line sways with your voice.
struct LiveLetters: View {
    let text: String
    var level: Double = 0
    var font: Font = .system(size: 34, weight: .bold, design: .rounded)
    @State private var settled = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || level < 0.02)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            WrapLayout(spacing: 9, lineSpacing: 4) {
                ForEach(Self.words(text), id: \.start) { word in
                    HStack(spacing: 0) {
                        ForEach(Array(word.text.enumerated()), id: \.offset) { offset, character in
                            let index = word.start + offset
                            Letter(character: character, font: font,
                                   delay: reduceMotion ? 0 : Double(max(0, index - settled)) * 0.035,
                                   sway: reduceMotion ? 0 : sin(t * 7 + Double(index) * 0.5) * level * 7)
                                .id("\(index)\(character)")
                        }
                    }
                }
            }
        }
        .onChange(of: text.count) { _, count in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled = count }
        }
        .accessibilityElement().accessibilityLabel(text)
    }

    private static func words(_ text: String) -> [(start: Int, text: String)] {
        var result: [(Int, String)] = []
        var index = 0
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if !word.isEmpty { result.append((index, String(word))) }
            index += word.count + 1
        }
        return result
    }

    private struct Letter: View {
        let character: Character
        let font: Font
        let delay: Double
        let sway: Double
        @State private var landed = false

        var body: some View {
            Text(String(character)).font(font)
                .blur(radius: landed ? 0 : 7)
                .opacity(landed ? 1 : 0)
                .scaleEffect(landed ? 1 : 0.35, anchor: .bottom)
                .offset(y: (landed ? 0 : 20) + sway)
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(delay)) { landed = true }
                }
        }
    }
}

/// Text that drifts apart into blurred letters, sweeping left to right, when `gone` turns on.
struct ScatteringText: View {
    let text: String
    let gone: Bool
    var font: Font = .system(.title, design: .rounded).weight(.bold)

    var body: some View {
        WrapLayout(spacing: 8, lineSpacing: 2) {
            ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { w, word in
                HStack(spacing: 0) {
                    ForEach(Array(word.enumerated()), id: \.offset) { c, character in
                        let seed = Double(w * 31 + c * 7)
                        let order = Double(w * 6 + c)
                        Text(String(character)).font(font)
                            .offset(x: gone ? sin(seed * 12.9) * 46 : 0, y: gone ? cos(seed * 78.2) * 34 - 10 : 0)
                            .scaleEffect(gone ? 0.5 : 1)
                            .blur(radius: gone ? 9 : 0)
                            .opacity(gone ? 0 : 1)
                            .animation(.easeOut(duration: 0.55).delay(gone ? order * 0.012 : 0), value: gone)
                    }
                }
            }
        }
        .accessibilityHidden(gone)
    }
}

/// A light that sweeps across text, for "Understanding…".
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width * 1.5)
            }
            .mask(content)
            .allowsHitTesting(false)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Lays views out in centered rows that wrap, like words in a paragraph.
struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    /// Rows start at the left edge instead of being centred.
    var leading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = leading ? bounds.minX : bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if next > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], next, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
