import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import MergeLists

// AYG: the General, Chats and Appearance categories — exteraGram for Android's
// `GeneralPreferencesActivity`, `ChatsPreferencesActivity` and
// `AppearancePreferencesActivity`, limited to the rows that mean something on iOS.
//
// Rows exteraGram has that are deliberately absent, because they drive Android-only
// machinery: camera type / CameraX, tablet mode, Monet, Solar icons, FAB shape, drawer
// items, the in-app updater, Crashlytics and system fonts.
//
// All three screens are one generic list: every row is a toggle, a choice, a slider, a
// header or a footer, and every value is read from and written to
// `AYGExteraManager` (TelegramCore), which is what the rendering sites read too.

public enum AYGExteraScreen {
    case general
    case chats
    case appearance
}

private enum AYGExteraToggle: Equatable {
    case disableNumberRounding
    case formatTimeWithSeconds
    case hidePhoneNumber
    case disableUnarchiveSwipe
    case uploadSpeedBoost
    case hideStickerTime
    case unlimitedRecentStickers
    case hideKeyboardOnScroll
    case disableJumpToNextChannel
    case hideShareButton
    case showSaveMessageButton
    case showDetailsButton
    case showReportButton
    case addCommaAfterMention
    case hideActionBarStatus
    case tabCounter

    func get() -> Bool {
        let manager = AYGExteraManager.shared
        switch self {
        case .disableNumberRounding: return manager.disableNumberRounding
        case .formatTimeWithSeconds: return manager.formatTimeWithSeconds
        case .hidePhoneNumber: return manager.hidePhoneNumber
        case .disableUnarchiveSwipe: return manager.disableUnarchiveSwipe
        case .uploadSpeedBoost: return manager.uploadSpeedBoost
        case .hideStickerTime: return manager.hideStickerTime
        case .unlimitedRecentStickers: return manager.unlimitedRecentStickers
        case .hideKeyboardOnScroll: return manager.hideKeyboardOnScroll
        case .disableJumpToNextChannel: return manager.disableJumpToNextChannel
        case .hideShareButton: return manager.hideShareButton
        case .showSaveMessageButton: return manager.showSaveMessageButton
        case .showDetailsButton: return manager.showDetailsButton
        case .showReportButton: return manager.showReportButton
        case .addCommaAfterMention: return manager.addCommaAfterMention
        case .hideActionBarStatus: return manager.hideActionBarStatus
        case .tabCounter: return manager.tabCounter
        }
    }

    func set(_ value: Bool) {
        let manager = AYGExteraManager.shared
        switch self {
        case .disableNumberRounding: manager.disableNumberRounding = value
        case .formatTimeWithSeconds: manager.formatTimeWithSeconds = value
        case .hidePhoneNumber: manager.hidePhoneNumber = value
        case .disableUnarchiveSwipe: manager.disableUnarchiveSwipe = value
        case .uploadSpeedBoost: manager.uploadSpeedBoost = value
        case .hideStickerTime: manager.hideStickerTime = value
        case .unlimitedRecentStickers: manager.unlimitedRecentStickers = value
        case .hideKeyboardOnScroll: manager.hideKeyboardOnScroll = value
        case .disableJumpToNextChannel: manager.disableJumpToNextChannel = value
        case .hideShareButton: manager.hideShareButton = value
        case .showSaveMessageButton: manager.showSaveMessageButton = value
        case .showDetailsButton: manager.showDetailsButton = value
        case .showReportButton: manager.showReportButton = value
        case .addCommaAfterMention: manager.addCommaAfterMention = value
        case .hideActionBarStatus: manager.hideActionBarStatus = value
        case .tabCounter: manager.tabCounter = value
        }
    }

