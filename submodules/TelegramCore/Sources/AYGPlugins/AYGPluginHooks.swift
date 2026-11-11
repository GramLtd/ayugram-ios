import Foundation
import Postbox

// AYG: the TelegramCore end of the plugin system.
//
// Plugins are a port of exteraGram for Android's plugin feature. The engine that
// actually runs them (JavaScriptCore, settings, UI) lives in AyuGramUI; TelegramCore
// only exposes two hook points and never imports JavaScriptCore itself. That keeps
// the app extensions (Share, Notification Service, Siri), which link TelegramCore but
// never start the engine, exactly as they were: with no handler installed every hook
// here is a no-op.
//
//   enqueueMessages (EnqueueMessage.swift)   ->  `aygApplyPluginSendHooks`
//       exteraGram's `on_send_message_hook`: a plugin may leave an outgoing message
//       alone, rewrite its text, or cancel it.
//   replayFinalState (AccountStateManagementUtils.swift)  ->  `aygNotifyPluginsOfNewMessages`
//       exteraGram's `on_update_hook` narrowed to new messages: read-only.

/// What a plugin decided about one outgoing message.
public enum AYGPluginSendDecision {
    /// Send unchanged.
    case keep
    /// Send with this text instead. Entities are dropped, their ranges would be wrong.
    case replace(text: String)
    /// Do not send at all.
    case cancel
}

/// An outgoing message as plugins see it.
public struct AYGPluginOutgoingMessage {
    public let accountPeerId: PeerId
    public let peerId: PeerId
    public let threadId: Int64?
    public let text: String
    public let hasMedia: Bool
    public let replyToMessageId: MessageId?
}

/// A message that just arrived from the server, as plugins see it.
public struct AYGPluginIncomingMessage {
    public let accountPeerId: PeerId
    public let id: MessageId
    public let threadId: Int64?
    public let authorId: PeerId?
    public let timestamp: Int32
    public let text: String
    public let isOutgoing: Bool
    public let hasMedia: Bool
}

public final class AYGPluginHooks {
    private static let lock = NSLock()
    private static var _sendHandler: ((AYGPluginOutgoingMessage) -> AYGPluginSendDecision)?
    private static var _incomingHandler: (([AYGPluginIncomingMessage]) -> Void)?

    /// Installed by the plugin engine when at least one plugin wants outgoing messages.
    /// Called synchronously on whatever queue `enqueueMessages` runs on.
    public static var sendHandler: ((AYGPluginOutgoingMessage) -> AYGPluginSendDecision)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sendHandler
        }
        set {
            lock.lock()
            _sendHandler = newValue
            lock.unlock()
        }
    }

    /// Installed by the plugin engine. Called from inside a Postbox transaction, so it
    /// must only copy what it needs and hop elsewhere — never block, never call back
    /// into Postbox.
    public static var incomingHandler: (([AYGPluginIncomingMessage]) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _incomingHandler
        }
        set {
            lock.lock()
            _incomingHandler = newValue
            lock.unlock()
        }
    }

    private static let bypassKey = "AYG.plugins.bypassSendHooks"

    /// Runs `f` with the send hook switched off on the current thread. Used for messages
    /// a plugin sends itself, so a plugin rewriting every message does not rewrite (or
    /// cancel) its own output in a loop.
    public static func withSendHooksBypassed<T>(_ f: () -> T) -> T {
        let thread = Thread.current
        let previous = thread.threadDictionary[bypassKey] as? Bool ?? false
        thread.threadDictionary[bypassKey] = true
        defer {
            thread.threadDictionary[bypassKey] = previous
        }
        return f()
    }

    static var isBypassed: Bool {
        return Thread.current.threadDictionary[bypassKey] as? Bool ?? false
    }
}

/// Result of running the send hook over a batch: the batch to actually enqueue and,
/// for every entry in it, the index it had in the original batch.
struct AYGPluginSendHookResult {
    let messages: [EnqueueMessage]
    let originalIndices: [Int]
    let originalCount: Int

    /// Spreads the ids enqueued for `messages` back over the caller's original batch;
    /// cancelled messages come back as `nil`, the same as a message that failed to
    /// enqueue, so callers that zip ids with their input keep working.
    func restore(_ ids: [MessageId?]) -> [MessageId?] {
        if self.originalIndices.count == self.originalCount {
            return ids
        }
        var result = Array<MessageId?>(repeating: nil, count: self.originalCount)
        for i in 0 ..< min(ids.count, self.originalIndices.count) {
            result[self.originalIndices[i]] = ids[i]
        }
        return result
    }
}

func aygApplyPluginSendHooks(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> AYGPluginSendHookResult {
    let passthrough = AYGPluginSendHookResult(messages: messages, originalIndices: Array(0 ..< messages.count), originalCount: messages.count)
    guard let handler = AYGPluginHooks.sendHandler, !AYGPluginHooks.isBypassed else {
        return passthrough
    }

    var result: [EnqueueMessage] = []
    var indices: [Int] = []
    for (index, message) in messages.enumerated() {
        switch message {
        case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets):
            let decision = handler(AYGPluginOutgoingMessage(
                accountPeerId: account.peerId,
                peerId: peerId,
                threadId: threadId,
                text: text,
                hasMedia: mediaReference != nil,
                replyToMessageId: replyToMessageId?.messageId
            ))
            switch decision {
            case .keep:
                result.append(message)
                indices.append(index)
            case .cancel:
                break
            case let .replace(newText):
                if newText == text {
                    result.append(message)
                    indices.append(index)
                } else if newText.isEmpty && mediaReference == nil {
                    // An empty text message is not sendable; treat it as cancelled.
                    break
                } else {
                    let updatedAttributes = attributes.filter { !($0 is TextEntitiesMessageAttribute) }
                    result.append(.message(text: newText, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets))
                    indices.append(index)
                }
            }
        case .forward:
            // Forwards carry no text of their own; exteraGram does not hook them either.
            result.append(message)
            indices.append(index)
        }
    }
    return AYGPluginSendHookResult(messages: result, originalIndices: indices, originalCount: messages.count)
}

/// Called once per `.AddMessages` operation for the live end of history.
func aygNotifyPluginsOfNewMessages(accountPeerId: PeerId, messages: [StoreMessage]) {
    guard let handler = AYGPluginHooks.incomingHandler else {
        return
    }
    var items: [AYGPluginIncomingMessage] = []
    for message in messages {
        guard case let .Id(id) = message.id else {
            continue
        }
        items.append(AYGPluginIncomingMessage(
            accountPeerId: accountPeerId,
            id: id,
            threadId: message.threadId,
            authorId: message.authorId,
            timestamp: message.timestamp,
            text: message.text,
            isOutgoing: !message.flags.contains(.Incoming),
            hasMedia: !message.media.isEmpty
        ))
    }
    if !items.isEmpty {
        handler(items)
    }
}
