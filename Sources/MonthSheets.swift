import SwiftUI

/// Jump to any month: recent ones with what you spent, or any month of any year on a calendar grid.
struct MonthPicker: View {
    let payments: [Payment]
    @Binding var month: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var ticks = 0

    private var calendar: Calendar { .current }
    private var thisMonth: Date { calendar.dateInterval(of: .month, for: .now)!.start }
    private var firstYear: Int {
        min(calendar.component(.year, from: payments.map(\.date).min() ?? .now), calendar.component(.year, from: .now))
    }
    private var lastYear: Int { calendar.component(.year, from: .now) }

    /// What you spent each month, by the month's first day.
    private var spent: [Date: Double] {
        payments.reduce(into: [:]) { totals, p in
            totals[calendar.dateInterval(of: .month, for: p.date)!.start, default: 0] += p.spent
        }
    }

    /// The last six months, newest first.
    private var recent: [Date] {
        (0..<6).compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonth) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    recentStrip
                    yearGrid
                }
                .padding(18)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Pick a month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !calendar.isDate(month, equalTo: .now, toGranularity: .month) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("This month") { choose(thisMonth) }.fontWeight(.semibold)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .sensoryFeedback(.selection, trigger: ticks)
        .onAppear { year = calendar.component(.year, from: month) }
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(recent, id: \.self) { start in
                        let on = calendar.isDate(start, equalTo: month, toGranularity: .month)
                        Button { choose(start) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(start == thisMonth ? "This month" : start.formatted(.dateTime.month(.wide)))
                                    .font(.subheadline.weight(.bold))
                                Text(dollars(spent[start] ?? 0)).font(.caption.weight(.semibold)).monospacedDigit()
                                    .opacity(0.8)
                            }
                            .foregroundStyle(on ? .white : Theme.ink)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(minWidth: 104, alignment: .leading)
                            .background(on ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? .clear : Theme.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var yearGrid: some View {
        let months = (1...12).compactMap { calendar.date(from: DateComponents(year: year, month: $0, day: 1)) }
        let top = max(months.map { spent[$0] ?? 0 }.max() ?? 0, 1)
        return VStack(spacing: 14) {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 40) }
                    .disabled(year <= firstYear)
                    .accessibilityLabel("Previous year")
                Spacer()
                VStack(spacing: 2) {
                    Text(String(year)).font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(Theme.ink)
                        .contentTransition(.numericText(value: Double(year)))
                    Text("\(dollars(months.reduce(0) { $0 + (spent[$1] ?? 0) })) spent")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).contentTransition(.numericText())
                }
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 40) }
                    .disabled(year >= lastYear)
                    .accessibilityLabel("Next year")
            }
            .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(months, id: \.self) { start in
                    let value = spent[start] ?? 0
                    let on = calendar.isDate(start, equalTo: month, toGranularity: .month)
                    let future = start > thisMonth
                    Button { choose(start) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(start.formatted(.dateTime.month(.abbreviated))).font(.subheadline.weight(.bold))
                                Spacer()
                                if start == thisMonth { Circle().fill(on ? .white : Theme.accent).frame(width: 6, height: 6) }
                            }
                            Text(value > 0 ? shortDollars(value) : "—").font(.caption.weight(.semibold)).monospacedDigit().opacity(0.8)
                            GeometryReader { geo in
                                Capsule().fill(on ? .white.opacity(0.3) : Theme.line.opacity(0.6))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(on ? .white : Theme.accent)
                                            .frame(width: value > 0 ? max(4, geo.size.width * value / top) : 0)
                                    }
                            }
                            .frame(height: 4)
                        }
                        .foregroundStyle(on ? .white : Theme.ink)
                        .padding(12)
                        .background(on ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .opacity(future ? 0.35 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(future)
                    .accessibilityLabel("\(start.formatted(.dateTime.month(.wide).year())), \(dollars(value))")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .id(year)
            .transition(.opacity)
        }
        .padding(14)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func step(_ by: Int) {
        ticks += 1
        withAnimation(reduceMotion ? nil : .snappy) { year += by }
    }

    private func choose(_ start: Date) {
        ticks += 1
        month = start
        dismiss()
    }
}