    var title: String {
        switch self {
        case .disableNumberRounding: return aygString("AYGExteraDisableNumberRounding")
        case .formatTimeWithSeconds: return aygString("AYGExteraFormatTimeWithSeconds")
        case .hidePhoneNumber: return aygString("AYGExteraHidePhoneNumber")
        case .disableUnarchiveSwipe: return aygString("AYGExteraDisableUnarchiveSwipe")
        case .uploadSpeedBoost: return aygString("AYGExteraUploadSpeedBoost")
        case .hideStickerTime: return aygString("AYGExteraHideStickerTime")
        case .unlimitedRecentStickers: return aygString("AYGExteraUnlimitedRecentStickers")
        case .hideKeyboardOnScroll: return aygString("AYGExteraHideKeyboardOnScroll")
        case .disableJumpToNextChannel: return aygString("AYGExteraDisableJumpToNextChannel")
        case .hideShareButton: return aygString("AYGExteraHideShareButton")
        case .showSaveMessageButton: return aygString("AYGSaveMessage")
        case .showDetailsButton: return aygString("AYGMessageDetails")
        case .showReportButton: return aygString("AYGExteraReport")
        case .addCommaAfterMention: return aygString("AYGExteraAddCommaAfterMention")
        case .hideActionBarStatus: return aygString("AYGExteraHideActionBarStatus")
        case .tabCounter: return aygString("AYGExteraTabCounter")
        }
    }

    /// The "before -> after" hint exteraGram prints under a few of its rows.
    var hint: String? {
        switch self {
        case .disableNumberRounding: return "1.23K -> 1,234"
        case .formatTimeWithSeconds: return "12:34 -> 12:34:56"
        default: return nil
        }
    }
}

private enum AYGExteraChoice: Equatable {
    case idFormat
    case doubleTapIncoming
    case doubleTapOutgoing
    case avatarShape
    case chatListTitle

    var title: String {
        switch self {
        case .idFormat: return aygString("AYGExteraShowIdAndDc")
        case .doubleTapIncoming: return aygString("AYGExteraDoubleTapIncoming")
        case .doubleTapOutgoing: return aygString("AYGExteraDoubleTapOutgoing")
        case .avatarShape: return aygString("AYGExteraAvatarShape")
        case .chatListTitle: return aygString("AYGExteraTitleText")
        }
    }

    var options: [String] {
        switch self {
        case .idFormat:
            return [aygString("AYGExteraHide"), "Telegram API", "Bot API"]
        case .doubleTapIncoming, .doubleTapOutgoing:
            return AYGDoubleTapAction.allCases.map(aygDoubleTapActionTitle)
        case .avatarShape:
            return [aygString("AYGExteraAvatarCircle"), aygString("AYGExteraAvatarRoundedSquare")]
        case .chatListTitle:
            return [aygString("AYGExteraTitleChats"), "AyuGram", "Telegram"]
        }
    }

    var selectedIndex: Int {
        let manager = AYGExteraManager.shared
        switch self {
        case .idFormat: return manager.showIdAndDc.rawValue
        case .doubleTapIncoming: return manager.doubleTapAction.rawValue
        case .doubleTapOutgoing: return manager.doubleTapActionOutOwner.rawValue
        case .avatarShape: return manager.avatarShape.rawValue
        case .chatListTitle: return manager.chatListTitle.rawValue
        }
    }

    func select(_ index: Int) {
        let manager = AYGExteraManager.shared
        switch self {
        case .idFormat:
            if let value = AYGIdFormat(rawValue: index) { manager.showIdAndDc = value }
        case .doubleTapIncoming:
            if let value = AYGDoubleTapAction(rawValue: index) { manager.doubleTapAction = value }
        case .doubleTapOutgoing:
            if let value = AYGDoubleTapAction(rawValue: index) { manager.doubleTapActionOutOwner = value }
        case .avatarShape:
            if let value = AYGAvatarShape(rawValue: index) { manager.avatarShape = value }
        case .chatListTitle:
            if let value = AYGChatListTitle(rawValue: index) { manager.chatListTitle = value }
        }
    }

    var valueTitle: String {
        let options = self.options
        let index = self.selectedIndex
        return index >= 0 && index < options.count ? options[index] : ""
    }
}

private func aygDoubleTapActionTitle(_ action: AYGDoubleTapAction) -> String {
    switch action {
    case .reaction: return aygString("AYGExteraDoubleTapReaction")
    case .reply: return aygString("AYGExteraDoubleTapReply")
    case .copy: return aygString("AYGExteraDoubleTapCopy")
    case .forward: return aygString("AYGExteraDoubleTapForward")
    case .edit: return aygString("AYGExteraDoubleTapEdit")
    case .saveMessage: return aygString("AYGSaveMessage")
    case .delete: return aygString("AYGExteraDoubleTapDelete")
    case .disabled: return aygString("AYGExteraDoubleTapDisabled")
    }
}

