import Foundation
import TelegramCore
import UIKit
import Display
import TelegramPresentationData
import AppBundle

// AYG: the AyuGram settings screen, taken from AyuGram for Android
// (`com.radolyn.ayugram.preferences.AyuMainPreferencesActivity.fillItems`).
// Order, titles and icons are that method's, one for one.

public enum AYGSettingsCategory: Int, CaseIterable {
    case ghostMode
    case spy
    case filters
    case customization
    case plugins

    public var title: String {
        switch self {
        case .ghostMode: return aygString("CategoryGhostMode")
        case .spy: return aygString("CategorySpy")
        case .filters: return aygString("CategoryFilters")
        case .customization: return aygString("CategoryCustomization")
        case .plugins: return aygString("CategoryPlugins")
        }
    }

    // Android drawable this was lifted from, in the same order:
    // ayu_ghost (AyuGram's own vector), msg_bots, menu_tag_filter, msg_theme.
    var iconName: String {
        switch self {
        case .ghostMode: return "AyuGram/AYGGhost"
        case .spy: return "AyuGram/AYGSpy"
        case .filters: return "AyuGram/AYGFilters"
        case .customization: return "AyuGram/AYGCustomization"
        // exteraGram's plugins entry; no AyuGram drawable exists for it.
        case .plugins: return "Chat/Context Menu/FormatCode"
        }
    }

    func icon(theme: PresentationTheme) -> UIImage? {
        return generateTintedImage(image: UIImage(bundleImageName: self.iconName), color: theme.list.itemSecondaryTextColor)
    }
}

public enum AYGSettingsLink: Int, CaseIterable {
    case developer
    case channel
    case chats
    case translate
    case documentation

    public var title: String {
        switch self {
        case .developer: return aygString("AYGLinkDeveloper")
        case .channel: return aygString("AYGLinkChannel")
        case .chats: return aygString("AYGLinkChats")
        case .translate: return aygString("AYGLinkTranslate")
        case .documentation: return aygString("DocsText")
        }
    }

    public var value: String {
        switch self {
        case .developer: return aygDeveloperUsername
        // The channel row shows the channel's name rather than its username.
        case .channel: return "GCONNECT"
        case .chats: return "@gconnectpublic"
        case .translate: return "Crowdin"
        case .documentation: return "ayugram.one"
        }
    }

    // Telegram peers are opened by username, not by URL — see the comment in
    // AYGSettingsController for why.
    public var username: String? {
        switch self {
        case .developer: return String(aygDeveloperUsername.dropFirst())
        case .channel: return "g_tweaks"
        case .chats: return "gconnectpublic"
        case .translate, .documentation: return nil
        }
    }

    public var url: String? {
        switch self {
        case .developer, .channel, .chats: return nil
        // the only link stored unobfuscated in the APK
        case .translate: return "https://crowdin.com/project/exteralocales"
        case .documentation: return "https://ayugram.one"
        }
    }

    // Android: msg_channel, msg_groups, msg_translate, msg_language.
    var iconName: String {
        switch self {
        case .developer: return "Chat/Context Menu/User"
        case .channel: return "AyuGram/AYGChannel"
        case .chats: return "AyuGram/AYGChats"
        case .translate: return "AyuGram/AYGTranslate"
        case .documentation: return "AyuGram/AYGDocs"
        }
    }

    func icon(theme: PresentationTheme) -> UIImage? {
        return generateTintedImage(image: UIImage(bundleImageName: self.iconName), color: theme.list.itemSecondaryTextColor)
    }
}
