import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import MergeLists
import UndoUI

// AYG: the Plugins category — exteraGram's plugins screen.
//
// Layout follows exteraGram for Android: a master switch, the ways to install a
// plugin, then one row per installed plugin with its own switch. Tapping a plugin
// opens its page: description, author, version, the plugin's own settings
// (`createSettings()`), its log and a delete button.

private func aygPluginsPresentBulletin(context: AccountContext, controller: ViewController?, content: UndoOverlayContent) {
    guard let controller else {
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
}

private func aygPluginInstallBulletin(_ result: Result<AYGPluginInfo, AYGPluginInstallError>) -> UndoOverlayContent {
    switch result {
    case let .success(info):
        return .succeed(text: aygString("AYGPluginInstalled", info.name), timeout: nil, customUndoText: nil)
    case let .failure(error):
        return .info(title: nil, text: error.localizedText, timeout: nil, customUndoText: nil)
    }
}

private final class AYGPluginDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    private var lifetime: AYGPluginDocumentPickerDelegate?

    init(completion: @escaping ([URL]) -> Void) {
        self.completion = completion
        super.init()
        self.lifetime = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.completion(urls)
        self.lifetime = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.lifetime = nil
    }
}

// MARK: - Plugins list

private enum AYGPluginsSection: Int32 {
    case engine
    case install
    case plugins
}

private final class AYGPluginsArguments {
    let toggleEngine: (Bool) -> Void
    let installFromFile: () -> Void
    let installFromClipboard: () -> Void
    let installFromUrl: () -> Void
    let togglePlugin: (String, Bool) -> Void
    let openPlugin: (String) -> Void

    init(toggleEngine: @escaping (Bool) -> Void, installFromFile: @escaping () -> Void, installFromClipboard: @escaping () -> Void, installFromUrl: @escaping () -> Void, togglePlugin: @escaping (String, Bool) -> Void, openPlugin: @escaping (String) -> Void) {
        self.toggleEngine = toggleEngine
        self.installFromFile = installFromFile
        self.installFromClipboard = installFromClipboard
        self.installFromUrl = installFromUrl
        self.togglePlugin = togglePlugin
        self.openPlugin = openPlugin
    }
}

private enum AYGPluginsEntry: ItemListNodeEntry {
    case engine(Bool)
    case engineInfo(String)
    case installHeader(String)
    case installFile
    case installClipboard
    case installUrl
    case pluginsHeader(String)
    case plugin(index: Int32, id: String, title: String, subtitle: String, enabled: Bool, engineEnabled: Bool)
    case pluginsEmpty(String)

    var section: ItemListSectionId {
        switch self {
        case .engine, .engineInfo:
            return AYGPluginsSection.engine.rawValue
        case .installHeader, .installFile, .installClipboard, .installUrl:
            return AYGPluginsSection.install.rawValue
        case .pluginsHeader, .plugin, .pluginsEmpty:
            return AYGPluginsSection.plugins.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .engine: return 0
        case .engineInfo: return 1
        case .installHeader: return 2
        case .installFile: return 3
        case .installClipboard: return 4
        case .installUrl: return 5
        case .pluginsHeader: return 6
        case .pluginsEmpty: return 7
        case let .plugin(index, _, _, _, _, _): return 100 + index
        }
    }

    static func <(lhs: AYGPluginsEntry, rhs: AYGPluginsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGPluginsArguments
        switch self {
        case let .engine(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginsEnable"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleEngine(value)
            })
        case let .engineInfo(text), let .pluginsEmpty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .installHeader(text), let .pluginsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case .installFile:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginsInstallFile"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.installFromFile()
            })
        case .installClipboard:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginsInstallClipboard"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.installFromClipboard()
            })
        case .installUrl:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginsInstallUrl"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.installFromUrl()
            })
        case let .plugin(_, id, title, subtitle, enabled, engineEnabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: subtitle, value: enabled, enabled: engineEnabled, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.togglePlugin(id, value)
            }, action: {
                arguments.openPlugin(id)
            })
        }
    }
}

