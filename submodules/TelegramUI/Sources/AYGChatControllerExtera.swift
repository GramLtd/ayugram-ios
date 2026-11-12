import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import UndoUI
import TextFormat
import Pasteboard

// AYG: exteraGram's double-tap actions, run from `updateMessageReaction` when a double
// tap arrives with the `.default` reaction and the user picked something other than
// the stock quick reaction (`AYGExteraManager.doubleTapAction(outgoing:)`).
extension ChatController {
    func aygPerformDoubleTapAction(_ action: AYGDoubleTapAction, message: EngineRawMessage) {
        switch action {
        case .reaction, .disabled:
            break
        case .reply:
            self.interfaceInteraction?.setupReplyMessage(message.id, nil, { _, f in f() })
        case .copy:
            guard !message.text.isEmpty else {
                return
            }
            var entities: [MessageTextEntity]?
            for attribute in message.attributes {
                if let attribute = attribute as? TextEntitiesMessageAttribute {
                    entities = attribute.entities
                    break
                }
            }
            storeMessageTextInPasteboard(message.text, entities: entities)
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: self.presentationData.strings.Conversation_TextCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in
                return false
            }), in: .current)
        case .forward:
            if message.isCopyProtected() {
                return
            }
            self.interfaceInteraction?.forwardMessages([message])
        case .edit:
            guard canEditMessage(context: self.context, limitsConfiguration: self.context.currentLimitsConfiguration.with { EngineConfiguration.Limits($0) }, message: message) else {
                return
            }
            self.interfaceInteraction?.setupEditMessage(message.id, { _ in })
        case .saveMessage:
            self.aygSaveMessagesToSavedMessages([message])
        case .delete:
            self.interfaceInteraction?.deleteMessages([message], nil, { _ in })
        }
    }

    /// exteraGram's "Save" — forwards straight to Saved Messages, no peer picker.
    func aygSaveMessagesToSavedMessages(_ inputMessages: [EngineRawMessage]) {
        aygSaveToSavedMessages(context: self.context, messages: inputMessages, present: { [weak self] controller in
            self?.present(controller, in: .current)
        })
    }
}

/// exteraGram's "Save": forwards `messages` to Saved Messages and shows the stock
/// "Forwarded to Saved Messages" toast. Copy-protected messages are skipped.
func aygSaveToSavedMessages(context: AccountContext, messages inputMessages: [EngineRawMessage], present: (ViewController) -> Void) {
    let messages = inputMessages.filter { !$0.isCopyProtected() }
    if messages.isEmpty {
        return
    }
    let enqueue: [EnqueueMessage] = messages.map { message in
        return .forward(source: message.id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil)
    }
    let _ = enqueueMessages(account: context.account, peerId: context.account.peerId, messages: enqueue).startStandalone()
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let text = messages.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One : presentationData.strings.Conversation_ForwardTooltip_SavedMessages_Many
    present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: true, text: text), elevatedLayout: false, animateInAsReplacement: true, action: { _ in
        return false
    }))
}

/// exteraGram's "Details": everything about one message that the bubble does not show.
func aygMessageDetailsText(context: AccountContext, message: EngineRawMessage) -> String {
    var lines: [String] = []
    let peerRawId = message.id.peerId.id._internalGetInt64Value()
    lines.append("Message ID: \(message.id.id)")
    lines.append("Chat ID: \(peerRawId)")
    if let author = message.author {
        lines.append("Author ID: \(author.id.id._internalGetInt64Value())")
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    lines.append("Date: \(formatter.string(from: Date(timeIntervalSince1970: Double(message.timestamp))))")
    for attribute in message.attributes {
        if let attribute = attribute as? EditedMessageAttribute {
            lines.append("Edited: \(formatter.string(from: Date(timeIntervalSince1970: Double(attribute.date))))")
        }
    }
    if let forwardInfo = message.forwardInfo {
        lines.append("Forwarded: \(formatter.string(from: Date(timeIntervalSince1970: Double(forwardInfo.date))))")
        if let author = forwardInfo.author {
            lines.append("Forwarded from ID: \(author.id.id._internalGetInt64Value())")
        }
    }
    for media in message.media {
        if let file = media as? TelegramMediaFile {
            if let fileName = file.fileName {
                lines.append("File: \(fileName)")
            }
            lines.append("MIME: \(file.mimeType)")
            if let size = file.size {
                lines.append("Size: \(AYGExteraManager.groupedNumberString(Int(size))) B")
            }
            if let resource = file.resource as? CloudDocumentMediaResource {
                lines.append("DC: \(resource.datacenterId)")
            }
        } else if let image = media as? TelegramMediaImage {
            if let largest = image.representations.last {
                lines.append("Photo: \(Int(largest.dimensions.width))×\(Int(largest.dimensions.height))")
                if let resource = largest.resource as? CloudPhotoSizeMediaResource {
                    lines.append("DC: \(resource.datacenterId)")
                }
            }
        }
    }
    return lines.joined(separator: "\n")
}