/// One category for one month: what it cost, how that compares, and every payment in it.
struct CategoryMonthSheet: View {
    @ObservedObject var store: WalletStore
    @State var category: SpendCategory
    let month: Date
    @ObservedObject private var splits = SplitService.shared
    @ObservedObject private var library = CategoryLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var opened: Payment?
    @State private var editing: CategoryInfo?

    private var calendar: Calendar { .current }
    private var all: [Payment] { splits.netted(store.transactions) }
    private func payments(_ category: SpendCategory, in month: Date) -> [Payment] {
        all.filter { $0.category == category && calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
    }
    private var shown: [Payment] { payments(category, in: month).sorted { $0.date > $1.date } }
    private var total: Double { shown.reduce(0) { $0 + $1.spent } }
    private var monthTotal: Double {
        all.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }.reduce(0) { $0 + $1.spent }
    }
    private var lastMonth: Double {
        let before = calendar.date(byAdding: .month, value: -1, to: month)!
        return payments(category, in: before).reduce(0) { $0 + $1.spent }
    }

    private var days: [(day: Date, payments: [Payment])] {
        Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switcher
                    header
                    if shown.isEmpty { empty } else { list }
                }
                .padding(18)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = category.info }.accessibilityLabel("Edit \(category.title)")
                }
            }
            .sheet(item: $opened) { tx in PaymentDetailSheet(store: store, transactionID: tx.id) }
            .sheet(item: $editing) { info in CategoryEditor(store: store, original: info) }
            .animation(.snappy, value: category)
        }
        .tint(Theme.accent)
        .sensoryFeedback(.selection, trigger: category)
    }

    /// Every category, to hop between them without going back.
    private var switcher: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(library.visible.map(\.category)) { option in
                        let on = option == category
                        let value = payments(option, in: month).reduce(0) { $0 + $1.spent }
                        Button { category = option } label: {
                            HStack(spacing: 6) {
                                CategoryIcon(category: option, size: 22)
                                Text(option.short).font(.subheadline.weight(.semibold))
                                if value > 0 && !on {
                                    Text(shortDollars(value)).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                                }
                            }
                            .padding(.horizontal, 12).frame(height: 38)
                            .background(on ? option.color.opacity(0.18) : Theme.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? option.color : Theme.line, lineWidth: on ? 1.5 : 1))
                            .foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .id(option)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(category, anchor: .center) }
            .onChange(of: category) { _, new in withAnimation(.snappy) { proxy.scrollTo(new, anchor: .center) } }
        }
    }

    private var header: some View {
        let share = monthTotal > 0 ? total / monthTotal : 0
        let change = total - lastMonth
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                CategoryIcon(category: category, size: 64)
                    .id(category)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                    Text(dollars(total)).font(.system(size: 36, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.ink).contentTransition(.numericText())
                }
            }
            GeometryReader { geo in
                Capsule().fill(Theme.line.opacity(0.5)).overlay(alignment: .leading) {
                    Capsule().fill(category.barColor.gradient).frame(width: max(share > 0 ? 8 : 0, geo.size.width * share))
                }
            }
            .frame(height: 8)
            HStack(spacing: 8) {
                fact("\(shown.count)", shown.count == 1 ? "payment" : "payments")
                fact("\(Int((share * 100).rounded()))%", "of the month")
                if lastMonth > 0 || total > 0 {
                    fact((change >= 0 ? "+" : "−") + shortDollars(abs(change)), "vs last month",
                         tint: change > 0 ? Color(hex: "#B5654A") : Theme.accent)
                }
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(.snappy, value: total)
    }

    private func fact(_ value: String, _ label: String, tint: Color = Theme.ink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            CategoryIcon(category: category, size: 56).opacity(0.5)
            Text("No \(category.title.lowercased()) in \(month.formatted(.dateTime.month(.wide)))")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity).padding(30)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(days, id: \.day) { group in
                HStack {
                    Text(dayTitle(group.day)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(dollars(group.payments.reduce(0) { $0 + $1.spent })).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 14).padding(.bottom, 4)
                ForEach(group.payments) { tx in
                    PaymentRow(tx: tx, split: splits.mark(for: tx.splitIDs))
                        .contentShape(Rectangle())
                        .onTapGesture { opened = tx }
                    if tx.id != group.payments.last?.id { Divider().padding(.leading, 62) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .id(category)
        .transition(.opacity)
    }

    private func dayTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
