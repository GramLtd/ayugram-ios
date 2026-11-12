import Foundation

// AYG: storage for the features carried over from exteraGram for Android
// (`com.exteragram.messenger.ExteraConfig`).
//
// Same shape as `AYGCustomizationManager`: one App Group key per setting under the
// `AYG.extera.` prefix, every value cached behind a recursive lock, so the hot paths
// that ask (number and time formatting, chat bubble layout, avatar clipping) pay a
// lock and a dictionary lookup, never a disk read.
//
// Key names are exteraGram's own `SharedPreferences` keys, so any setting can be traced
// back to the Android source. Defaults differ from exteraGram's where exteraGram's would
// silently change how a stock iOS screen behaves for someone who never opened the new
// sections (share button, unarchive swipe, keyboard, comma) — those start off here.

/// What a double tap on a message does. exteraGram's `doubleTapAction` values, minus
/// the ones that need Android-only UI (translate, message details popup).
public enum AYGDoubleTapAction: Int, CaseIterable {
    case reaction = 0
    case reply = 1
    case copy = 2
    case forward = 3
    case edit = 4
    case saveMessage = 5
    case delete = 6
    case disabled = 7
}

/// exteraGram's `showIdAndDc`: hidden, the raw MTProto id, or the Bot API id (which
/// prefixes groups with `-` and channels with `-100`).
public enum AYGIdFormat: Int, CaseIterable {
    case hidden = 0
    case telegramApi = 1
    case botApi = 2
}

/// exteraGram's `titleText`: what the chat list's large title says.
public enum AYGChatListTitle: Int, CaseIterable {
    case chats = 0
    case appName = 1
    case telegram = 2
}

/// exteraGram's `downloadSpeedBoost`.
public enum AYGDownloadSpeedBoost: Int, CaseIterable {
    case off = 0
    case fast = 1
    case ultra = 2
}

/// exteraGram's `avatarCorners`, reduced to the two shapes iOS's avatar pipeline can
/// draw without touching every call site: the stock circle and the forum-style
/// rounded square.
public enum AYGAvatarShape: Int, CaseIterable {
    case circle = 0
    case roundedSquare = 1
}

public final class AYGExteraManager {
    public static let shared = AYGExteraManager()

    /// Posted after any setting changes.
    public static let settingsChangedNotification = Notification.Name("AYGExteraSettingsChanged")

    private enum Key: String {
        // General
        case disableNumberRounding
        case formatTimeWithSeconds
        case hidePhoneNumber
        case showIdAndDc
        case disableUnarchiveSwipe
        case downloadSpeedBoost
        case uploadSpeedBoost
        // Chats
        case stickerSize
        case hideStickerTime
        case unlimitedRecentStickers
        case doubleTapAction
        case doubleTapActionOutOwner
        case hideKeyboardOnScroll
        case disableJumpToNextChannel
        case hideShareButton
        case showSaveMessageButton
        case showDetailsButton
        case showReportButton
        case addCommaAfterMention
        // Appearance
        case avatarShape
        case hideActionBarStatus
        case tabCounter
        case titleText

        var storageKey: String {
            return "AYG.extera." + self.rawValue
        }

        var defaultValue: Int {
            switch self {
            case .showIdAndDc:
                return AYGIdFormat.telegramApi.rawValue
            case .stickerSize:
                return 100
            case .showReportButton, .tabCounter:
                return 1
            default:
                return 0
            }
        }
    }

    private let defaults = AYGSharedDefaults.store
    private let lock = NSRecursiveLock()
    private var cache: [Key: Int] = [:]

    private init() {}

