import SwiftUI
import PhotosUI
import VisionKit

/// Snap a receipt, or pick a photo or screenshot of one: it's read on the phone, printed back line by line to check,
/// and saved as a payment with every item, ready to split evenly or by who had what.
struct ReceiptScanSheet: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Equatable { case choose, reading, review, split(UUID) }
    @State private var step: Step = .choose
    @State private var image: UIImage?
    @State private var marks: [ReceiptMark] = []
    @State private var marksShown = 0
    @State private var scan = ReceiptScan()
    @State private var engine: ReceiptReader.Engine = .parser
    @State private var category: SpendCategory = .other
    @State private var priceTexts: [UUID: String] = [:]
    @State private var totalText = ""
    @State private var printed = 0
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var usingCamera = false
    @State private var ticks = 0
    @State private var landed = 0
    /// A payment already in the wallet that this receipt is for, like the Apple Pay tap at the till.
    @State private var matched: Payment?
    @State private var useMatch = true

    var body: some View {
        Group {
            switch step {
            case .split(let id): SplitSheet(store: store, transactionID: id)
            default:
                NavigationStack {
                    Group {
                        switch step {
                        case .choose: choose
                        case .reading: reading
                        default: review
                        }
                    }
                    .background(Theme.background.ignoresSafeArea())
                    .navigationTitle(step == .review ? "Check the receipt" : "Scan a receipt")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        if step == .review {
                            ToolbarItem(placement: .primaryAction) {
                                Button("Rescan") { withAnimation { step = .choose; image = nil } }
                            }
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: step)
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let picked = UIImage(data: data) { read(picked) }
                photo = nil
            }
        }
        .fullScreenCover(isPresented: $usingCamera) {
            DocumentCamera { pages in
                usingCamera = false
                if let page = DocumentCamera.stitch(pages) { read(page) }
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(.selection, trigger: ticks)
        .sensoryFeedback(.success, trigger: landed)
        .task {
            #if DEBUG
            // Simulator checks: read a receipt image without a camera.
            if let path = UserDefaults.standard.string(forKey: "scan-image"), let picked = UIImage(contentsOfFile: path) { read(picked) }
            #endif
        }
    }

    // MARK: - Choose

    private var choose: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            ScanningReceiptArt()
                .frame(width: 170, height: 210)
            VStack(spacing: 8) {
                Text("Every line, read for you").font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                Text("Take a photo of a paper receipt, or pick a photo or screenshot. It's read right on your iPhone.")
                    .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
            VStack(spacing: 12) {
                if VNDocumentCameraViewController.isSupported {
                    Button { usingCamera = true } label: {
                        Label("Take a photo", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("scan-camera")
                }
                Button { choosingPhoto = true } label: {
                    Label("Choose a photo or screenshot", systemImage: "photo.on.rectangle.angled")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityIdentifier("scan-photo")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18).padding(.bottom, 12)
        }
    }

    // MARK: - Reading

    private var reading: some View {
        VStack(spacing: 18) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                                let rect = CGRect(x: mark.rect.minX * geo.size.width - 3, y: mark.rect.minY * geo.size.height - 2,
                                                  width: mark.rect.width * geo.size.width + 6, height: mark.rect.height * geo.size.height + 4)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color(mark.kind).opacity(index < marksShown ? 0.28 : 0))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color(mark.kind).opacity(index < marksShown ? 0.9 : 0), lineWidth: 1.5))
                                    .frame(width: rect.width, height: rect.height)
                                    .scaleEffect(index < marksShown ? 1 : 1.25)
                                    .position(x: rect.midX, y: rect.midY)
                            }
                            if marks.isEmpty { ScanBeam().allowsHitTesting(false) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
                    .frame(maxHeight: 520)
                    .padding(.horizontal, 24)
            }
            HStack(spacing: 10) {
                if marks.isEmpty { ProgressView() } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                Text(marks.isEmpty ? "Reading every line…" : scan.lines.isEmpty ? "Couldn't find prices" : "Found \(scan.lines.count) \(scan.lines.count == 1 ? "thing" : "things")")
                    .font(.headline).foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    private func color(_ kind: ReceiptMark.Kind) -> Color {
        switch kind {
        case .item: return Color(red: 0.2, green: 0.62, blue: 0.36)
        case .total: return Color(red: 0.0, green: 0.48, blue: 1.0)
        case .other: return .clear
        }
    }

    // MARK: - Review

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let matched { matchCard(matched) }
                paper
                VStack(alignment: .leading, spacing: 10) {
                    Text("What was it?").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(SpendCategory.allCases) { option in
                                Button {
                                    ticks += 1
                                    withAnimation(.snappy) { category = option }
                                } label: {
                                    HStack(spacing: 6) {
                                        CategoryIcon(category: option, size: 22)
                                        Text(option.short).font(.subheadline.weight(.semibold))
                                    }
                                    .padding(.horizontal, 12).frame(height: 38)
                                    .background(category == option ? option.color.opacity(0.18) : Theme.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(category == option ? option.color : Theme.line, lineWidth: category == option ? 1.5 : 1))
                                    .foregroundStyle(Theme.ink)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(16).padding(.bottom, 140)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { saveBar }
    }

    /// "This is your Apple Pay at Menards": the receipt joins that payment instead of counting it twice.
    private func matchCard(_ payment: Payment) -> some View {
        Button {
            ticks += 1
            withAnimation(.snappy) { useMatch.toggle() }
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    CategoryIcon(category: payment.category, size: 42)
                    Image(systemName: "link.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Theme.accent)
                        .offset(x: 4, y: 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(useMatch ? "Matched to a payment you have" : "Save as a new payment")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("\(payment.merchant) · \(payment.formattedAmount) · \(payment.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))\(payment.card.isEmpty ? "" : " · \(payment.card)")")
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: useMatch ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(useMatch ? Theme.accent : Theme.line)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(useMatch ? Theme.softGreen : Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(useMatch ? Theme.accent.opacity(0.35) : Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scan-match")
        .accessibilityHint(useMatch ? "The receipt and its items are added to this payment" : "Saved as its own payment")
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 6) {
                CategoryIcon(category: category, size: 44)
                TextField("Shop name", text: $scan.merchant)
                    .font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("scan-merchant")
                HStack(spacing: 6) {
                    Text((scan.date ?? .now).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    Text("·")
                    Image(systemName: engine == .appleIntelligence ? "apple.intelligence" : "lock.fill").font(.caption2)
                    Text(engine == .appleIntelligence ? "Read with Apple Intelligence" : "Read on your iPhone")
                }
                .font(.caption).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            dashes
            if scan.lines.isEmpty {
                Text("No items found. Add them below, or just save the total.")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            ForEach(Array(scan.lines.enumerated()), id: \.element.id) { index, line in
                lineRow(line)
                    .opacity(index < printed ? 1 : 0)
                    .offset(y: index < printed ? 0 : -10)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .scale(scale: 0.8).combined(with: .opacity)))
            }
            Button {
                ticks += 1
                let line = ReceiptScan.Line(name: "", cents: 0)
                withAnimation(.snappy) { scan.lines.append(line); printed = scan.lines.count }
            } label: {
                Label("Add a line", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scan-add-line")
            dashes
            summaryRow("Items", money(scan.itemsCents))
            if scan.extrasCents > 0 { summaryRow(scan.extrasLabel, money(scan.extrasCents)) }
            HStack {
                Text("Total").font(.system(.title3, design: .rounded).weight(.heavy))
                Spacer()
                HStack(spacing: 0) {
                    Text("$")
                    TextField("0.00", text: Binding(get: { totalText }, set: { text in
                        totalText = text
                        scan.totalCents = Self.cents(text)
                    }))
                    .keyboardType(.decimalPad).fixedSize()
                    .accessibilityIdentifier("scan-total")
                }
                .font(.system(.title3, design: .rounded).weight(.heavy)).monospacedDigit()
            }
            .foregroundStyle(Theme.ink)
            if scan.itemsCents > scan.totalCents, scan.totalCents > 0 {
                Label("The items add up to more than the total. Check a price.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(Color(red: 0.6, green: 0.38, blue: 0.1))
            }
        }
        .padding(18).padding(.bottom, 10)
        .background(Color.white, in: TornEdge())
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        .animation(.snappy, value: scan.lines.count)
    }

    private func lineRow(_ line: ReceiptScan.Line) -> some View {
        HStack(spacing: 10) {
            Text(SplitService.emoji(for: line.name, category: category)).font(.title3).frame(width: 28)
            TextField("Item", text: Binding(get: { line.name }, set: { name in
                if let i = scan.lines.firstIndex(where: { $0.id == line.id }) { scan.lines[i].name = name }
            }))
            .font(.body.weight(.medium)).foregroundStyle(Theme.ink)
            if line.quantity > 1 {
                Text("×\(line.quantity)").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 0) {
                Text("$")
                TextField("0.00", text: Binding(get: { priceTexts[line.id] ?? "" }, set: { text in
                    priceTexts[line.id] = text
                    if let i = scan.lines.firstIndex(where: { $0.id == line.id }) { scan.lines[i].cents = Self.cents(text) }
                }))
                .keyboardType(.decimalPad).fixedSize()
            }
            .font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.ink)
            Button {
                ticks += 1
                withAnimation(.snappy) { scan.lines.removeAll { $0.id == line.id }; printed = scan.lines.count }
            } label: {
                Image(systemName: "minus.circle.fill").font(.body).foregroundStyle(Theme.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(line.name)")
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().contentTransition(.numericText())
        }
        .font(.subheadline).foregroundStyle(Theme.secondary)
    }

    private var dashes: some View {
        Rectangle().fill(.clear).frame(height: 1)
            .overlay(Line().stroke(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    private var amountCents: Int { scan.totalCents > 0 ? scan.totalCents : scan.itemsCents }

    private var saveBar: some View {
        HStack(spacing: 12) {
            Button { save(split: false) } label: {
                Label(useMatch && matched != nil ? "Add to payment" : "Save \(money(amountCents))", systemImage: useMatch && matched != nil ? "link" : "checkmark")
                    .font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .accessibilityIdentifier("scan-save")
            Button { save(split: true) } label: {
                Label("Split it", systemImage: "person.2.fill")
                    .font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("scan-split")
        }
        .buttonStyle(.plain)
        .disabled(amountCents == 0)
        .opacity(amountCents == 0 ? 0.5 : 1)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func read(_ picked: UIImage) {
        image = picked
        marks = []
        marksShown = 0
        printed = 0
        step = .reading
        Task {
            let started = Date.now
            let (found, foundMarks, foundEngine) = await ReceiptReader.scan(picked)
            // Let the beam sweep at least once, so the reading is seen.
            let left = 1.4 - Date.now.timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            scan = found
            engine = foundEngine
            category = SpendCategory.guess(merchant: found.merchant, items: found.lines.map(\.name))
            priceTexts = Dictionary(uniqueKeysWithValues: found.lines.map { ($0.id, Self.text($0.cents)) })
            totalText = found.totalCents > 0 ? Self.text(found.totalCents) : ""
            matched = store.match(cents: found.totalCents > 0 ? found.totalCents : found.itemsCents, date: found.date)
            useMatch = matched != nil
            let shown = foundMarks.filter { $0.kind != .other }
            withAnimation(.easeOut(duration: 0.2)) { marks = shown }
            for index in shown.indices {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 70))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { marksShown = index + 1 }
                if shown[index].kind == .item { ticks += 1 }
            }
            try? await Task.sleep(for: .milliseconds(650))
            step = .review
            // The receipt prints back, one line at a time.
            for index in scan.lines.indices {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 110))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { printed = index + 1 }
                ticks += 1
            }
            landed += 1
        }
    }

    private func save(split: Bool) {
        let lines = scan.lines.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty || $0.cents > 0 }
        let items = lines.map { LineItem(name: $0.name.isEmpty ? "Item" : $0.name, quantity: $0.quantity, price: Double($0.cents) / 100) }
        let merchant = scan.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if useMatch, var existing = matched.flatMap({ store.transaction($0.id) }) {
            // The receipt joins the payment already here, so nothing is counted twice.
            if !merchant.isEmpty, ["Apple Pay", "Payment"].contains(existing.merchant) { existing.merchant = merchant }
            existing.items = items
            if existing.category == .other { existing.category = category }
            store.update(existing)
            if let image { store.attachReceipt(image, to: existing.id) }
            landed += 1
            if split { step = .split(existing.id) } else { dismiss() }
            return
        }
        let saved = store.add(merchant: merchant.isEmpty ? (items.count == 1 ? items[0].name : "Receipt") : merchant,
                              amount: Double(amountCents) / 100, date: scan.date ?? .now, category: category,
                              source: .receipt, items: items)
        if let image { store.attachReceipt(image, to: saved.id) }
        landed += 1
        if split { step = .split(saved.id) } else { dismiss() }
    }

    static func cents(_ text: String) -> Int {
        let clean = text.replacingOccurrences(of: ",", with: "").filter { "0123456789.".contains($0) }
        return Int(((Double(clean) ?? 0) * 100).rounded())
    }

    static func text(_ cents: Int) -> String { String(format: "%d.%02d", cents / 100, cents % 100) }
}

// MARK: - Pieces

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

/// A bright line sweeping down the photo while it's read.
private struct ScanBeam: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            GeometryReader { geo in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2.2) + 1) / 2
                let y = geo.size.height * phase
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 90).offset(y: y - 90)
                    Rectangle().fill(Color(red: 0.55, green: 0.95, blue: 0.7))
                        .frame(height: 3).shadow(color: Color(red: 0.4, green: 0.95, blue: 0.6), radius: 8)
                        .offset(y: y)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
    }
}

/// A little receipt with a beam going over it, on the start screen.
private struct ScanningReceiptArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 1.6) + 1) / 2
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 11) {
                    Capsule().fill(Theme.ink.opacity(0.75)).frame(width: 70, height: 9).frame(maxWidth: .infinity)
                    ForEach(0..<5) { i in
                        let lit = abs(phase - (Double(i) + 1.5) / 7) < 0.09
                        HStack {
                            Capsule().fill(lit ? Color(red: 0.2, green: 0.62, blue: 0.36) : Theme.line).frame(width: [62, 48, 70, 40, 56][i], height: 7)
                            Spacer()
                            Capsule().fill(lit ? Color(red: 0.2, green: 0.62, blue: 0.36) : Theme.line).frame(width: 26, height: 7)
                        }
                        .animation(.easeOut(duration: 0.15), value: lit)
                    }
                    Rectangle().fill(.clear).frame(height: 1)
                        .overlay(Line().stroke(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    HStack {
                        Capsule().fill(Theme.ink.opacity(0.7)).frame(width: 44, height: 9)
                        Spacer()
                        Capsule().fill(Theme.ink.opacity(0.7)).frame(width: 34, height: 9)
                    }
                }
                .padding(18).padding(.bottom, 8)
                .frame(width: 150, height: 196)
                .background(Color.white, in: TornEdge())
                .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
                .rotationEffect(.degrees(-4))
                Rectangle().fill(Color(red: 0.55, green: 0.95, blue: 0.7))
                    .frame(width: 176, height: 3)
                    .shadow(color: Color(red: 0.4, green: 0.95, blue: 0.6), radius: 10)
                    .offset(y: 10 + 186 * phase)
            }
            .frame(width: 176, height: 210)
        }
        .accessibilityHidden(true)
    }
}

/// The system's document scanner: finds the receipt's edges, flattens it, and hands back every page.
struct DocumentCamera: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(done: @escaping ([UIImage]) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done([]) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done([]) }
    }

    /// A long receipt shot in parts, joined top to bottom into one picture.
    static func stitch(_ pages: [UIImage]) -> UIImage? {
        guard pages.count > 1 else { return pages.first }
        let width = pages.map(\.size.width).max() ?? 0
        let height = pages.reduce(0) { $0 + $1.size.height * width / $1.size.width }
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
            var y: CGFloat = 0
            for page in pages {
                let h = page.size.height * width / page.size.width
                page.draw(in: CGRect(x: 0, y: y, width: width, height: h))
                y += h
            }
        }
    }
}
