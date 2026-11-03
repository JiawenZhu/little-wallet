import Contacts
import SwiftUI

/// Search friends to split with: people you've split with before, your Contacts, or a Venmo username.
/// Tapping a row adds them straight into the split; the sheet stays open so you can add a few in a row.
struct FriendPicker: View {
    /// People already in the split, shown with a check.
    let added: Set<String>
    let onAdd: (SplitPerson) -> Void
    @ObservedObject private var service = SplitService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var contacts: [ContactMatch] = []
    @State private var access = CNContactStore.authorizationStatus(for: .contacts)
    @State private var justAdded: Set<String> = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var recent: [SplitPerson] {
        guard !trimmed.isEmpty else { return service.friends }
        return service.friends.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || ($0.venmo ?? "").localizedCaseInsensitiveContains(trimmed.trimmingCharacters(in: ["@"]))
        }
    }

    /// "@jane-doe" adds a Venmo username; anything else adds a name you can link to Venmo later.
    private var typed: (name: String, venmo: String?)? {
        guard !trimmed.isEmpty else { return nil }
        // A shared Venmo profile link: the username is the name until you rename them.
        if let handle = Venmo.username(fromLink: trimmed) { return (handle.replacingOccurrences(of: "-", with: " "), handle) }
        if trimmed.hasPrefix("@"), let handle = Venmo.recipient(trimmed) { return (String(trimmed.dropFirst()), handle) }
        if service.friends.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return nil }
        return (trimmed, nil)
    }

    var body: some View {
        NavigationStack {
            List {
                if let typed, typed.venmo != nil { typedSection(typed) }
                if !recent.isEmpty {
                    Section("Split with before") {
                        ForEach(recent) { friend in
                            row(name: friend.name, detail: friend.venmo.map { Venmo.label($0) } ?? "No Venmo yet", colors: friend.colors, key: friend.id) {
                                onAdd(friend); mark(friend.id)
                            }
                            .swipeActions {
                                Button("Forget", systemImage: "person.badge.minus", role: .destructive) {
                                    withAnimation { service.forget(friend) }
                                }
                            }
                        }
                    }
                }
                contactsSection
                if let typed, typed.venmo == nil { typedSection(typed) }
                if trimmed.isEmpty {
                    Section {
                        Label {
                            Text("In Venmo, open a friend's profile → Share → Copy link, then paste it in the search above.")
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        } icon: {
                            Text("V").font(.system(size: 13, weight: .black, design: .rounded))
                                .frame(width: 22, height: 22).background(Color(red: 0, green: 0.55, blue: 1), in: Circle()).foregroundStyle(.white)
                        }
                    } header: { Text("Friends from Venmo") }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, phone, @venmo or Venmo link")
            .navigationTitle("Add friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: trimmed) { await search() }
            .sensoryFeedback(.impact(weight: .light), trigger: justAdded.count)
        }
    }

    /// A Venmo username goes first; a plain name goes last, after any contacts that match it.
    private func typedSection(_ typed: (name: String, venmo: String?)) -> some View {
        Section {
            row(name: typed.name, detail: typed.venmo.map { "Venmo @\($0)" } ?? "Add by name", symbol: typed.venmo == nil ? "person.fill.badge.plus" : "at", key: "typed-\(typed.name)") {
                add(name: typed.name, venmo: typed.venmo)
            }
        }
    }

    /// Contacts not already in "Split with before".
    private var newContacts: [ContactMatch] {
        contacts.filter { match in !service.friends.contains { $0.name.caseInsensitiveCompare(match.name) == .orderedSame } }
    }

    @ViewBuilder private var contactsSection: some View {
        switch access {
        case .notDetermined:
            Section {
                Button {
                    Task {
                        _ = try? await CNContactStore().requestAccess(for: .contacts)
                        access = CNContactStore.authorizationStatus(for: .contacts)
                        await search()
                    }
                } label: {
                    Label("Find friends in Contacts", systemImage: "person.crop.circle.badge.magnifyingglass")
                        .font(.body.weight(.semibold))
                }
                .accessibilityIdentifier("split-contacts-access")
            } footer: {
                Text("Their phone number lets Venmo find them, so requests go to the right person. Contacts stay on your phone.")
            }
        case .denied, .restricted:
            Section {
                Text("Turn on Contacts for Little Wallet in Settings to search them here.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
        default:
            if !newContacts.isEmpty {
                Section(trimmed.isEmpty ? "Contacts" : "In your contacts") {
                    ForEach(newContacts) { match in
                        row(name: match.name, detail: match.phone ?? match.email ?? "", photo: match.thumbnail, key: match.id) {
                            add(name: match.name, venmo: match.phone ?? match.email)
                        }
                    }
                }
            }
        }
    }

    private func row(name: String, detail: String, colors: [Color] = [Theme.accent], photo: Data? = nil, symbol: String? = nil,
                     key: String, action: @escaping () -> Void) -> some View {
        let isIn = justAdded.contains(key) || added.contains(key) || service.friends.contains { $0.name == name && added.contains($0.id) }
        return Button(action: { if !isIn { action() } }) {
            HStack(spacing: 12) {
                ZStack {
                    if let photo, let image = UIImage(data: photo) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text(String(name.prefix(1)).uppercased()).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
                .background(SplitPerson.fill(colors), in: Circle())
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
                }
                Spacer()
                Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title2).foregroundStyle(isIn ? Theme.accent : Theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isIn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isIn ? "\(name), added" : "Add \(name)")
        .accessibilityIdentifier("split-pick-\(name)")
    }

    private func add(name: String, venmo: String?) {
        guard let person = service.rememberFriend(named: name, venmo: venmo) else { return }
        onAdd(person)
        mark(person.id)
        query = ""
    }

    private func mark(_ key: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { _ = justAdded.insert(key) }
    }

    private func search() async {
        // Full or limited (iOS 18) access.
        guard access != .notDetermined && access != .denied && access != .restricted else { contacts = []; return }
        let text = trimmed
        let found = await Task.detached(priority: .userInitiated) { ContactMatch.search(text) }.value
        if text == trimmed { withAnimation(.snappy) { contacts = found } }
    }
}

/// A contact that can be added to a split.
struct ContactMatch: Identifiable, Sendable {
    let id: String
    let name: String
    let phone: String?
    let email: String?
    let thumbnail: Data?

    static func search(_ text: String) -> [ContactMatch] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactEmailAddressesKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor]
        var list: [CNContact] = []
        if text.isEmpty {
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .givenName
            try? store.enumerateContacts(with: request) { contact, stop in
                list.append(contact)
                if list.count >= 40 { stop.pointee = true }
            }
        } else {
            list = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: text), keysToFetch: keys)) ?? []
            let digits = text.filter(\.isNumber)
            if digits.count >= 3 {
                let byPhone = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: text)), keysToFetch: keys)) ?? []
                list += byPhone.filter { found in !list.contains { $0.identifier == found.identifier } }
            }
        }
        return list.prefix(40).compactMap { contact in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            guard !name.isEmpty else { return nil }
            return ContactMatch(id: contact.identifier, name: name,
                                phone: contact.phoneNumbers.first?.value.stringValue,
                                email: contact.emailAddresses.first.map { String($0.value) },
                                thumbnail: contact.thumbnailImageData)
        }
    }
}

