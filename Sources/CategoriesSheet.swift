import SwiftUI
import UIKit

/// Your categories: add your own, change any name, emoji, icon or colour, drag to reorder, remove what you don't use.
struct CategoriesSheet: View {
    @ObservedObject var store: WalletStore
    @ObservedObject private var library = CategoryLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editing: CategoryInfo?
    @State private var adding = false
    @State private var removing: CategoryInfo?
    @State private var ticks = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { adding = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add a category").font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text("Pick an emoji or an icon").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("category-add")
                }
                .listRowBackground(Theme.card)

                Section {
                    ForEach(library.visible) { info in
                        Button { editing = info } label: { row(info) }
                            .deleteDisabled(info.id == SpendCategory.other.rawValue)
                    }
                    .onMove { from, to in
                        ticks += 1
                        withAnimation(.snappy) { library.move(from: from, to: to) }
                    }
                    .onDelete { offsets in
                        if let index = offsets.first { removing = library.visible[index] }
                    }
                } header: {
                    Text("Your categories")
                } footer: {
                    Text("Drag to reorder. They show in this order on your chart.")
                }
                .listRowBackground(Theme.card)

                if !library.removed.isEmpty {
                    Section("Removed") {
                        ForEach(library.removed) { info in
                            HStack(spacing: 14) {
                                CategoryArt(icon: info.icon, hex: info.hex, size: 34).opacity(0.5)
                                Text(info.name).foregroundStyle(Theme.secondary)
                                Spacer()
                                Button("Add back") {
                                    ticks += 1
                                    withAnimation(.snappy) { library.restore(info.category) }
                                }
                                .font(.subheadline.weight(.semibold))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                }

                Section {
                    Button("Reset the built-in categories") {
                        withAnimation(.snappy) { library.resetBuiltIns() }
                    }
                    .font(.subheadline)
                } footer: {
                    Text("Brings back the eight categories the app comes with, with their names and drawings. Your own categories stay.")
                }
                .listRowBackground(Theme.card)
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { info in
                Button("Remove", role: .destructive) {
                    withAnimation(.snappy) { library.remove(info.category, in: store) }
                }
            } message: { info in
                let count = store.count(in: info.category)
                Text(count == 0 ? "No payments use it." : "\(count) \(count == 1 ? "payment moves" : "payments move") to Other.")
            }
            .sheet(item: $editing) { info in CategoryEditor(store: store, original: info) }
            .sheet(isPresented: $adding) { CategoryEditor(store: store, original: nil) }
        }
        .tint(Theme.accent)
        .sensoryFeedback(.selection, trigger: ticks)
    }

    private func row(_ info: CategoryInfo) -> some View {
        let count = store.count(in: info.category)
        return HStack(spacing: 14) {
            CategoryArt(icon: info.icon, hex: info.hex, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(count == 0 ? "No payments yet" : "\(count) \(count == 1 ? "payment" : "payments")")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Circle().fill(Color(hex: info.barHex ?? info.hex)).frame(width: 10, height: 10)
        }
        .contentShape(Rectangle())
    }
}

/// Name, picture and colour for one category: an emoji from the iPhone keyboard, or an icon from the library.
struct CategoryEditor: View {
    @ObservedObject var store: WalletStore
    let original: CategoryInfo?
    @ObservedObject private var library = CategoryLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Tab: String, CaseIterable, Identifiable {
        case emoji = "Emoji", icons = "Icons"
        var id: Self { self }
    }

    @State private var name = ""
    @State private var icon: CategoryInfo.Icon = .emoji("🐶")
    @State private var hex = SplitPerson.hexes[2]
    @State private var keywords = ""
    @State private var tab: Tab = .emoji
    @State private var typed = ""
    @State private var removing = false
    @State private var bounce = 0
    @FocusState private var naming: Bool

    private var isNew: Bool { original == nil }
    private var builtInArt: CategoryInfo.Icon? { CategoryInfo.builtIn.first { $0.id == original?.id }?.icon }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    preview
                    if let art = builtInArt { artChoice(art) }
                    Picker("Picture", selection: $tab.animation(.snappy)) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if tab == .emoji { emojiPicker } else { iconPicker }
                    colors
                    if !(original?.isBuiltIn ?? false) { keywordField }
                    if let original, original.id != SpendCategory.other.rawValue {
                        Button(role: .destructive) { removing = true } label: {
                            Label("Remove category", systemImage: "trash").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(red: 0.75, green: 0.27, blue: 0.22))
                                .frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(isNew ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }.fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("category-save")
                }
            }
            .confirmationDialog("Remove \(original?.name ?? "")?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let original { library.remove(original.category, in: store) }
                    dismiss()
                }
            } message: {
                let count = original.map { store.count(in: $0.category) } ?? 0
                Text(count == 0 ? "No payments use it." : "\(count) \(count == 1 ? "payment moves" : "payments move") to Other.")
            }
        }
        .tint(Theme.accent)
        .sensoryFeedback(.selection, trigger: bounce)
        .onAppear {
            if let original {
                name = original.name
                icon = original.icon
                hex = original.hex
                keywords = original.keywords.joined(separator: ", ")
                if case .symbol = original.icon { tab = .icons }
            } else {
                naming = true
            }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 14) {
            CategoryArt(icon: icon, hex: hex, size: 92)
                .id(icon)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: icon)
                .padding(.top, 6)
            TextField("Name", text: $name)
                .font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .submitLabel(.done)
                .focused($naming)
                .accessibilityIdentifier("category-name")
            // How it will look on the chart.
            HStack(alignment: .bottom, spacing: 6) {
                ForEach([0.45, 0.8, 0.6], id: \.self) { height in
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: hex).gradient)
                        .frame(width: 18, height: 34 * height)
                }
            }
            .frame(height: 34)
            .animation(.snappy, value: hex)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// The eight built-in categories can go back to the app's own drawing.
    private func artChoice(_ art: CategoryInfo.Icon) -> some View {
        Button { pick(art) } label: {
            HStack(spacing: 12) {
                CategoryArt(icon: art, hex: hex, size: 36)
                Text("Use the original drawing").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if icon == art { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            .padding(12)
            .background(icon == art ? Theme.softGreen : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Emoji

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "face.smiling").font(.title3).foregroundStyle(Theme.accent)
                EmojiField(text: $typed, placeholder: "Type any emoji")
                    .frame(height: 30)
                    .accessibilityIdentifier("category-emoji-field")
            }
            .padding(.horizontal, 14).frame(height: 52)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
            .onChange(of: typed) { _, text in
                if let emoji = text.last(where: \.isEmoji) { pick(.emoji(String(emoji))) }
                if !text.isEmpty { typed = "" }
            }
            ForEach(EmojiLibrary.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                        ForEach(group.items, id: \.self) { emoji in
                            let on = icon == .emoji(emoji)
                            Button { pick(.emoji(emoji)) } label: {
                                Text(emoji).font(.system(size: 26))
                                    .frame(maxWidth: .infinity).frame(height: 42)
                                    .background(on ? Theme.softGreen : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Icons

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(IconLibrary.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(group.items, id: \.self) { symbol in
                            let on = icon == .symbol(symbol)
                            Button { pick(.symbol(symbol)) } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(on ? .white : Color(hex: hex))
                                    .frame(maxWidth: .infinity).frame(height: 48)
                                    .background(on ? AnyShapeStyle(Color(hex: hex).gradient) : AnyShapeStyle(Color(hex: hex).opacity(0.12)),
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Colour and words

    private var colors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 10) {
                ForEach(SplitPerson.hexes, id: \.self) { option in
                    Button {
                        bounce += 1
                        withAnimation(.snappy) { hex = option }
                    } label: {
                        Circle().fill(Color(hex: option).gradient).frame(height: 36)
                            .overlay(Circle().strokeBorder(.white, lineWidth: hex == option ? 3 : 0))
                            .overlay(Circle().strokeBorder(Color(hex: option), lineWidth: hex == option ? 2 : 0).padding(-3))
                            .scaleEffect(hex == option ? 1.08 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(option)")
                    .accessibilityAddTraits(hex == option ? .isSelected : [])
                }
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var keywordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shops that go here").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.ink)
            TextField("Petco, Chewy, vet", text: $keywords)
                .padding(.horizontal, 14).frame(height: 48)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("New payments from these shops are filed here for you.").font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private func pick(_ choice: CategoryInfo.Icon) {
        bounce += 1
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { icon = choice }
    }

    private func save() {
        let words = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if var info = original {
            info.name = name
            info.icon = icon
            if info.hex != hex { info.hex = hex; info.barHex = nil }
            if !info.isBuiltIn { info.keywords = words }
            library.update(info)
        } else {
            let made = library.add(name: name, icon: icon, hex: hex)
            if !words.isEmpty, var info = library.all.first(where: { $0.id == made.rawValue }) {
                info.keywords = words
                library.update(info)
            }
        }
        dismiss()
    }
}

// MARK: - Libraries

enum EmojiLibrary {
    static let groups: [(title: String, items: [String])] = [
        ("Food & drink", ["🍕", "🍣", "🍜", "🥗", "🍩", "☕️", "🧋", "🍺", "🍷", "🥐", "🍔", "🌮", "🍦", "🥑", "🍎", "🛒"]),
        ("Home & family", ["🏠", "🛋️", "🧺", "🧹", "🪴", "👶", "🍼", "🧸", "🐶", "🐱", "🐠", "🔑", "🛠️", "💡", "🔌", "🧾"]),
        ("Getting around", ["✈️", "🚗", "🚕", "🚌", "🚲", "⛽️", "🅿️", "🚆", "🛳️", "🏨", "🗺️", "🧳", "🏖️", "⛰️", "🎟️", "🛵"]),
        ("Health & self", ["💊", "🩺", "🦷", "💪", "🧘", "💇", "💅", "🧴", "👓", "🏃", "🧠", "❤️", "🛁", "😴", "🌿", "🩹"]),
        ("Fun & things", ["🎬", "🎮", "🎵", "📚", "🎨", "⚽️", "🎳", "🎁", "🎉", "👗", "👟", "💄", "📱", "💻", "📷", "🎧"]),
        ("Money & work", ["💼", "💰", "💳", "🏦", "📈", "🧮", "🎓", "✏️", "📦", "🙏", "🤝", "⛪️", "🎗️", "🏛️", "📮", "⭐️"]),
    ]
}

enum IconLibrary {
    static let groups: [(title: String, items: [String])] = [
        ("Food", ["fork.knife", "cup.and.saucer.fill", "wineglass.fill", "birthday.cake.fill", "carrot.fill", "cart.fill"]),
        ("Home", ["house.fill", "sofa.fill", "bed.double.fill", "washer.fill", "lightbulb.fill", "wrench.and.screwdriver.fill",
                  "leaf.fill", "drop.fill", "flame.fill", "bolt.fill", "wifi", "key.fill"]),
        ("Family & pets", ["figure.2.and.child.holdinghands", "stroller.fill", "teddybear.fill", "pawprint.fill", "dog.fill", "cat.fill"]),
        ("Travel", ["airplane", "car.fill", "tram.fill", "bus.fill", "bicycle", "fuelpump.fill",
                    "parkingsign", "suitcase.fill", "bed.double.circle.fill", "map.fill", "beach.umbrella.fill", "mountain.2.fill"]),
        ("Health", ["heart.fill", "cross.case.fill", "pills.fill", "stethoscope", "dumbbell.fill", "figure.run",
                    "scissors", "sparkles", "eyeglasses", "brain.head.profile", "bandage.fill", "moon.zzz.fill"]),
        ("Fun", ["film.fill", "gamecontroller.fill", "music.note", "book.fill", "paintpalette.fill", "sportscourt.fill",
                 "gift.fill", "party.popper.fill", "tshirt.fill", "bag.fill", "headphones", "camera.fill"]),
        ("Money & work", ["briefcase.fill", "dollarsign.circle.fill", "creditcard.fill", "building.columns.fill", "chart.line.uptrend.xyaxis",
                          "graduationcap.fill", "pencil", "shippingbox.fill", "hands.sparkles.fill", "star.fill", "tag.fill", "doc.text.fill"]),
    ]
}

extension Character {
    /// Whether this looks like an emoji, not a digit or letter that only can be shown as one.
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}

/// A text field that opens straight to the iPhone's emoji keyboard.
struct EmojiField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    final class Field: UITextField {
        override var textInputContextIdentifier: String? { "" }
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.tintColor = UIColor(Theme.accent)
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { field.resignFirstResponder(); return true }
    }
}