    private func value(_ key: Key) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let cached = self.cache[key] {
            return cached
        }
        var result = key.defaultValue
        if let stored = self.defaults.object(forKey: key.storageKey) as? NSNumber {
            result = stored.intValue
        }
        self.cache[key] = result
        return result
    }

    private func setValue(_ key: Key, _ value: Int) {
        self.lock.lock()
        if self.cache[key] == value, self.defaults.object(forKey: key.storageKey) != nil {
            self.lock.unlock()
            return
        }
        self.cache[key] = value
        self.defaults.set(value, forKey: key.storageKey)
        self.lock.unlock()
        NotificationCenter.default.post(name: AYGExteraManager.settingsChangedNotification, object: nil)
    }

    private func bool(_ key: Key) -> Bool {
        return self.value(key) != 0
    }

    private func setBool(_ key: Key, _ value: Bool) {
        self.setValue(key, value ? 1 : 0)
    }

    // MARK: - General

    /// "1.23K" becomes "1,234" everywhere `compactNumericCountString` is used.
    public var disableNumberRounding: Bool {
        get { return self.bool(.disableNumberRounding) }
        set { self.setBool(.disableNumberRounding, newValue) }
    }

    /// Message timestamps gain seconds: "12:34" becomes "12:34:56".
    public var formatTimeWithSeconds: Bool {
        get { return self.bool(.formatTimeWithSeconds) }
        set { self.setBool(.formatTimeWithSeconds, newValue) }
    }

    /// Keeps the account's own number off the Settings header and the phone row.
    public var hidePhoneNumber: Bool {
        get { return self.bool(.hidePhoneNumber) }
        set { self.setBool(.hidePhoneNumber, newValue) }
    }

    public var showIdAndDc: AYGIdFormat {
        get { return AYGIdFormat(rawValue: self.value(.showIdAndDc)) ?? .telegramApi }
        set { self.setValue(.showIdAndDc, newValue.rawValue) }
    }

    /// Drops the "Unarchive" swipe action inside the archive, so a long swipe there can
    /// no longer pull a chat out by accident. The context menu still offers it.
    public var disableUnarchiveSwipe: Bool {
        get { return self.bool(.disableUnarchiveSwipe) }
        set { self.setBool(.disableUnarchiveSwipe, newValue) }
    }

    public var downloadSpeedBoost: AYGDownloadSpeedBoost {
        get { return AYGDownloadSpeedBoost(rawValue: self.value(.downloadSpeedBoost)) ?? .off }
        set { self.setValue(.downloadSpeedBoost, newValue.rawValue) }
    }

    public var uploadSpeedBoost: Bool {
        get { return self.bool(.uploadSpeedBoost) }
        set { self.setBool(.uploadSpeedBoost, newValue) }
    }

    /// How many parts of one file are downloaded at once, given what stock Telegram
    /// would have used. Only the large-file case is boosted: small files and stories
    /// are fetched the stock way.
    public func boostedDownloadParallelParts(_ stock: Int) -> Int {
        switch self.downloadSpeedBoost {
        case .off:
            return stock
        case .fast:
            return max(stock, 12)
        case .ultra:
            return max(stock, 16)
        }
    }

    /// Likewise for uploads that stock Telegram does not already parallelise heavily.
    public func boostedUploadParallelParts(_ stock: Int) -> Int {
        return self.uploadSpeedBoost ? max(stock, 8) : stock
    }

    // MARK: - Chats

    /// Sticker size as a percentage of stock (100).
    public var stickerSizePercent: Int {
        get { return max(50, min(150, self.value(.stickerSize))) }
        set { self.setValue(.stickerSize, max(50, min(150, newValue))) }
    }

    public var stickerScale: Double {
        return Double(self.stickerSizePercent) / 100.0
    }

    public var hideStickerTime: Bool {
        get { return self.bool(.hideStickerTime) }
        set { self.setBool(.hideStickerTime, newValue) }
    }

    public var unlimitedRecentStickers: Bool {
        get { return self.bool(.unlimitedRecentStickers) }
        set { self.setBool(.unlimitedRecentStickers, newValue) }
    }

    /// The cap on the local recent-stickers list.
    public var recentStickersLimit: Int {
        return self.unlimitedRecentStickers ? 200 : 20
    }

    /// Double tap on someone else's message.
    public var doubleTapAction: AYGDoubleTapAction {
        get { return AYGDoubleTapAction(rawValue: self.value(.doubleTapAction)) ?? .reaction }
        set { self.setValue(.doubleTapAction, newValue.rawValue) }
    }

    /// Double tap on the user's own message.
    public var doubleTapActionOutOwner: AYGDoubleTapAction {
        get { return AYGDoubleTapAction(rawValue: self.value(.doubleTapActionOutOwner)) ?? .reaction }
        set { self.setValue(.doubleTapActionOutOwner, newValue.rawValue) }
    }

    public func doubleTapAction(outgoing: Bool) -> AYGDoubleTapAction {
        return outgoing ? self.doubleTapActionOutOwner : self.doubleTapAction
    }

    /// Whether a double tap does something other than the stock quick reaction — in
    /// which case it has to be handled even where reactions are not allowed.
    public func overridesDoubleTap(outgoing: Bool) -> Bool {
        return self.doubleTapAction(outgoing: outgoing) != .reaction
    }

    public var hideKeyboardOnScroll: Bool {
        get { return self.bool(.hideKeyboardOnScroll) }
        set { self.setBool(.hideKeyboardOnScroll, newValue) }
    }

    /// Turns off "swipe up to go to the next unread channel".
    public var disableJumpToNextChannel: Bool {
        get { return self.bool(.disableJumpToNextChannel) }
        set { self.setBool(.disableJumpToNextChannel, newValue) }
    }

    /// Hides the round share button next to channel posts.
    public var hideShareButton: Bool {
        get { return self.bool(.hideShareButton) }
        set { self.setBool(.hideShareButton, newValue) }
    }

    /// "Save" in the message menu: forwards the message to Saved Messages in one tap.
    public var showSaveMessageButton: Bool {
        get { return self.bool(.showSaveMessageButton) }
        set { self.setBool(.showSaveMessageButton, newValue) }
    }

    /// "Details" in the message menu: ids, date, DC and file info.
    public var showDetailsButton: Bool {
        get { return self.bool(.showDetailsButton) }
        set { self.setBool(.showDetailsButton, newValue) }
    }

    public var showReportButton: Bool {
        get { return self.bool(.showReportButton) }
        set { self.setBool(.showReportButton, newValue) }
    }

    /// Picking a mention at the very start of the message inserts "@name, ".
    public var addCommaAfterMention: Bool {
        get { return self.bool(.addCommaAfterMention) }
        set { self.setBool(.addCommaAfterMention, newValue) }
    }

    // MARK: - Appearance

    public var avatarShape: AYGAvatarShape {
        get { return AYGAvatarShape(rawValue: self.value(.avatarShape)) ?? .circle }
        set { self.setValue(.avatarShape, newValue.rawValue) }
    }

    /// Hides the emoji status next to the chat list title.
    public var hideActionBarStatus: Bool {
        get { return self.bool(.hideActionBarStatus) }
        set { self.setBool(.hideActionBarStatus, newValue) }
    }

    /// Unread counters on folder tabs.
    public var tabCounter: Bool {
        get { return self.bool(.tabCounter) }
        set { self.setBool(.tabCounter, newValue) }
    }

    public var chatListTitle: AYGChatListTitle {
        get { return AYGChatListTitle(rawValue: self.value(.titleText)) ?? .chats }
        set { self.setValue(.titleText, newValue.rawValue) }
    }

    /// The root chat list's title, given the stock "Chats".
    public func chatListTitle(stock: String) -> String {
        switch self.chatListTitle {
        case .chats:
            return stock
        case .appName:
            return "AyuGram"
        case .telegram:
            return "Telegram"
        }
    }

    // MARK: - Formatting helpers

    /// `1234567` as "1,234,567" — what `compactNumericCountString` returns instead of
    /// "1.2M" while number rounding is off.
    public static func groupedNumberString(_ count: Int, separator: String = ",") -> String {
        let digits = String(abs(count))
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index != 0 && index % 3 == 0 {
                result.append(contentsOf: separator.reversed())
            }
            result.append(character)
        }
        return (count < 0 ? "-" : "") + String(result.reversed())
    }
}
