import SwiftUI
import QuickLook

/// Pick dates and what to count, see the report take shape, and save it as a PDF or spreadsheet to send anywhere.
struct ReportSheet: View {
    @ObservedObject var store: WalletStore
    /// The month on screen when the report was opened.
    var month: Date = .now
    @ObservedObject private var splits = SplitService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var range: ReportRange = .thisMonth
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var categories = Set(SpendCategory.allCases)
    @State private var yourShare = false
    @State private var withPhotos = true
    @State private var format: ReportFormat = .pdf
    @State private var making = false
    @State private var made: URL?
    @State private var previewing: URL?
    @State private var failed = false
    @State private var ticks = 0

    private var report: ExpenseReport {
        ExpenseReport(payments: splits.netted(store.transactions), start: start, end: end, categories: categories,
                      yourShare: yourShare, withPhotos: withPhotos)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    rangePicker
                    preview(report)
                    options
                    formats
                }
                .padding(18).padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { exportBar(report) }
        }
        .tint(Theme.accent)
        .sheet(item: $made) { url in ShareSheet(items: [url]).presentationDetents([.medium, .large]) }
        .quickLookPreview($previewing)
        .alert("Couldn't make the report", isPresented: $failed) { Button("OK") {} }
        .sensoryFeedback(.selection, trigger: ticks)
        .onAppear(perform: openOnMonth)
        .onChange(of: range) { _, new in if let days = new.days() { withAnimation(.snappy) { start = days.start; end = days.end } } }
    }

    private func openOnMonth() {
        let calendar = Calendar.current
        if calendar.isDate(month, equalTo: .now, toGranularity: .month) {
            if let days = ReportRange.thisMonth.days() { start = days.start; end = days.end }
        } else if let shown = calendar.dateInterval(of: .month, for: month) {
            let last = ReportRange.lastMonth.days()
            range = last.map { calendar.isDate($0.start, inSameDayAs: shown.start) } == true ? .lastMonth : .custom
            start = shown.start
            end = shown.end.addingTimeInterval(-1)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-report-year") { range = .thisYear }
        #endif
    }

    // MARK: - Dates

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ReportRange.allCases) { option in
                        Button {
                            ticks += 1
                            withAnimation(.snappy) { range = option }
                        } label: {
                            Text(option.title).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(height: 38)
                                .background(range == option ? Theme.accent : Theme.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(range == option ? .clear : Theme.line))
                                .foregroundStyle(range == option ? .white : Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(range == option ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            if range == .custom {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $start, in: ...end, displayedComponents: .date).labelsHidden()
                    Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                    DatePicker("To", selection: $end, in: start..., displayedComponents: .date).labelsHidden()
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Preview

    /// The report's first page, small: what will be sent, updating as the choices change.
    private func preview(_ report: ExpenseReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Expense report").font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(Theme.ink)
                    Text(report.rangeText).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Spacer()
                receiptFan(report.withReceipts)
            }
            Text(dollars(report.total))
                .font(.system(size: 44, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.ink).contentTransition(.numericText())
                .minimumScaleFactor(0.6).lineLimit(1)
            HStack(spacing: 8) {
                chip("\(report.payments.count)", report.payments.count == 1 ? "payment" : "payments")
                chip("\(report.withReceipts.count)", report.withReceipts.count == 1 ? "receipt" : "receipts")
                if report.paidBack > 0 { chip(shortDollars(report.paidBack), "paid back") }
            }
            if report.payments.isEmpty {
                Text("No payments in these dates.").font(.subheadline).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            } else {
                VStack(spacing: 10) {
                    let top = max(report.groups.first?.total ?? 1, 0.01)
                    ForEach(report.groups) { group in
                        HStack(spacing: 10) {
                            CategoryIcon(category: group.category, size: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(group.category.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Text("\(group.count)").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                                    Spacer()
                                    Text(dollars(group.total)).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Theme.line.opacity(0.5)).overlay(alignment: .leading) {
                                        Capsule().fill(group.category.barColor.gradient).frame(width: max(6, geo.size.width * group.total / top))
                                    }
                                }
                                .frame(height: 6)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
        }
        .padding(18).padding(.bottom, 8)
        .background(Color.white, in: TornEdge())
        .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
        .animation(reduceMotion ? nil : .snappy, value: report.total)
        .animation(reduceMotion ? nil : .snappy, value: report.groups.map(\.category))
    }

    private func chip(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).fontWeight(.bold).monospacedDigit().contentTransition(.numericText())
            Text(label)
        }
        .font(.caption).foregroundStyle(Theme.ink)
        .padding(.horizontal, 10).frame(height: 26)
        .background(Theme.background, in: Capsule())
    }

    /// Up to four receipt photos, fanned like paper on a desk.
    private func receiptFan(_ kept: [Payment]) -> some View {
        ZStack {
            ForEach(Array(kept.prefix(4).enumerated().reversed()), id: \.element.id) { index, p in
                ReceiptThumb(id: p.id, width: 38)
                    .rotationEffect(.degrees(Double(index) * 9 - 6))
                    .offset(x: CGFloat(index) * -14, y: CGFloat(index) * 2)
            }
        }
        .frame(width: 90, height: 56, alignment: .trailing)
        .accessibilityHidden(true)
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to include").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(SpendCategory.allCases) { option in
                        let on = categories.contains(option)
                        Button {
                            ticks += 1
                            withAnimation(.snappy) {
                                if on { if categories.count > 1 { categories.remove(option) } } else { categories.insert(option) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                CategoryIcon(category: option, size: 20)
                                Text(option.short).font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(on ? option.color.opacity(0.16) : Theme.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? option.color : Theme.line, lineWidth: on ? 1.5 : 1))
                            .foregroundStyle(on ? Theme.ink : Theme.secondary)
                            .opacity(on ? 1 : 0.7)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            VStack(spacing: 0) {
                Toggle(isOn: $yourShare.animation(.snappy)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only your share").font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text("Take off what friends paid back").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.vertical, 12)
                Divider()
                Toggle(isOn: $withPhotos) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Receipt photos in the PDF").font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text("Two to a page, after the table").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var formats: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                ForEach(ReportFormat.allCases) { option in
                    Button {
                        ticks += 1
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { format = option }
                    } label: {
                        VStack(spacing: 8) {
                            FileBadge(format: option).scaleEffect(format == option ? 1.06 : 1)
                            Text(option.title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(format == option ? Theme.softGreen : Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(format == option ? Theme.accent : Theme.line, lineWidth: format == option ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityHint(option.detail)
                    .accessibilityAddTraits(format == option ? .isSelected : [])
                    .accessibilityIdentifier("report-format-\(option.rawValue)")
                }
            }
            Text(format.detail).font(.caption).foregroundStyle(Theme.secondary)
                .contentTransition(.opacity)
        }
    }

    // MARK: - Export

    private func exportBar(_ report: ExpenseReport) -> some View {
        HStack(spacing: 10) {
            if format == .pdf {
                Button { make(report, preview: true) } label: {
                    Image(systemName: "eye").font(.headline).foregroundStyle(Theme.ink)
                        .frame(width: 56, height: 56)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                }
                .accessibilityLabel("Preview the PDF")
                .accessibilityIdentifier("report-preview")
                .transition(.scale.combined(with: .opacity))
            }
            Button { make(report, preview: false) } label: {
                HStack(spacing: 8) {
                    if making { ProgressView().tint(.white) } else { Image(systemName: "square.and.arrow.up") }
                    Text(making ? "Making your report…" : "Export \(format.title)")
                }
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .accessibilityIdentifier("report-export")
        }
        .buttonStyle(.plain)
        .disabled(report.payments.isEmpty || making)
        .opacity(report.payments.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .animation(.snappy, value: format)
    }

    private func make(_ report: ExpenseReport, preview: Bool) {
        making = true
        Task {
            // Let the button show it's working before the pages are drawn.
            try? await Task.sleep(for: .milliseconds(60))
            do {
                let url = try report.file(preview ? .pdf : format)
                if preview { previewing = url } else { made = url }
                ticks += 1
            } catch {
                failed = true
            }
            making = false
        }
    }
}

/// A small file icon in the app's own style: a folded page with the format's mark.
struct FileBadge: View {
    let format: ReportFormat

    private var color: Color {
        switch format {
        case .pdf: return Color(hex: "#D9574A")
        case .csv: return Theme.accent
        case .itemsCSV: return Color(hex: "#4F7FB8")
        }
    }

    private var symbol: String {
        switch format {
        case .pdf: return "doc.richtext.fill"
        case .csv: return "tablecells.fill"
        case .itemsCSV: return "list.bullet.rectangle.fill"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
                .frame(width: 46, height: 54)
                .overlay(alignment: .topTrailing) {
                    Triangle().fill(.white.opacity(0.45)).frame(width: 14, height: 14)
                }
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
        }
        .shadow(color: color.opacity(0.3), radius: 6, y: 3)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}

/// The system share sheet: Mail, Messages, Save to Files, Print and more.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
