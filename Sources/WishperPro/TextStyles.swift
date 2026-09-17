import Combine
import Foundation

/// Where the dictated text is going; each type has its own style.
enum AppCategory: String, CaseIterable, Identifiable, Codable {
    case aiChat
    case messages
    case email
    case documents
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aiChat: return "Chats de IA"
        case .messages: return "Mensagens"
        case .email: return "Email"
        case .documents: return "Documentos e notas"
        case .other: return "Outros"
        }
    }

    /// How the cleanup instructions describe the destination.
    var promptName: String {
        switch self {
        case .aiChat: return "an AI chat"
        case .messages: return "a messaging app"
        case .email: return "an email"
        case .documents: return "a document or note"
        case .other: return "another app"
        }
    }

    var defaultStyle: TextStyle {
        switch self {
        case .messages: return .casual
        case .email: return .formal
        case .aiChat, .documents, .other: return .natural
        }
    }
}

enum TextStyle: String, CaseIterable, Identifiable, Codable {
    case natural
    case casual
    case formal
    case unchanged

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .casual: return "Casual"
        case .formal: return "Formal"
        case .unchanged: return "Sem alterações"
        }
    }

    /// Style line of the cleanup instructions (`unchanged` never reaches the cleanup prompt).
    var instruction: String {
        switch self {
        case .natural:
            return "Neutral and faithful. Standard punctuation."
        case .casual:
            return "Relaxed, chat-like. Light punctuation; no period at the end of a short single message. Keep informal words."
        case .formal:
            return "Polished and professional. Full sentences and a formal register. Do not add greetings or sign-offs."
        case .unchanged:
            return ""
        }
    }
}

/// Built-in types for apps (`app:<bundle ID>`) and sites (`site:<host>`).
enum StyleCatalog {
    enum BrowserFamily {
        case safari
        case chromium
        case firefox
    }

    static let apps: [String: AppCategory] = [
        "com.anthropic.claudefordesktop": .aiChat,
        "com.openai.chat": .aiChat,
        "com.todesktop.230313mzl4w4u92": .aiChat,
        "ai.perplexity.mac": .aiChat,
        "net.whatsapp.WhatsApp": .messages,
        "com.apple.MobileSMS": .messages,
        "com.tinyspeck.slackmacgap": .messages,
        "com.microsoft.teams2": .messages,
        "com.hnc.Discord": .messages,
        "ru.keepcoder.Telegram": .messages,
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.SparkDesktop": .email,
        "com.apple.Notes": .documents,
        "com.apple.iWork.Pages": .documents,
        "com.microsoft.Word": .documents,
        "notion.id": .documents,
        "md.obsidian": .documents,
        "com.apple.TextEdit": .documents,
    ]

    static let sites: [String: AppCategory] = [
        "claude.ai": .aiChat,
        "chatgpt.com": .aiChat,
        "chat.openai.com": .aiChat,
        "gemini.google.com": .aiChat,
        "perplexity.ai": .aiChat,
        "copilot.microsoft.com": .aiChat,
        "web.whatsapp.com": .messages,
        "slack.com": .messages,
        "teams.microsoft.com": .messages,
        "teams.live.com": .messages,
        "discord.com": .messages,
        "web.telegram.org": .messages,
        "messenger.com": .messages,
        "mail.google.com": .email,
        "outlook.live.com": .email,
        "outlook.office.com": .email,
        "outlook.office365.com": .email,
        "mail.proton.me": .email,
        "docs.google.com": .documents,
        "notion.so": .documents,
        "notion.site": .documents,
    ]

    static let browsers: [String: BrowserFamily] = [
        "com.apple.Safari": .safari,
        "com.google.Chrome": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.brave.Browser": .chromium,
        "org.mozilla.firefox": .firefox,
    ]

    /// A page host (only known in browsers) wins over the app.
    static func key(bundleID: String, host: String?) -> String {
        if let host, !host.isEmpty {
            return "site:\(host)"
        }
        return "app:\(bundleID)"
    }

    /// The catalog's type, ignoring the user's choices.
    static func builtInCategory(forKey key: String) -> AppCategory {
        if key.hasPrefix("site:") {
            return siteCategory(host: String(key.dropFirst(5))) ?? .other
        }
        if key.hasPrefix("app:") {
            return apps[String(key.dropFirst(4))] ?? .other
        }
        return .other
    }

    /// The user's choice first, then the catalog, then Outros.
    static func category(forKey key: String, overrides: [String: AppCategory]) -> AppCategory {
        overrides[key] ?? builtInCategory(forKey: key)
    }

    /// A host matches an entry when it is the entry itself or one of its subdomains.
    static func siteCategory(host: String) -> AppCategory? {
        var candidate = host.lowercased()
        while true {
            if let category = sites[candidate] {
                return category
            }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
    }
}

/// Names, brands and acronyms to be written exactly as saved.
enum PersonalDictionary {
    static let maxEntries = 100
    static let maxLength = 60
    static let defaultEntries = ["Wishper Pro"]

    enum Rejection: Error, Equatable {
        case empty
        case duplicate
        case tooLong
        case full