private func aygPluginsEntries() -> [AYGPluginsEntry] {
    let manager = AYGPluginManager.shared
    let engineEnabled = manager.isEngineEnabled
    var entries: [AYGPluginsEntry] = [
        .engine(engineEnabled),
        .engineInfo(aygString("AYGPluginsInfo")),
        .installHeader(aygString("AYGPluginsInstallHeader").uppercased()),
        .installFile,
        .installClipboard,
        .installUrl,
        .pluginsHeader(aygString("AYGPluginsInstalledHeader").uppercased())
    ]
    let plugins = manager.plugins
    if plugins.isEmpty {
        entries.append(.pluginsEmpty(aygString("AYGPluginsEmpty")))
    }
    for (index, info) in plugins.enumerated() {
        var subtitleParts: [String] = []
        if let error = manager.loadError(id: info.id) {
            subtitleParts.append("⚠️ " + (error.components(separatedBy: "\n").first ?? error))
        } else {
            subtitleParts.append("v\(info.version)" + (info.author.isEmpty ? "" : " · \(info.author)"))
            if !info.description.isEmpty {
                subtitleParts.append(info.description)
            }
        }
        entries.append(.plugin(index: Int32(index), id: info.id, title: info.name, subtitle: subtitleParts.joined(separator: "\n"), enabled: manager.isEnabled(id: info.id), engineEnabled: engineEnabled))
    }
    return entries
}

public func aygPluginsController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentBulletinImpl: ((UndoOverlayContent) -> Void)?
    var presentNativeControllerImpl: ((UIViewController) -> Void)?

    let arguments = AYGPluginsArguments(toggleEngine: { value in
        AYGPluginManager.shared.isEngineEnabled = value
    }, installFromFile: {
        let delegate = AYGPluginDocumentPickerDelegate(completion: { urls in
            for url in urls {
                guard let data = try? Data(contentsOf: url) else {
                    presentBulletinImpl?(.info(title: nil, text: aygString("AYGPluginErrorRead"), timeout: nil, customUndoText: nil))
                    continue
                }
                presentBulletinImpl?(aygPluginInstallBulletin(AYGPluginManager.shared.install(data: data)))
            }
        })
        var types: [UTType] = [UTType.javaScript, UTType.plainText, UTType.sourceCode]
        if let pluginType = UTType(filenameExtension: "plugin") {
            types.append(pluginType)
        }
        types.append(UTType.data)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = delegate
        picker.allowsMultipleSelection = true
        presentNativeControllerImpl?(picker)
    }, installFromClipboard: {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            presentBulletinImpl?(.info(title: nil, text: aygString("AYGPluginsClipboardEmpty"), timeout: nil, customUndoText: nil))
            return
        }
        presentBulletinImpl?(aygPluginInstallBulletin(AYGPluginManager.shared.install(source: text)))
    }, installFromUrl: {
        pushImpl?(aygPluginUrlInputController(context: context, completion: { url in
            presentBulletinImpl?(.info(title: nil, text: aygString("AYGPluginsDownloading"), timeout: nil, customUndoText: nil))
            let _ = (aygFiltersFetch(url: url)
            |> deliverOnMainQueue).startStandalone(next: { result in
                guard let body = result.body else {
                    presentBulletinImpl?(.info(title: nil, text: aygString("AYGPluginsDownloadFailed"), timeout: nil, customUndoText: nil))
                    return
                }
                presentBulletinImpl?(aygPluginInstallBulletin(AYGPluginManager.shared.install(source: body)))
            })
        }))
    }, togglePlugin: { id, value in
        AYGPluginManager.shared.setEnabled(id: id, value)
    }, openPlugin: { id in
        pushImpl?(aygPluginDetailController(context: context, pluginId: id))
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        AYGPluginManager.shared.updates
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(AYGSettingsCategory.plugins.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygPluginsEntries(),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentBulletinImpl = { [weak controller] content in
        aygPluginsPresentBulletin(context: context, controller: controller, content: content)
    }
    presentNativeControllerImpl = { [weak controller] c in
        guard let root = controller?.view.window?.rootViewController else {
            return
        }
        if let popover = c.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0.0, height: 0.0)
            popover.permittedArrowDirections = []
        }
        root.present(c, animated: true)
    }
    return controller
}

// MARK: - Install from URL

private final class AYGPluginUrlArguments {
    let update: (String) -> Void

    init(update: @escaping (String) -> Void) {
        self.update = update
    }
}