/// Venmo finds people by username, phone number or email. There's no public API to search Venmo itself,
/// so the app keeps whichever of these you give it and hands it to the Venmo app.
enum Venmo {
    /// The username in a shared Venmo profile link: "https://venmo.com/u/Jing-Allen" or "account.venmo.com/u/…".
    static func username(fromLink raw: String) -> String? {
        guard let match = raw.firstMatch(of: #/venmo\.com/(?:u/)?@?([A-Za-z0-9_-]{5,30})(?:[/?#]|$)/#) else { return nil }
        let handle = String(match.1)
        return ["code", "account", "signin", "login", "pay"].contains(handle.lowercased()) ? nil : handle
    }

    /// The value for `recipients=` in a venmo:// link, or nil when it isn't one Venmo understands.
    static func recipient(_ raw: String) -> String? {
        if let handle = username(fromLink: raw) { return handle }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("@"), !text.hasPrefix("@") { return text.count > 4 ? text.lowercased() : nil }  // email
        let digits = text.filter(\.isNumber)
        if digits.count >= 10, text.allSatisfy({ $0.isNumber || " +-().".contains($0) }) { return String(digits.suffix(10)) }
        let handle = text.trimmingCharacters(in: ["@"])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard (5...30).contains(handle.count), handle.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return handle
    }

    /// How a saved recipient reads in the app.
    static func label(_ recipient: String) -> String {
        if recipient.contains("@") { return recipient }
        if recipient.count == 10, recipient.allSatisfy(\.isNumber) {
            let d = Array(recipient)
            return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
        }
        return "@\(recipient)"
    }

    /// The note shown on the Venmo request: food emoji first, so it reads well in the Venmo feed.
    static func note(title: String, emojis: String?) -> String {
        let food = (emojis ?? "").isEmpty ? "🛒" : emojis!
        return "\(food) \(title) split · Little Wallet 👛"
    }

    /// Opens Venmo with a request filled in: who, how much and the note. You confirm it in Venmo.
    static func requestURL(recipient: String?, amount: String, note: String) -> URL? {
        var parts = URLComponents()
        parts.queryItems = [.init(name: "txn", value: "charge"), .init(name: "amount", value: amount), .init(name: "note", value: note)]
            + (recipient.map { [.init(name: "recipients", value: $0)] } ?? [])
        return URL(string: "venmo://paycharge?\(parts.percentEncodedQuery ?? "")")
    }
}