private enum AYGExteraSlider: Equatable {
    case downloadSpeedBoost
    case stickerSize

    static let stickerSizeStops: [Int] = [50, 75, 100, 125, 150]

    var titles: [String] {
        switch self {
        case .downloadSpeedBoost:
            return [aygString("AYGExteraOff"), aygString("AYGExteraFast"), aygString("AYGExteraUltra")]
        case .stickerSize:
            return AYGExteraSlider.stickerSizeStops.map { "\($0)%" }
        }
    }

    var index: Int {
        switch self {
        case .downloadSpeedBoost:
            return AYGExteraManager.shared.downloadSpeedBoost.rawValue
        case .stickerSize:
            let current = AYGExteraManager.shared.stickerSizePercent
            var best = 0
            for (i, value) in AYGExteraSlider.stickerSizeStops.enumerated() {
                if abs(value - current) < abs(AYGExteraSlider.stickerSizeStops[best] - current) {
                    best = i
                }
            }
            return best
        }
    }

    func select(_ index: Int) {
        switch self {
        case .downloadSpeedBoost:
            if let value = AYGDownloadSpeedBoost(rawValue: index) {
                AYGExteraManager.shared.downloadSpeedBoost = value
            }
        case .stickerSize:
            if index >= 0 && index < AYGExteraSlider.stickerSizeStops.count {
                AYGExteraManager.shared.stickerSizePercent = AYGExteraSlider.stickerSizeStops[index]
            }
        }
    }
}

private final class AYGExteraArguments {
    let toggle: (AYGExteraToggle, Bool) -> Void
    let openChoice: (AYGExteraChoice) -> Void
    let slide: (AYGExteraSlider, Int) -> Void

    init(toggle: @escaping (AYGExteraToggle, Bool) -> Void, openChoice: @escaping (AYGExteraChoice) -> Void, slide: @escaping (AYGExteraSlider, Int) -> Void) {
        self.toggle = toggle
        self.openChoice = openChoice
        self.slide = slide
    }
}

