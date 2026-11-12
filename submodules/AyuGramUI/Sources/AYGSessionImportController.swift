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
import UndoUI

// AYG: "Add account via session" — logging in from an existing Telethon `.session` file
// instead of the phone + code flow. The heavy lifting lives in TelegramCore
// (`AYGSessionImport`): parse the file, validate the key over the network and learn the
// self peer id, then write a backup-shaped account record the app picks up on its next
// refresh. This screen is the file picker, a one-line explanation and the result.
//
// This is for importing the user's OWN accounts. A `.session` file is a full login
// credential, which the footer says in as many words.

// The picker holds its delegate weakly, so the delegate keeps itself alive until one of
// the two callbacks fires. Same shape as the Spy screen's picker delegate.
private final class AYGSessionPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    private var lifetime: AYGSessionPickerDelegate?

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

private enum AYGSessionImportSection: Int32 {
    case action
}

private enum AYGSessionImportEntry: ItemListNodeEntry {
    case chooseFile(String, Bool)
    case info(String)

    var section: ItemListSectionId {
        return AYGSessionImportSection.action.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .chooseFile: return 0
        case .info: return 1
        }
    }

    static func <(lhs: AYGSessionImportEntry, rhs: AYGSessionImportEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGSessionImportArguments
        switch self {
        case let .chooseFile(title, inProgress):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: inProgress ? .disabled : .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.chooseFile()
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class AYGSessionImportArguments {
    let chooseFile: () -> Void
    init(chooseFile: @escaping () -> Void) {
        self.chooseFile = chooseFile
    }
}

private func aygSessionImportEntries(inProgress: Bool) -> [AYGSessionImportEntry] {
    return [
        .chooseFile(inProgress ? aygString("AYGSessionImportInProgress") : aygString("AYGSessionImportChoose"), inProgress),
        .info(aygString("AYGSessionImportInfo"))
    ]
}

public func aygSessionImportController(context: AccountContext) -> ViewController {
    let statePromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    var inProgress = false
    let setProgress: (Bool) -> Void = { value in
        inProgress = value
        statePromise.set(value)
    }

    var presentNativeControllerImpl: ((UIViewController) -> Void)?
    var presentBulletinImpl: ((UndoOverlayContent) -> Void)?
    var dismissImpl: (() -> Void)?

    let importDisposable = MetaDisposable()

    let runImport: (URL) -> Void = { url in
        setProgress(true)
        // Parse off the main thread — SQLite open + read — then validate over the network
        // and write the record. The whole chain reports back on the main queue.
        let signal = Signal<AYGImportedSession, AYGSessionImportError> { subscriber in
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if let session = aygParseTelethonSession(path: url.path) {
                subscriber.putNext(session)
                subscriber.putCompletion()
            } else {
                subscriber.putError(.invalidFile)
            }
            return EmptyDisposable
        }
        |> runOn(Queue.concurrentDefaultQueue())
        |> mapToSignal { session -> Signal<Int64, AYGSessionImportError> in
            return aygResolveImportedSelf(
                networkArguments: context.sharedContext.networkArguments,
                rootPath: context.sharedContext.basePath,
                testingEnvironment: false,
                session: session
            )
            |> map { peerId -> (AYGImportedSession, Int64) in
                return (session, peerId)
            }
            |> mapToSignal { sessionAndPeer -> Signal<Int64, AYGSessionImportError> in
                return aygAddImportedAccount(
                    accountManager: context.sharedContext.accountManager,
                    session: sessionAndPeer.0,
                    peerId: sessionAndPeer.1,
                    testingEnvironment: false,
                    makeCurrent: true
                )
            }
        }
        |> deliverOnMainQueue

        importDisposable.set(signal.start(next: { _ in
            setProgress(false)
            presentBulletinImpl?(.succeed(text: aygString("AYGSessionImportSuccess"), timeout: nil, customUndoText: nil))
            // The new account is now current; drop the import screen so the app shows it.
            Queue.mainQueue().after(0.5) {
                dismissImpl?()
            }
        }, error: { error in
            setProgress(false)
            presentBulletinImpl?(.info(title: nil, text: aygSessionImportErrorText(error), timeout: nil, customUndoText: nil))
        }))
    }

    let arguments = AYGSessionImportArguments(chooseFile: {
        if inProgress {
            return
        }
        guard #available(iOS 14.0, *) else {
            presentBulletinImpl?(.info(title: nil, text: aygString("AYGSessionImportPickerUnavailable"), timeout: nil, customUndoText: nil))
            return
        }
        let delegate = AYGSessionPickerDelegate(completion: { urls in
            guard let url = urls.first else {
                return
            }
            Queue.mainQueue().async {
                runImport(url)
            }
        })
        // A `.session` file has no registered UTI, so allow any file and validate on read.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data, UTType.database], asCopy: true)
        picker.delegate = delegate
        picker.allowsMultipleSelection = false
        presentNativeControllerImpl?(picker)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, inProgress -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(aygString("AYGSessionImportTitle")),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygSessionImportEntries(inProgress: inProgress),
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        importDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
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
    presentBulletinImpl = { [weak controller] content in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}

private func aygSessionImportErrorText(_ error: AYGSessionImportError) -> String {
    switch error {
    case .invalidFile:
        return aygString("AYGSessionImportErrorFile")
    case .invalidAuthKey, .invalidDatacenter:
        return aygString("AYGSessionImportErrorKey")
    case .network:
        return aygString("AYGSessionImportErrorNetwork")
    case .keyRevoked:
        return aygString("AYGSessionImportErrorRevoked")
    case .alreadyAdded:
        return aygString("AYGSessionImportErrorExists")
    case .generic:
        return aygString("AYGSessionImportErrorGeneric")
    }
}