        var message: String {
            switch self {
            case .empty: return "Escreve uma palavra."
            case .duplicate: return "Essa palavra já está no dicionário."
            case .tooLong: return "Cada entrada pode ter até \(PersonalDictionary.maxLength) caracteres."
            case .full: return "O dicionário já tem \(PersonalDictionary.maxEntries) entradas."
            }
        }
    }

    /// Drops what the transcription API refuses (`<`, `>`, line breaks) and collapses spaces.
    static func clean(_ entry: String) -> String {
        let separators = CharacterSet(charactersIn: "<>").union(.whitespacesAndNewlines)
        return entry.components(separatedBy: separators).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func adding(_ entry: String, to entries: [String]) -> Result<[String], Rejection> {
        let cleaned = clean(entry)
        guard !cleaned.isEmpty else { return .failure(.empty) }
        guard cleaned.count <= maxLength else { return .failure(.tooLong) }
        guard !entries.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else {
            return .failure(.duplicate)
        }
        guard entries.count < maxEntries else { return .failure(.full) }
        return .success(entries + [cleaned])
    }

    /// Saved entries go through the same rules; anything refused is dropped.
    static func sanitized(_ entries: [String]) -> [String] {
        entries.reduce(into: []) { result, entry in
            if case .success(let next) = adding(entry, to: result) {
                result = next
            }
        }
    }
}

struct RecentTarget: Codable, Equatable, Identifiable {
    let key: String
    let name: String

    var id: String { key }
}

/// Cleanup, styles, per-place types and the dictionary, saved in UserDefaults.
@MainActor
final class TextSettings: ObservableObject {
    private enum Key {
        static let cleanupEnabled = "wishper.cleanup_enabled"
        static let styles = "wishper.styles"
        static let targetCategories = "wishper.target_categories"
        static let recentTargets = "wishper.recent_targets"
        static let dictionary = "wishper.dictionary"
    }

    static let maxRecentTargets = 30

    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }
    @Published private(set) var styles: [AppCategory: TextStyle]
    @Published private(set) var targetCategories: [String: AppCategory]
    @Published private(set) var recentTargets: [RecentTarget]
    @Published private(set) var dictionary: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true
        let savedStyles = defaults.dictionary(forKey: Key.styles) as? [String: String] ?? [:]
        styles = Dictionary(uniqueKeysWithValues: AppCategory.allCases.map { category in
            (category, savedStyles[category.rawValue].flatMap(TextStyle.init(rawValue:)) ?? category.defaultStyle)
        })
        let savedCategories = defaults.dictionary(forKey: Key.targetCategories) as? [String: String] ?? [:]
        targetCategories = savedCategories.compactMapValues(AppCategory.init(rawValue:))
        let savedTargets = defaults.data(forKey: Key.recentTargets)
            .flatMap { try? JSONDecoder().decode([RecentTarget].self, from: $0) }
        recentTargets = savedTargets ?? []
        dictionary = PersonalDictionary.sanitized(
            defaults.stringArray(forKey: Key.dictionary) ?? PersonalDictionary.defaultEntries
        )
    }

    func style(for category: AppCategory) -> TextStyle {
        styles[category] ?? category.defaultStyle
    }

    func setStyle(_ style: TextStyle, for category: AppCategory) {
        styles[category] = style
        defaults.set(
            Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value.rawValue) }),
            forKey: Key.styles
        )
    }

    /// The style a dictation uses: "Sem alterações" while AI cleanup is off.
    func effectiveStyle(for category: AppCategory) -> TextStyle {
        cleanupEnabled ? style(for: category) : .unchanged
    }

    func category(forKey key: String) -> AppCategory {
        StyleCatalog.category(forKey: key, overrides: targetCategories)
    }

    /// `nil` goes back to the catalog's type.
    func setCategory(_ category: AppCategory?, forKey key: String) {
        targetCategories[key] = category
        defaults.set(targetCategories.mapValues(\.rawValue), forKey: Key.targetCategories)
    }

    /// Most recent first. Beyond 30, the oldest places without a chosen type are dropped.
    func recordTarget(key: String, name: String) {
        var targets = recentTargets.filter { $0.key != key }
        targets.insert(RecentTarget(key: key, name: name), at: 0)
        while targets.count > Self.maxRecentTargets,
              let index = targets.lastIndex(where: { targetCategories[$0.key] == nil }) {
            targets.remove(at: index)
        }
        recentTargets = targets
        defaults.set(try? JSONEncoder().encode(targets), forKey: Key.recentTargets)
    }

    /// Returns the reason when the word is refused.
    func addWord(_ word: String) -> PersonalDictionary.Rejection? {
        switch PersonalDictionary.adding(word, to: dictionary) {
        case .success(let entries):
            dictionary = entries
            defaults.set(entries, forKey: Key.dictionary)
            return nil
        case .failure(let rejection):
            return rejection
        }
    }

    func removeWord(_ word: String) {
        dictionary.removeAll { $0 == word }
        defaults.set(dictionary, forKey: Key.dictionary)
    }
}
