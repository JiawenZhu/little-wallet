import AppIntents

/// What the Shortcuts "Payment" automation runs after every Apple Pay tap: it saves the payment without
/// opening the app.
struct LogPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Payment"
    static var description = IntentDescription("Save a payment to Little Wallet. Add it to a Wallet Payment automation to track every Apple Pay tap.")
    static var openAppWhenRun = false

    @Parameter(title: "Merchant", default: "")
    var merchant: String

    @Parameter(title: "Amount", default: "")
    var amount: String

    @Parameter(title: "Card", default: "")
    var card: String

    /// Reads like a sentence in Shortcuts, which also helps Siri pick the right blanks when it builds the shortcut.
    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$amount) from \(\.$merchant), paid with \(\.$card)")
    }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = WalletStore.amount(amount)
        let saved = await MainActor.run {
            WalletStore.shared.add(merchant: merchant, amount: value, card: card, source: .tap)
        }
        await TapNotifier.saved(saved)
        return .result(dialog: saved.cents == 0 ? "Saved \(saved.merchant). Open Little Wallet to add the amount."
                                                : "Saved \(saved.formattedAmount) at \(saved.merchant).")
    }
}

struct LittleWalletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogPaymentIntent(),
                    phrases: ["Save a payment to \(.applicationName)", "Track a payment with \(.applicationName)",
                              "Save an Apple Pay payment to \(.applicationName)", "Log a payment in \(.applicationName)"],
                    shortTitle: "Save Payment", systemImageName: "creditcard.fill")
    }
}