private enum AYGPluginUrlEntry: ItemListNodeEntry {
    case url(String)
    case info(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .url: return 0
        case .info: return 1
        }
    }

    static func <(lhs: AYGPluginUrlEntry, rhs: AYGPluginUrlEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGPluginUrlArguments
        switch self {
        case let .url(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: text, placeholder: "https://", type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.update(value)
            }, action: {})
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func aygPluginUrlInputController(context: AccountContext, completion: @escaping (String) -> Void) -> ViewController {
    let statePromise = ValuePromise("", ignoreRepeated: true)
    let stateValue = Atomic(value: "")
    var dismissImpl: (() -> Void)?

    let arguments = AYGPluginUrlArguments(update: { text in
        statePromise.set(stateValue.modify { _ in text })
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, url -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = trimmed.lowercased().hasPrefix("https://") || trimmed.lowercased().hasPrefix("http://")
        let rightNavigationButton = ItemListNavigationButton(content: .text(aygString("AYGPluginsInstallAction")), style: .bold, enabled: isValid, action: {
            dismissImpl?()
            completion(trimmed)
        })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(aygString("AYGPluginsInstallUrl")),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let entries: [AYGPluginUrlEntry] = [.url(url), .info(aygString("AYGPluginsInstallUrlInfo"))]
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    return controller
}

// MARK: - Plugin page

private final class AYGPluginDetailArguments {
    let toggleEnabled: (Bool) -> Void
    let toggleSetting: (String, Bool) -> Void
    let updateInput: (String, String) -> Void
    let openSelector: (String, String, [String]) -> Void
    let tapText: (Int) -> Void
    let copyLogs: () -> Void
    let copySource: () -> Void
    let delete: () -> Void

    init(toggleEnabled: @escaping (Bool) -> Void, toggleSetting: @escaping (String, Bool) -> Void, updateInput: @escaping (String, String) -> Void, openSelector: @escaping (String, String, [String]) -> Void, tapText: @escaping (Int) -> Void, copyLogs: @escaping () -> Void, copySource: @escaping () -> Void, delete: @escaping () -> Void) {
        self.toggleEnabled = toggleEnabled
        self.toggleSetting = toggleSetting
        self.updateInput = updateInput
        self.openSelector = openSelector
        self.tapText = tapText
        self.copyLogs = copyLogs
        self.copySource = copySource
        self.delete = delete
    }
}

private enum AYGPluginDetailKind: Equatable {
    case header(String)
    case footer(String)
    case enabled(Bool, Bool)
    case toggle(key: String, text: String, subtext: String?, value: Bool)
    case input(key: String, text: String, value: String)
    case selector(key: String, text: String, items: [String], value: Int)
    case action(index: Int, text: String, isAccent: Bool, isDestructive: Bool)
    case copyLogs
    case copySource
    case delete
}

private struct AYGPluginDetailEntry: ItemListNodeEntry {
    let stableId: Int32
    let sectionId: Int32
    let kind: AYGPluginDetailKind

    var section: ItemListSectionId {
        return self.sectionId
    }

    static func <(lhs: AYGPluginDetailEntry, rhs: AYGPluginDetailEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGPluginDetailArguments
        switch self.kind {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .enabled(value, engineEnabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginEnabled"), value: value, enabled: engineEnabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleEnabled(value)
            })
        case let .toggle(key, text, subtext, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, text: subtext, value: value, maximumNumberOfLines: 3, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSetting(key, value)
            })
        case let .input(key, text, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: value, placeholder: text, type: .regular(capitalization: false, autocorrection: false), clearType: .onFocus, sectionId: self.section, textUpdated: { value in
                arguments.updateInput(key, value)
            }, action: {})
        case let .selector(key, text, items, value):
            let label = value >= 0 && value < items.count ? items[value] : ""
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openSelector(key, text, items)
            })
        case let .action(index, text, isAccent, isDestructive):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: isDestructive ? .destructive : (isAccent ? .generic : .neutral), alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.tapText(index)
            })
        case .copyLogs:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginCopyLogs"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.copyLogs()
            })
        case .copySource:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginCopySource"), kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.copySource()
            })
        case .delete:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: aygString("AYGPluginDelete"), kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.delete()
            })
        }
    }
}

