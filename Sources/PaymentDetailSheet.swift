import SwiftUI
import PhotosUI
import VisionKit

/// One payment: what, where, when and how, with what was bought. Split it or change it from here.
struct PaymentDetailSheet: View {
    @ObservedObject var store: WalletStore
    let transactionID: UUID
    @ObservedObject private var splits = SplitService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var splitting = false
    @State private var confirmingDelete = false
    @State private var viewingReceipt = false
    @State private var choosingPhoto = false
    @State private var usingCamera = false
    @State private var photo: PhotosPickerItem?
    @State private var attaching = false

    private var tx: Payment? { store.transaction(transactionID) }

    var body: some View {
        NavigationStack {
            if let tx {
                ScrollView {
                    VStack(spacing: 18) {
                        summary(tx)
                        if tx.cents == 0 {
                            Button { editing = true } label: {
                                Label("Apple Pay didn't share the amount — add it", systemImage: "pencil")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).frame(height: 46)
                                    .background(Color(hex: "#D9734A"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        facts(tx)
                        receiptCard(tx)
                        if !tx.items.isEmpty { itemsCard(tx) }
                        splitButton(tx)
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete payment", systemImage: "trash").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(red: 0.75, green: 0.27, blue: 0.22))
                                .frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                }
                .background(Theme.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editing = true }.fontWeight(.semibold).accessibilityIdentifier("payment-edit")
                    }
                }
                .sheet(isPresented: $editing) { AddPaymentSheet(store: store, editing: tx) }
                .sheet(isPresented: $splitting) { SplitSheet(store: store, transactionID: tx.id) }
                .fullScreenCover(isPresented: $viewingReceipt) { ReceiptViewer(id: tx.id, title: tx.merchant) }
                .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self), let picked = UIImage(data: data) { await attach(picked) }
                        photo = nil
                    }
                }
                .fullScreenCover(isPresented: $usingCamera) {
                    DocumentCamera { pages in
                        usingCamera = false
                        if let page = DocumentCamera.stitch(pages) { Task { await attach(page) } }
                    }
                    .ignoresSafeArea()
                }
                .confirmationDialog("Delete this payment?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { store.delete(tx.id); dismiss() }
                }
            } else {
                Text("This payment was deleted.").foregroundStyle(Theme.secondary)
            }
        }
        .tint(Theme.accent)
    }

    private func summary(_ tx: Payment) -> some View {
        VStack(spacing: 8) {
            CategoryIcon(category: tx.category, size: 96)
            Text(tx.merchant).font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(tx.formattedAmount).font(.system(size: 48, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text(tx.date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))
                .font(.subheadline).foregroundStyle(Theme.secondary)
            if let back = splits.netted([tx]).first?.paidBack, back > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Theme.accent)
                    Text("\(dollars(back)) paid back · your share \(dollars(max(0, tx.amount - back)))")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.softGreen, in: Capsule())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    private func facts(_ tx: Payment) -> some View {
        VStack(spacing: 0) {
            row("Category") {
                Menu {
                    ForEach(SpendCategory.allCases) { option in
                        Button(option.title) { var changed = tx; changed.category = option; store.update(changed) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(tx.category.title)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.body.weight(.semibold))
                }
            }
            Divider()
            row("Paid with") {
                HStack(spacing: 8) {
                    if !tx.card.isEmpty { PayMethodIcon(name: tx.card, size: 24) }
                    Text(tx.card.isEmpty ? "—" : tx.card).font(.body.weight(.semibold))
                }
            }
            Divider()
            row("Added") {
                Label(tx.source.label, systemImage: tx.source == .tap ? "wave.3.right" : tx.source == .voice ? "mic" : "hand.tap")
                    .font(.body.weight(.semibold))
            }
            if let bill = store.recurringBill(tx.recurringID) {
                Divider()
                row("Repeats") {
                    Label("\(bill.every.short) · next \(bill.next.formatted(.dateTime.month(.abbreviated).day()))",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.semibold))
                }
            }
            if let note = tx.note {
                Divider()
                row("Note") { Text(note).font(.body).multilineTextAlignment(.trailing) }
            }
        }
        .padding(.horizontal, 16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.secondary)
            Spacer()
            value().foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 14)
    }

    /// The paper receipt, kept with the payment, or a way to add one.
    @ViewBuilder
    private func receiptCard(_ tx: Payment) -> some View {
        if ReceiptVault.has(tx.id) {
            Button { viewingReceipt = true } label: {
                HStack(spacing: 14) {
                    ReceiptThumb(id: tx.id, width: 58).rotationEffect(.degrees(-4))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Receipt").font(.headline).foregroundStyle(Theme.ink)
                        Text("Kept on your iPhone · tap to see it").font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Replace photo", systemImage: "photo") { choosingPhoto = true }
                Button("Remove photo", systemImage: "trash", role: .destructive) { store.removeReceipt(from: tx.id) }
            }
            .accessibilityIdentifier("payment-receipt")
        } else {
            Menu {
                if VNDocumentCameraViewController.isSupported {
                    Button("Take a photo", systemImage: "camera") { usingCamera = true }
                }
                Button("Choose a photo or screenshot", systemImage: "photo.on.rectangle") { choosingPhoto = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: attaching ? "hourglass" : "doc.text.viewfinder").font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                        .background(Theme.softGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attaching ? "Reading the receipt…" : "Add the receipt").font(.headline).foregroundStyle(Theme.ink)
                        Text("Keep the photo for reports and returns").font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Image(systemName: "plus").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondary)
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            }
            .buttonStyle(.plain)
            .disabled(attaching)
            .accessibilityIdentifier("payment-add-receipt")
        }
    }

    /// Keeps the photo. When the payment had no items and the receipt's total matches, its items come along.
    private func attach(_ image: UIImage) async {
        guard let tx else { return }
        attaching = true
        var items: [LineItem] = []
        if tx.items.isEmpty {
            let (scan, _, _) = await ReceiptReader.scan(image)
            if abs(scan.totalCents - tx.cents) <= 1, scan.itemsCents <= scan.totalCents {
                items = scan.lines.map { LineItem(name: $0.name, quantity: $0.quantity, price: Double($0.cents) / 100) }
            }
        }
        withAnimation(.snappy) { store.attachReceipt(image, to: tx.id, items: items) }
        attaching = false
    }

    private func itemsCard(_ tx: Payment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Items").font(.headline).foregroundStyle(Theme.ink)
            ForEach(tx.splitLines) { line in
                HStack {
                    Text(SplitService.emoji(for: line.name, category: tx.category))
                    Text(line.quantity > 1 ? "\(line.name) ×\(line.quantity)" : line.name).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(dollars(line.price ?? 0)).monospacedDigit().foregroundStyle(Theme.ink)
                }
                .font(.body)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func splitButton(_ tx: Payment) -> some View {
        let mark = splits.mark(for: tx.splitIDs)
        return Button { splitting = true } label: {
            Label(mark == nil ? "Split the bill" : mark == .settled ? "Split · everyone paid" : "Split · see who paid",
                  systemImage: mark == .settled ? "checkmark.circle.fill" : "person.2.fill")
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("payment-split")
    }
}
