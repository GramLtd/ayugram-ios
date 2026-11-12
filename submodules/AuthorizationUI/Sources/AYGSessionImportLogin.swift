import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext

// AYG: "log in from an existing session" on the authorization screen, before any account
// exists. The in-app version (AyuGramUI) needs a full AccountContext; here there is only
// the SharedAccountContext of the login flow, so this is a self-contained UIKit path that
// calls the same TelegramCore core (parse → validate over the network → write an
// AccountBackupData-backed record). When it succeeds the new account becomes current and
// the app leaves the login flow on its own.
//
// For importing the user's OWN account. A .session file is a full credential.

private final class AYGLoginSessionPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    private var lifetime: AYGLoginSessionPickerDelegate?

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

private let aygLoginImportDisposable = MetaDisposable()

func aygPresentSessionImportLogin(from controller: ViewController, sharedContext: SharedAccountContext, presentationData: PresentationData) {
    guard #available(iOS 14.0, *) else {
        controller.present(textAlertController(sharedContext: sharedContext, title: nil, text: aygString("AYGSessionImportPickerUnavailable"), actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
        return
    }

    let present: (String) -> Void = { [weak controller] text in
        guard let controller else {
            return
        }
        controller.present(textAlertController(sharedContext: sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
    }

    let runImport: (URL) -> Void = { url in
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
                networkArguments: sharedContext.networkArguments,
                rootPath: sharedContext.basePath,
                testingEnvironment: false,
                session: session
            )
            |> mapToSignal { peerId -> Signal<Int64, AYGSessionImportError> in
                return aygAddImportedAccount(
                    accountManager: sharedContext.accountManager,
                    session: session,
                    peerId: peerId,
                    testingEnvironment: false,
                    makeCurrent: true
                )
            }
        }
        |> deliverOnMainQueue

        aygLoginImportDisposable.set(signal.start(next: { _ in
            // The new account is current now; the app tears the login flow down itself.
            present(aygString("AYGSessionImportSuccess"))
        }, error: { error in
            present(aygSessionImportLoginErrorText(error))
        }))
    }

    let delegate = AYGLoginSessionPickerDelegate(completion: { urls in
        guard let url = urls.first else {
            return
        }
        Queue.mainQueue().async {
            runImport(url)
        }
    })
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data, UTType.database], asCopy: true)
    picker.delegate = delegate
    picker.allowsMultipleSelection = false
    if let popover = picker.popoverPresentationController, let view = controller.view {
        popover.sourceView = view
        popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0.0, height: 0.0)
        popover.permittedArrowDirections = []
    }
    (controller.navigationController?.view.window?.rootViewController ?? controller.view.window?.rootViewController)?.present(picker, animated: true)
}

private func aygSessionImportLoginErrorText(_ error: AYGSessionImportError) -> String {
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