private func aygPluginDetailEntries(pluginId: String) -> [AYGPluginDetailEntry] {
    let manager = AYGPluginManager.shared
    guard let info = manager.plugin(id: pluginId) else {
        return []
    }
    var entries: [AYGPluginDetailEntry] = []
    var stableId: Int32 = 0
    var sectionId: Int32 = 0
    func add(_ kind: AYGPluginDetailKind) {
        entries.append(AYGPluginDetailEntry(stableId: stableId, sectionId: sectionId, kind: kind))
        stableId += 1
    }

    // About
    add(.header(info.name.uppercased()))
    add(.enabled(manager.isEnabled(id: pluginId), manager.isEngineEnabled))
    var about: [String] = []
    if !info.description.isEmpty {
        about.append(info.description)
    }
    about.append(aygString("AYGPluginVersion", info.version))
    if !info.author.isEmpty {
        about.append(aygString("AYGPluginAuthor", info.author))
    }
    about.append("ID: \(info.id)")
    if let error = manager.loadError(id: pluginId) {
        about.append("⚠️ " + error)
    }
    add(.footer(about.joined(separator: "\n")))

    // Plugin settings
    let items = manager.isLoaded(id: pluginId) ? manager.settingsItems(id: pluginId) : []
    if !items.isEmpty {
        sectionId += 1
        var sectionHasContent = false
        for item in items {
            switch item {
            case let .header(text):
                if sectionHasContent {
                    sectionId += 1
                }
                add(.header(text.uppercased()))
                sectionHasContent = false
            case let .divider(text):
                if let text {
                    add(.footer(text))
                }
                sectionId += 1
                sectionHasContent = false
            case let .toggle(key, text, subtext, defaultValue):
                let value = manager.settingValue(id: pluginId, key: key) as? Bool ?? defaultValue
                add(.toggle(key: key, text: text, subtext: subtext, value: value))
                sectionHasContent = true
            case let .input(key, text, subtext, defaultValue):
                let value = manager.settingValue(id: pluginId, key: key) as? String ?? defaultValue
                add(.input(key: key, text: text, value: value))
                if let subtext {
                    add(.footer(subtext))
                }
                sectionHasContent = true
            case let .selector(key, text, options, defaultValue):
                let value = (manager.settingValue(id: pluginId, key: key) as? NSNumber)?.intValue ?? defaultValue
                add(.selector(key: key, text: text, items: options, value: value))
                sectionHasContent = true
            case let .text(index, text, isAccent, isDestructive):
                add(.action(index: index, text: text, isAccent: isAccent, isDestructive: isDestructive))
                sectionHasContent = true
            }
        }
    }

    // Management
    sectionId += 1
    add(.copyLogs)
    add(.copySource)
    add(.delete)
    return entries
}

private func aygPluginDetailController(context: AccountContext, pluginId: String) -> ViewController {
    var presentBulletinImpl: ((UndoOverlayContent) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?

    let arguments = AYGPluginDetailArguments(toggleEnabled: { value in
        AYGPluginManager.shared.setEnabled(id: pluginId, value)
    }, toggleSetting: { key, value in
        AYGPluginManager.shared.setSettingValue(id: pluginId, key: key, value: value)
    }, updateInput: { key, value in
        AYGPluginManager.shared.setSettingValue(id: pluginId, key: key, value: value)
    }, openSelector: { key, title, items in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var sheetItems: [ActionSheetItem] = [ActionSheetTextItem(title: title)]
        for (index, item) in items.enumerated() {
            sheetItems.append(ActionSheetButtonItem(title: item, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                AYGPluginManager.shared.setSettingValue(id: pluginId, key: key, value: index)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: sheetItems),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, tapText: { index in
        AYGPluginManager.shared.textItemTapped(id: pluginId, index: index)
    }, copyLogs: {
        let text = AYGPluginManager.shared.logText(id: pluginId)
        UIPasteboard.general.string = text
        presentBulletinImpl?(.info(title: nil, text: text.isEmpty ? aygString("AYGPluginLogsEmpty") : aygString("AYGPluginLogsCopied"), timeout: nil, customUndoText: nil))
    }, copySource: {
        guard let source = AYGPluginManager.shared.source(id: pluginId) else {
            return
        }
        UIPasteboard.general.string = source
        presentBulletinImpl?(.info(title: nil, text: aygString("AYGPluginSourceCopied"), timeout: nil, customUndoText: nil))
    }, delete: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let name = AYGPluginManager.shared.plugin(id: pluginId)?.name ?? pluginId
        presentControllerImpl?(textAlertController(
            context: context,
            title: aygString("AYGPluginDelete"),
            text: aygString("AYGPluginDeleteConfirm", name),
            actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: aygString("AYGPluginDelete"), action: {
                    AYGPluginManager.shared.delete(id: pluginId)
                    dismissImpl?()
                })
            ]
        ))
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        AYGPluginManager.shared.updates
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(AYGPluginManager.shared.plugin(id: pluginId)?.name ?? AYGSettingsCategory.plugins.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygPluginDetailEntries(pluginId: pluginId),
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentBulletinImpl = { [weak controller] content in
        aygPluginsPresentBulletin(context: context, controller: controller, content: content)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    return controller
}