private enum AYGExteraEntry: ItemListNodeEntry {
    case header(id: Int32, section: Int32, text: String)
    case toggle(id: Int32, section: Int32, toggle: AYGExteraToggle, value: Bool)
    case choice(id: Int32, section: Int32, choice: AYGExteraChoice, value: String)
    case slider(id: Int32, section: Int32, slider: AYGExteraSlider, titles: [String], index: Int)
    case info(id: Int32, section: Int32, text: String)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _), let .toggle(_, section, _, _), let .choice(_, section, _, _), let .slider(_, section, _, _, _), let .info(_, section, _):
            return section
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(id, _, _), let .toggle(id, _, _, _), let .choice(id, _, _, _), let .slider(id, _, _, _, _), let .info(id, _, _):
            return id
        }
    }

    static func <(lhs: AYGExteraEntry, rhs: AYGExteraEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGExteraArguments
        switch self {
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .toggle(_, _, toggle, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: toggle.title, text: toggle.hint, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(toggle, value)
            })
        case let .choice(_, _, choice, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: choice.title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openChoice(choice)
            })
        case let .slider(_, _, slider, titles, index):
            return AYGSlideChooseItem(theme: presentationData.theme, systemStyle: .glass, titles: titles, value: index, sectionId: self.section, updated: { index in
                arguments.slide(slider, index)
            })
        case let .info(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// Builds entries with ids and sections handed out in order, so each screen below
/// reads top to bottom like the Android `updateRowsId`.
private struct AYGExteraEntryBuilder {
    private(set) var entries: [AYGExteraEntry] = []
    private var nextId: Int32 = 0
    private var section: Int32 = -1

    private mutating func id() -> Int32 {
        self.nextId += 1
        return self.nextId
    }

    mutating func header(_ text: String) {
        self.section += 1
        self.entries.append(.header(id: self.id(), section: self.section, text: text.uppercased()))
    }

    mutating func toggle(_ toggle: AYGExteraToggle) {
        self.entries.append(.toggle(id: self.id(), section: self.section, toggle: toggle, value: toggle.get()))
    }

    mutating func choice(_ choice: AYGExteraChoice) {
        self.entries.append(.choice(id: self.id(), section: self.section, choice: choice, value: choice.valueTitle))
    }

    mutating func slider(_ slider: AYGExteraSlider) {
        self.entries.append(.slider(id: self.id(), section: self.section, slider: slider, titles: slider.titles, index: slider.index))
    }

    mutating func info(_ text: String) {
        self.entries.append(.info(id: self.id(), section: self.section, text: text))
    }
}

private func aygExteraEntries(screen: AYGExteraScreen) -> [AYGExteraEntry] {
    var builder = AYGExteraEntryBuilder()
    switch screen {
    case .general:
        builder.header(aygString("CategoryGeneral"))
        builder.toggle(.disableNumberRounding)
        builder.toggle(.formatTimeWithSeconds)

        builder.header(aygString("AYGExteraDownloadSpeedBoost"))
        builder.slider(.downloadSpeedBoost)
        builder.toggle(.uploadSpeedBoost)
        builder.info(aygString("AYGExteraSpeedBoostInfo"))

        builder.header(aygString("AYGExteraProfile"))
        builder.toggle(.hidePhoneNumber)
        builder.choice(.idFormat)
        builder.info(aygString("AYGExteraShowIdAndDcInfo"))

        builder.header(aygString("AYGExteraArchive"))
        builder.toggle(.disableUnarchiveSwipe)
        builder.info(aygString("AYGExteraDisableUnarchiveSwipeInfo"))
    case .chats:
        builder.header(aygString("AYGExteraStickerSize"))
        builder.slider(.stickerSize)
        builder.toggle(.hideStickerTime)
        builder.toggle(.unlimitedRecentStickers)

        builder.header(aygString("AYGExteraDoubleTapAction"))
        builder.choice(.doubleTapIncoming)
        builder.choice(.doubleTapOutgoing)

        builder.header(aygString("AYGExteraMessageMenu"))
        builder.toggle(.showSaveMessageButton)
        builder.toggle(.showDetailsButton)
        builder.toggle(.showReportButton)

        builder.header(aygString("CategoryChats"))
        builder.toggle(.hideKeyboardOnScroll)
        builder.toggle(.disableJumpToNextChannel)
        builder.toggle(.hideShareButton)
        builder.toggle(.addCommaAfterMention)
    case .appearance:
        builder.header(aygString("AYGExteraAvatarShape"))
        builder.choice(.avatarShape)
        builder.info(aygString("AYGExteraAvatarShapeInfo"))

        builder.header(aygString("AYGExteraChatList"))
        builder.choice(.chatListTitle)
        builder.toggle(.hideActionBarStatus)
        builder.toggle(.tabCounter)
    }
    return builder.entries
}

private func aygExteraTitle(_ screen: AYGExteraScreen) -> String {
    switch screen {
    case .general: return aygString("CategoryGeneral")
    case .chats: return aygString("CategoryChats")
    case .appearance: return aygString("CategoryAppearance")
    }
}

public func aygExteraController(context: AccountContext, screen: AYGExteraScreen) -> ViewController {
    // The manager is the state; this promise only exists to push a redraw.
    let refreshPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    var refreshCounter = 0
    let refresh: () -> Void = {
        refreshCounter += 1
        refreshPromise.set(refreshCounter)
    }

    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = AYGExteraArguments(toggle: { toggle, value in
        toggle.set(value)
        refresh()
    }, openChoice: { choice in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: choice.title)]
        let selected = choice.selectedIndex
        for (index, title) in choice.options.enumerated() {
            items.append(ActionSheetButtonItem(title: index == selected ? "✓ " + title : title, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                choice.select(index)
                refresh()
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, slide: { slider, index in
        slider.select(index)
        refresh()
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        refreshPromise.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(aygExteraTitle(screen)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygExteraEntries(screen: screen),
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
