import Foundation
import UIKit
import JavaScriptCore
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI

// AYG: plugins — a port of exteraGram for Android's plugin system.
//
// exteraGram runs Python plugins on Chaquopy and lets them hook arbitrary Java
// methods. Neither half exists on iOS: there is no JVM to hook and no Python to embed
// without shipping an interpreter. What *can* be carried over is the plugin model
// itself, so that is what this file is:
//
//   * a plugin is one source file with exteraGram's metadata globals
//     (`__id__`, `__name__`, `__description__`, `__author__`, `__version__`,
//     `__min_version__`, `__icon__`), read without running the file;
//   * it defines `class Plugin extends BasePlugin` with exteraGram's lifecycle
//     (`onPluginLoad` / `onPluginUnload`), `createSettings()` returning
//     `Header` / `Switch` / `Input` / `Selector` / `Divider` / `Text` items,
//     `onSendMessageHook(params)` returning a `HookResult` with a `HookStrategy`,
//     `addMenuItem({ menuType: MenuItemType.MESSAGE_CONTEXT_MENU, ... })`,
//     `BulletinHelper.show*`, `getSetting` / `setSetting` and `sendMessage`;
//   * snake_case spellings (`on_plugin_load`, `create_settings`,
//     `on_send_message_hook`, ...) are accepted too, so a Python plugin ports by
//     changing syntax, not structure.
//
// The language is JavaScript, run by the system JavaScriptCore — the only script
// engine an iOS app can use without bundling one.
//
// Threading: every JSContext lives on `queue` and is only ever touched there. The two
// TelegramCore hooks reach it with `queue.sync` (send — the caller needs the answer)
// or `queue.async` (incoming — read-only). Nothing on `queue` ever waits for the main
// thread, so the sync hop cannot deadlock.

public let aygPluginEngineVersion = "1.0.0"
public let aygPluginFileExtensions = ["js", "plugin"]

// MARK: - Models

public struct AYGPluginInfo: Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let author: String
    public let version: String
    public let minVersion: String?
    public let icon: String?
    public let fileURL: URL
}

public enum AYGPluginInstallError: Error {
    case invalidEncoding
    case missingId
    case invalidId
    case missingName
    case unsupportedVersion(String)
    case writeFailed

    public var localizedText: String {
        switch self {
        case .invalidEncoding:
            return aygString("AYGPluginErrorEncoding")
        case .missingId:
            return aygString("AYGPluginErrorMissingId")
        case .invalidId:
            return aygString("AYGPluginErrorInvalidId")
        case .missingName:
            return aygString("AYGPluginErrorMissingName")
        case let .unsupportedVersion(version):
            return aygString("AYGPluginErrorVersion", version)
        case .writeFailed:
            return aygString("AYGPluginErrorWrite")
        }
    }
}

public enum AYGPluginSettingItem: Equatable {
    case header(text: String)
    case divider(text: String?)
    case toggle(key: String, text: String, subtext: String?, defaultValue: Bool)
    case input(key: String, text: String, subtext: String?, defaultValue: String)
    case selector(key: String, text: String, items: [String], defaultValue: Int)
    case text(index: Int, text: String, isAccent: Bool, isDestructive: Bool)
}

public enum AYGPluginMenuType: String {
    case messageContextMenu = "message_context_menu"
}

public struct AYGPluginMenuItem: Equatable {
    public let pluginId: String
    public let itemId: String
    public let type: AYGPluginMenuType
    public let text: String
    public let icon: String?
}

private struct AYGPluginLogEntry {
    let date: Date
    let level: Int
    let text: String
}

// MARK: - Metadata

private func aygPluginMetadataValue(_ name: String, in source: String) -> String? {
    // `__name__ = "..."` / `const __name__ = '...'` / `` var __name__ = `...` ``.
    // Plain string literals only: metadata is read without running the file, the same
    // way exteraGram reads it with `ast` instead of importing the module.
    let pattern = "\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([\"'`])((?:\\\\.|(?!\\1).)*)\\1"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return nil
    }
    let range = NSRange(source.startIndex..., in: source)
    guard let match = regex.firstMatch(in: source, options: [], range: range), let valueRange = Range(match.range(at: 2), in: source) else {
        return nil
    }
    let raw = String(source[valueRange])
    return raw
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\'", with: "'")
        .replacingOccurrences(of: "\\\\", with: "\\")
}

private func aygPluginIsValidId(_ id: String) -> Bool {
    guard (2 ... 64).contains(id.count) else {
        return false
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
    return id.unicodeScalars.allSatisfy { allowed.contains($0) } && !id.hasPrefix(".")
}

private func aygCompareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let l = lhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    let r = rhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    for i in 0 ..< max(l.count, r.count) {
        let a = i < l.count ? l[i] : 0
        let b = i < r.count ? r[i] : 0
        if a != b {
            return a < b ? .orderedAscending : .orderedDescending
        }
    }
    return .orderedSame
}

private func aygParsePluginInfo(source: String, fileURL: URL) -> Result<AYGPluginInfo, AYGPluginInstallError> {
    guard let id = aygPluginMetadataValue("__id__", in: source), !id.isEmpty else {
        return .failure(.missingId)
    }
    guard aygPluginIsValidId(id) else {
        return .failure(.invalidId)
    }
    guard let name = aygPluginMetadataValue("__name__", in: source), !name.isEmpty else {
        return .failure(.missingName)
    }
    let minVersion = aygPluginMetadataValue("__min_version__", in: source)
    if let minVersion, !minVersion.isEmpty, aygCompareVersions(aygPluginEngineVersion, minVersion) == .orderedAscending {
        return .failure(.unsupportedVersion(minVersion))
    }
    return .success(AYGPluginInfo(
        id: id,
        name: name,
        description: aygPluginMetadataValue("__description__", in: source) ?? "",
        author: aygPluginMetadataValue("__author__", in: source) ?? "",
        version: aygPluginMetadataValue("__version__", in: source) ?? "1.0",
        minVersion: minVersion,
        icon: aygPluginMetadataValue("__icon__", in: source),
        fileURL: fileURL
    ))
}

// MARK: - Prelude

// The runtime every plugin is evaluated on top of. Callbacks (menu clicks, settings
// `onChange`, `onClick`, timers) are kept on the JS side and addressed by id, so Swift
// never holds a `JSValue` and no retain cycle runs through the context.
private let aygPluginPrelude = #"""
"use strict";
var __ayg_str = function (v) {
    if (typeof v === "string") { return v; }
    if (v instanceof Error) { return v.name + ": " + v.message + (v.stack ? "\n" + v.stack : ""); }
    try { var s = JSON.stringify(v); return s === undefined ? String(v) : s; } catch (e) { return String(v); }
};
var console = {
    log: function () { __ayg_log(0, Array.prototype.map.call(arguments, __ayg_str).join(" ")); },
    info: function () { __ayg_log(0, Array.prototype.map.call(arguments, __ayg_str).join(" ")); },
    debug: function () { __ayg_log(0, Array.prototype.map.call(arguments, __ayg_str).join(" ")); },
    warn: function () { __ayg_log(1, Array.prototype.map.call(arguments, __ayg_str).join(" ")); },
    error: function () { __ayg_log(2, Array.prototype.map.call(arguments, __ayg_str).join(" ")); }
};
var log = console.log;

var HookStrategy = Object.freeze({ DEFAULT: "default", MODIFY: "modify", MODIFY_FINAL: "modify_final", CANCEL: "cancel" });
class HookResult {
    constructor(options) {
        options = options || {};
        this.strategy = options.strategy || HookStrategy.DEFAULT;
        this.params = options.params !== undefined ? options.params : null;
    }
    static default() { return new HookResult(); }
    static modify(params) { return new HookResult({ strategy: HookStrategy.MODIFY, params: params }); }
    static cancel() { return new HookResult({ strategy: HookStrategy.CANCEL }); }
}

var MenuItemType = Object.freeze({ MESSAGE_CONTEXT_MENU: "message_context_menu" });

var BulletinHelper = Object.freeze({
    showInfo: function (text) { __ayg_bulletin("info", __ayg_str(text)); },
    showSimple: function (text) { __ayg_bulletin("info", __ayg_str(text)); },
    showSuccess: function (text) { __ayg_bulletin("success", __ayg_str(text)); },
    showError: function (text) { __ayg_bulletin("error", __ayg_str(text)); },
    show_info: function (text) { __ayg_bulletin("info", __ayg_str(text)); },
    show_success: function (text) { __ayg_bulletin("success", __ayg_str(text)); },
    show_error: function (text) { __ayg_bulletin("error", __ayg_str(text)); }
});

var Header = function (o) { o = typeof o === "string" ? { text: o } : (o || {}); return { type: "header", text: String(o.text || "") }; };
var Divider = function (o) { o = typeof o === "string" ? { text: o } : (o || {}); return { type: "divider", text: o.text !== undefined ? String(o.text) : null }; };
var Switch = function (o) { o = o || {}; return { type: "switch", key: String(o.key), text: String(o.text || o.key), subtext: o.subtext || null, default: !!o.default, onChange: o.onChange || o.on_change || null }; };
var Input = function (o) { o = o || {}; return { type: "input", key: String(o.key), text: String(o.text || o.key), subtext: o.subtext || null, default: o.default !== undefined ? String(o.default) : "", onChange: o.onChange || o.on_change || null }; };
var Selector = function (o) { o = o || {}; return { type: "selector", key: String(o.key), text: String(o.text || o.key), items: (o.items || []).map(String), default: o.default | 0, onChange: o.onChange || o.on_change || null }; };
var Text = function (o) { o = typeof o === "string" ? { text: o } : (o || {}); return { type: "text", text: String(o.text || ""), accent: !!o.accent, red: !!o.red, onClick: o.onClick || o.on_click || null }; };

var __ayg_timers = {};
var __ayg_next_timer = 1;
var setTimeout = function (fn, ms) {
    var id = __ayg_next_timer++;
    var args = Array.prototype.slice.call(arguments, 2);
    __ayg_timers[id] = function () { fn.apply(null, args); };
    __ayg_schedule(id, Math.max(0, +ms || 0));
    return id;
};
var clearTimeout = function (id) { delete __ayg_timers[id]; };

class BasePlugin {
    constructor() {
        this.__menuHandlers = {};
        this.__nextMenuId = 1;
    }
    get id() { return __ayg_plugin_id; }
    onPluginLoad() {}
    onPluginUnload() {}
    createSettings() { return []; }
    getSetting(key, defaultValue) {
        var v = __ayg_get_setting(String(key));
        return (v === undefined || v === null) ? (defaultValue === undefined ? null : defaultValue) : v;
    }
    setSetting(key, value) { __ayg_set_setting(String(key), value === undefined ? null : value); }
    log() { console.log.apply(console, arguments); }
    addMenuItem(item) {
        item = item || {};
        var id = item.item_id || item.itemId || ("item" + (this.__nextMenuId++));
        var handler = item.onClick || item.on_click;
        if (typeof handler === "function") { this.__menuHandlers[id] = handler; }
        __ayg_register_menu_item(String(id), String(item.menuType || item.menu_type || MenuItemType.MESSAGE_CONTEXT_MENU), String(item.text || id), item.icon ? String(item.icon) : "");
        return id;
    }
    removeMenuItem(id) { delete this.__menuHandlers[id]; __ayg_unregister_menu_item(String(id)); }
    sendMessage(params) {
        params = params || {};
        var peer = params.peer !== undefined ? params.peer : params.peerId;
        var text = params.message !== undefined ? params.message : params.text;
        __ayg_send_message(String(peer), String(text === undefined ? "" : text), params.replyToMessageId ? +params.replyToMessageId : 0, params.threadId ? String(params.threadId) : "");
    }
    // exteraGram (Python) spellings.
    get_setting(key, defaultValue) { return this.getSetting(key, defaultValue); }
    set_setting(key, value) { this.setSetting(key, value); }
    add_menu_item(item) { return this.addMenuItem(item); }
    remove_menu_item(id) { this.removeMenuItem(id); }
    send_message(params) { this.sendMessage(params); }
}

var __ayg_registered = null;
var registerPlugin = function (instance) { __ayg_registered = instance; };

var __ayg = (function () {
    var instance = null;
    var settingHandlers = {};
    var textHandlers = [];
    // Prefers a method the plugin defined itself over BasePlugin's no-op default, so
    // `on_plugin_load` wins over the inherited `onPluginLoad`.
    var method = function (names) {
        if (!instance) { return null; }
        var fallback = null;
        for (var i = 0; i < names.length; i++) {
            var f = instance[names[i]];
            if (typeof f !== "function") { continue; }
            if (f !== BasePlugin.prototype[names[i]]) { return f.bind(instance); }
            if (!fallback) { fallback = f.bind(instance); }
        }
        return fallback;
    };
    return {
        create: function () {
            if (__ayg_registered) { instance = __ayg_registered; }
            else if (typeof Plugin === "function") { instance = new Plugin(); }
            else { throw new Error("The plugin defines neither `class Plugin` nor calls registerPlugin()."); }
            if (!instance.__menuHandlers) { instance.__menuHandlers = {}; instance.__nextMenuId = 1; }
            return true;
        },
        load: function () { var f = method(["onPluginLoad", "on_plugin_load"]); if (f) { f(); } },
        unload: function () { var f = method(["onPluginUnload", "on_plugin_unload"]); __ayg_timers = {}; if (f) { f(); } },
        hasSendHook: function () { return !!method(["onSendMessageHook", "on_send_message_hook"]); },
        hasIncomingHook: function () { return !!method(["onIncomingMessage", "on_incoming_message"]); },
        send: function (params) {
            var f = method(["onSendMessageHook", "on_send_message_hook"]);
            if (!f) { return null; }
            var copy = Object.assign({}, params);
            var r = f.length >= 2 ? f(params.accountId, copy) : f(copy);
            if (r === undefined || r === null) { return null; }
            if (r === false) { return { strategy: "cancel" }; }
            if (typeof r === "string") { return { strategy: "modify", text: r }; }
            var strategy = r.strategy || HookStrategy.DEFAULT;
            if (strategy === HookStrategy.CANCEL) { return { strategy: "cancel" }; }
            if (strategy === HookStrategy.MODIFY || strategy === HookStrategy.MODIFY_FINAL) {
                var p = r.params || copy;
                var text = p.message !== params.message ? p.message : p.text;
                if (text === undefined || text === null) { text = params.text; }
                return { strategy: strategy, text: String(text) };
            }
            return null;
        },
        incoming: function (messages) {
            var f = method(["onIncomingMessage", "on_incoming_message"]);
            if (!f) { return; }
            for (var i = 0; i < messages.length; i++) {
                try { f(messages[i]); } catch (e) { console.error(e); }
            }
        },
        settings: function () {
            settingHandlers = {};
            textHandlers = [];
            var f = method(["createSettings", "create_settings"]);
            var items = f ? (f() || []) : [];
            var out = [];
            for (var i = 0; i < items.length; i++) {
                var it = items[i];
                if (!it || !it.type) { continue; }
                if (it.onChange && it.key) { settingHandlers[it.key] = it.onChange; }
                var plain = { type: it.type, text: it.text, key: it.key, subtext: it.subtext, items: it.items, accent: it.accent, red: it.red };
                plain.default = it.default;
                if (it.type === "text") { plain.index = textHandlers.length; textHandlers.push(it.onClick || null); }
                out.push(plain);
            }
            return out;
        },
        settingChanged: function (key, value) { var h = settingHandlers[key]; if (typeof h === "function") { h(value); } },
        textClicked: function (index) { var h = textHandlers[index]; if (typeof h === "function") { h(); } },
        menuClicked: function (itemId, context) { var h = instance && instance.__menuHandlers[itemId]; if (typeof h === "function") { h(context); } },
        fireTimer: function (id) { var t = __ayg_timers[id]; delete __ayg_timers[id]; if (t) { t(); } }
    };
})();
"""#

// MARK: - Loaded plugin

private final class AYGLoadedPlugin {
    let info: AYGPluginInfo
    let context: JSContext
    var hasSendHook = false
    var hasIncomingHook = false

    init(info: AYGPluginInfo, context: JSContext) {
        self.info = info
        self.context = context
    }

    func call(_ name: String, _ arguments: [Any] = []) -> JSValue? {
        guard let runtime = self.context.objectForKeyedSubscript("__ayg"), !runtime.isUndefined else {
            return nil
        }
        return runtime.invokeMethod(name, withArguments: arguments)
    }
}

// MARK: - Manager

public final class AYGPluginManager {
    public static let shared = AYGPluginManager()

    private static let engineEnabledKey = "AYG.plugins.engineEnabled"
    private static let enabledIdsKey = "AYG.plugins.enabledIds"
    private static func settingsKey(_ id: String) -> String {
        return "AYG.plugins.settings.\(id)"
    }

    private let queue = DispatchQueue(label: "ayg.plugins", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let virtualMachine: JSVirtualMachine = JSVirtualMachine()

    // Confined to `queue`.
    private var loaded: [String: AYGLoadedPlugin] = [:]

    // Read from any thread.
    private let lock = NSLock()
    private var _infos: [AYGPluginInfo] = []
    private var _loadErrors: [String: String] = [:]
    private var _menuItems: [AYGPluginMenuItem] = []
    private var _logs: [String: [AYGPluginLogEntry]] = [:]
    private var _sendHookIds: Set<String> = []
    private var _incomingHookIds: Set<String> = []

    // Main thread only.
    private weak var context: AccountContext?
    private var started = false

    private let updatesPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    private var updatesCounter = 0

    /// Fires (on the main queue) whenever the plugin list, a plugin's state or a
    /// plugin's settings change.
    public var updates: Signal<Void, NoError> {
        return self.updatesPromise.get() |> map { _ in Void() } |> deliverOnMainQueue
    }

    private init() {
        self.queue.setSpecific(key: self.queueKey, value: true)
    }

    // MARK: Paths

    public var pluginsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("AyuGramPlugins", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: Lifecycle

    /// Called from `TelegramRootController` for every account; the most recent
    /// account is the one `sendMessage` and bulletins use.
    public func start(context: AccountContext) {
        assert(Thread.isMainThread)
        self.context = context
        if self.started {
            return
        }
        self.started = true
        self.rescan()
        if self.isEngineEnabled {
            self.loadAllEnabled()
        }
        self.installHooks()
    }

    private func installHooks() {
        AYGPluginHooks.sendHandler = { [weak self] message in
            return self?.handleSend(message) ?? .keep
        }
        AYGPluginHooks.incomingHandler = { [weak self] messages in
            self?.handleIncoming(messages)
        }
    }

    // MARK: Public state

    public var isEngineEnabled: Bool {
        get {
            return AYGSharedDefaults.store.object(forKey: AYGPluginManager.engineEnabledKey) as? Bool ?? true
        }
        set {
            AYGSharedDefaults.store.set(newValue, forKey: AYGPluginManager.engineEnabledKey)
            if newValue {
                self.loadAllEnabled()
            } else {
                self.unloadAll()
            }
            self.notifyUpdated()
        }
    }

    public var plugins: [AYGPluginInfo] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._infos
    }

    public func plugin(id: String) -> AYGPluginInfo? {
        return self.plugins.first(where: { $0.id == id })
    }

    public func loadError(id: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._loadErrors[id]
    }

    private var enabledIds: Set<String> {
        get {
            return Set(AYGSharedDefaults.store.stringArray(forKey: AYGPluginManager.enabledIdsKey) ?? [])
        }
        set {
            AYGSharedDefaults.store.set(Array(newValue).sorted(), forKey: AYGPluginManager.enabledIdsKey)
        }
    }

    public func isEnabled(id: String) -> Bool {
        return self.enabledIds.contains(id)
    }

    public func isLoaded(id: String) -> Bool {
        return self.runOnQueue { self.loaded[id] != nil }
    }

    public func setEnabled(id: String, _ value: Bool) {
        var ids = self.enabledIds
        if value {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        self.enabledIds = ids
        if value, self.isEngineEnabled, let info = self.plugin(id: id) {
            self.queue.async {
                self.load(info: info)
                self.notifyUpdated()
            }
        } else if !value {
            self.queue.async {
                self.unload(id: id)
                self.notifyUpdated()
            }
        }
        self.notifyUpdated()
    }

    // MARK: Install / delete

    @discardableResult
    public func install(data: Data) -> Result<AYGPluginInfo, AYGPluginInstallError> {
        guard let source = String(data: data, encoding: .utf8) else {
            return .failure(.invalidEncoding)
        }
        return self.install(source: source)
    }

    @discardableResult
    public func install(source: String) -> Result<AYGPluginInfo, AYGPluginInstallError> {
        let placeholderURL = self.pluginsDirectory.appendingPathComponent("plugin.js")
        let parsed = aygParsePluginInfo(source: source, fileURL: placeholderURL)
        guard case let .success(parsedInfo) = parsed else {
            return parsed
        }
        let fileURL = self.pluginsDirectory.appendingPathComponent("\(parsedInfo.id).js")
        guard let data = source.data(using: .utf8), (try? data.write(to: fileURL, options: .atomic)) != nil else {
            return .failure(.writeFailed)
        }
        let info = AYGPluginInfo(id: parsedInfo.id, name: parsedInfo.name, description: parsedInfo.description, author: parsedInfo.author, version: parsedInfo.version, minVersion: parsedInfo.minVersion, icon: parsedInfo.icon, fileURL: fileURL)

        self.lock.lock()
        self._infos.removeAll(where: { $0.id == info.id })
        self._infos.append(info)
        self._infos.sort(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        self._loadErrors[info.id] = nil
        self.lock.unlock()

        // exteraGram enables a plugin as soon as it is installed; an update keeps
        // the plugin's state but re-runs it.
        var ids = self.enabledIds
        ids.insert(info.id)
        self.enabledIds = ids
        if self.isEngineEnabled {
            self.queue.async {
                self.unload(id: info.id)
                self.load(info: info)
                self.notifyUpdated()
            }
        }
        self.notifyUpdated()
        return .success(info)
    }

    public func delete(id: String) {
        guard let info = self.plugin(id: id) else {
            return
        }
        self.queue.async {
            self.unload(id: id)
            self.notifyUpdated()
        }
        try? FileManager.default.removeItem(at: info.fileURL)
        var ids = self.enabledIds
        ids.remove(id)
        self.enabledIds = ids
        AYGSharedDefaults.store.removeObject(forKey: AYGPluginManager.settingsKey(id))

        self.lock.lock()
        self._infos.removeAll(where: { $0.id == id })
        self._loadErrors[id] = nil
        self._logs[id] = nil
        self.lock.unlock()
        self.notifyUpdated()
    }

    public func source(id: String) -> String? {
        guard let info = self.plugin(id: id) else {
            return nil
        }
        return try? String(contentsOf: info.fileURL, encoding: .utf8)
    }

    private func rescan() {
        let directory = self.pluginsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var infos: [AYGPluginInfo] = []
        var errors: [String: String] = [:]
        for file in files where aygPluginFileExtensions.contains(file.pathExtension.lowercased()) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            switch aygParsePluginInfo(source: source, fileURL: file) {
            case let .success(info):
                if !infos.contains(where: { $0.id == info.id }) {
                    infos.append(info)
                }
            case let .failure(error):
                errors[file.deletingPathExtension().lastPathComponent] = error.localizedText
            }
        }
        infos.sort(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        self.lock.lock()
        self._infos = infos
        self._loadErrors.merge(errors, uniquingKeysWith: { _, new in new })
        self.lock.unlock()
    }

    // MARK: Loading

    private func loadAllEnabled() {
        let infos = self.plugins
        let ids = self.enabledIds
        self.queue.async {
            for info in infos where ids.contains(info.id) && self.loaded[info.id] == nil {
                self.load(info: info)
            }
            self.notifyUpdated()
        }
    }

    private func unloadAll() {
        self.queue.async {
            for id in Array(self.loaded.keys) {
                self.unload(id: id)
            }
            self.notifyUpdated()
        }
    }

    private func load(info: AYGPluginInfo) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        if self.loaded[info.id] != nil {
            return
        }
        guard let source = try? String(contentsOf: info.fileURL, encoding: .utf8) else {
            self.setLoadError(id: info.id, aygString("AYGPluginErrorRead"))
            return
        }
        guard let context = JSContext(virtualMachine: self.virtualMachine) else {
            return
        }
        context.name = "AyuGram plugin \(info.id)"
        let pluginId = info.id
        var loadFailure: String?
        context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "unknown error"
            let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
            let message = stack.isEmpty || stack == "undefined" ? text : "\(text)\n\(stack)"
            loadFailure = message
            self?.appendLog(id: pluginId, level: 2, text: message)
        }
        self.installNatives(into: context, pluginId: pluginId, info: info)
        context.evaluateScript(aygPluginPrelude, withSourceURL: URL(string: "ayugram://prelude.js"))
        if let failure = loadFailure {
            self.setLoadError(id: pluginId, failure)
            return
        }
        context.evaluateScript(source, withSourceURL: info.fileURL)
        let plugin = AYGLoadedPlugin(info: info, context: context)
        if loadFailure == nil {
            _ = plugin.call("create")
        }
        if loadFailure == nil {
            plugin.hasSendHook = plugin.call("hasSendHook")?.toBool() ?? false
            plugin.hasIncomingHook = plugin.call("hasIncomingHook")?.toBool() ?? false
            self.loaded[pluginId] = plugin
            _ = plugin.call("load")
        }
        if let failure = loadFailure, self.loaded[pluginId] == nil {
            self.setLoadError(id: pluginId, failure)
            self.removeMenuItems(pluginId: pluginId)
            return
        }
        self.lock.lock()
        self._loadErrors[pluginId] = nil
        if plugin.hasSendHook {
            self._sendHookIds.insert(pluginId)
        }
        if plugin.hasIncomingHook {
            self._incomingHookIds.insert(pluginId)
        }
        self.lock.unlock()
        self.appendLog(id: pluginId, level: 0, text: "Loaded \(info.name) \(info.version)")
    }

    private func unload(id: String) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard let plugin = self.loaded.removeValue(forKey: id) else {
            return
        }
        _ = plugin.call("unload")
        plugin.context.exceptionHandler = nil
        self.lock.lock()
        self._sendHookIds.remove(id)
        self._incomingHookIds.remove(id)
        self.lock.unlock()
        self.removeMenuItems(pluginId: id)
        self.appendLog(id: id, level: 0, text: "Unloaded")
    }

    private func setLoadError(id: String, _ text: String) {
        self.lock.lock()
        self._loadErrors[id] = text
        self.lock.unlock()
        self.notifyUpdated()
    }

    // MARK: Natives

    private func installNatives(into context: JSContext, pluginId: String, info: AYGPluginInfo) {
        context.setObject(pluginId, forKeyedSubscript: "__ayg_plugin_id" as NSString)
        context.setObject(aygPluginEngineVersion, forKeyedSubscript: "__ayg_engine_version" as NSString)
        let appInfo: [String: Any] = [
            "name": aygAppName,
            "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
            "engineVersion": aygPluginEngineVersion,
            "developer": aygDeveloperUsername
        ]
        context.setObject(appInfo, forKeyedSubscript: "AyuGram" as NSString)

        let logBlock: @convention(block) (Int, String) -> Void = { [weak self] level, text in
            self?.appendLog(id: pluginId, level: level, text: text)
        }
        context.setObject(unsafeBitCast(logBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_log" as NSString)

        let bulletinBlock: @convention(block) (String, String) -> Void = { [weak self] kind, text in
            DispatchQueue.main.async {
                self?.presentBulletin(kind: kind, text: text)
            }
        }
        context.setObject(unsafeBitCast(bulletinBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_bulletin" as NSString)

        let getSettingBlock: @convention(block) (String) -> AnyObject? = { key in
            let dict = AYGSharedDefaults.store.dictionary(forKey: AYGPluginManager.settingsKey(pluginId)) ?? [:]
            if let value = dict[key] {
                return value as AnyObject
            }
            return NSNull()
        }
        context.setObject(unsafeBitCast(getSettingBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_get_setting" as NSString)

        let setSettingBlock: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            self?.storeSetting(pluginId: pluginId, key: key, value: value.isNull || value.isUndefined ? nil : value.toObject())
            self?.notifyUpdated()
        }
        context.setObject(unsafeBitCast(setSettingBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_set_setting" as NSString)

        let scheduleBlock: @convention(block) (Int, Double) -> Void = { [weak self, weak context] timerId, ms in
            self?.queue.asyncAfter(deadline: .now() + ms / 1000.0) { [weak self] in
                guard let self, let context, let plugin = self.loaded[pluginId], plugin.context === context else {
                    return
                }
                _ = plugin.call("fireTimer", [timerId])
            }
        }
        context.setObject(unsafeBitCast(scheduleBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_schedule" as NSString)

        let registerMenuBlock: @convention(block) (String, String, String, String) -> Void = { [weak self] itemId, type, text, icon in
            guard let self, let menuType = AYGPluginMenuType(rawValue: type) else {
                return
            }
            self.lock.lock()
            self._menuItems.removeAll(where: { $0.pluginId == pluginId && $0.itemId == itemId })
            self._menuItems.append(AYGPluginMenuItem(pluginId: pluginId, itemId: itemId, type: menuType, text: text, icon: icon.isEmpty ? nil : icon))
            self.lock.unlock()
        }
        context.setObject(unsafeBitCast(registerMenuBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_register_menu_item" as NSString)

        let unregisterMenuBlock: @convention(block) (String) -> Void = { [weak self] itemId in
            guard let self else {
                return
            }
            self.lock.lock()
            self._menuItems.removeAll(where: { $0.pluginId == pluginId && $0.itemId == itemId })
            self.lock.unlock()
        }
        context.setObject(unsafeBitCast(unregisterMenuBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_unregister_menu_item" as NSString)

        let sendMessageBlock: @convention(block) (String, String, Int, String) -> Void = { [weak self] peer, text, replyTo, thread in
            guard let rawPeerId = Int64(peer), !text.isEmpty else {
                self?.appendLog(id: pluginId, level: 2, text: "sendMessage: invalid peer or empty text")
                return
            }
            let threadId = Int64(thread)
            DispatchQueue.main.async {
                self?.sendMessage(peerId: PeerId(rawPeerId), text: text, replyTo: replyTo > 0 ? Int32(clamping: replyTo) : nil, threadId: threadId)
            }
        }
        context.setObject(unsafeBitCast(sendMessageBlock, to: AnyObject.self), forKeyedSubscript: "__ayg_send_message" as NSString)
    }

    private func storeSetting(pluginId: String, key: String, value: Any?) {
        var dict = AYGSharedDefaults.store.dictionary(forKey: AYGPluginManager.settingsKey(pluginId)) ?? [:]
        if let value, PropertyListSerialization.propertyList(value, isValidFor: .binary) {
            dict[key] = value
        } else {
            dict.removeValue(forKey: key)
        }
        AYGSharedDefaults.store.set(dict, forKey: AYGPluginManager.settingsKey(pluginId))
    }

    private func sendMessage(peerId: PeerId, text: String, replyTo: Int32?, threadId: Int64?) {
        guard let context = self.context else {
            return
        }
        var replySubject: EngineMessageReplySubject?
        if let replyTo {
            replySubject = EngineMessageReplySubject(messageId: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: replyTo), quote: nil, innerSubject: nil)
        }
        let message: EnqueueMessage = .message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: threadId, replyToMessageId: replySubject, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let signal = AYGPluginHooks.withSendHooksBypassed {
            return enqueueMessages(account: context.account, peerId: peerId, messages: [message])
        }
        let _ = signal.startStandalone()
    }

    private func presentBulletin(kind: String, text: String) {
        guard let context = self.context else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let content: UndoOverlayContent
        switch kind {
        case "success":
            content = .succeed(text: text, timeout: nil, customUndoText: nil)
        default:
            content = .info(title: nil, text: text, timeout: nil, customUndoText: nil)
        }
        let controller = UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false })
        context.sharedContext.mainWindow?.present(controller, on: .root)
    }

    // MARK: Hooks

    private func handleSend(_ message: AYGPluginOutgoingMessage) -> AYGPluginSendDecision {
        self.lock.lock()
        let hasHooks = !self._sendHookIds.isEmpty
        self.lock.unlock()
        guard hasHooks, self.isEngineEnabled else {
            return .keep
        }
        return self.runOnQueue {
            var text = message.text
            var changed = false
            for plugin in self.loaded.values.sorted(by: { $0.info.id < $1.info.id }) where plugin.hasSendHook {
                var params: [String: Any] = [
                    "accountId": String(message.accountPeerId.toInt64()),
                    "peer": String(message.peerId.toInt64()),
                    "peerId": String(message.peerId.toInt64()),
                    "text": text,
                    "message": text,
                    "hasMedia": message.hasMedia
                ]
                if let threadId = message.threadId {
                    params["threadId"] = String(threadId)
                }
                if let reply = message.replyToMessageId {
                    params["replyToMessageId"] = Int(reply.id)
                }
                guard let result = plugin.call("send", [params]), result.isObject else {
                    continue
                }
                let strategy = result.objectForKeyedSubscript("strategy")?.toString() ?? ""
                if strategy == "cancel" {
                    self.appendLog(id: plugin.info.id, level: 0, text: "Cancelled an outgoing message")
                    return .cancel
                }
                if strategy == "modify" || strategy == "modify_final", let newText = result.objectForKeyedSubscript("text")?.toString() {
                    if newText != text {
                        text = newText
                        changed = true
                    }
                    if strategy == "modify_final" {
                        break
                    }
                }
            }
            return changed ? .replace(text: text) : .keep
        }
    }

    private func handleIncoming(_ messages: [AYGPluginIncomingMessage]) {
        self.lock.lock()
        let hasHooks = !self._incomingHookIds.isEmpty
        self.lock.unlock()
        guard hasHooks else {
            return
        }
        let payload: [[String: Any]] = messages.map { message in
            var item: [String: Any] = [
                "accountId": String(message.accountPeerId.toInt64()),
                "peerId": String(message.id.peerId.toInt64()),
                "messageId": Int(message.id.id),
                "date": Int(message.timestamp),
                "text": message.text,
                "isOutgoing": message.isOutgoing,
                "hasMedia": message.hasMedia
            ]
            if let authorId = message.authorId {
                item["fromId"] = String(authorId.toInt64())
            }
            if let threadId = message.threadId {
                item["threadId"] = String(threadId)
            }
            return item
        }
        self.queue.async {
            for plugin in self.loaded.values.sorted(by: { $0.info.id < $1.info.id }) where plugin.hasIncomingHook {
                _ = plugin.call("incoming", [payload])
            }
        }
    }

    // MARK: Settings

    public func settingsItems(id: String) -> [AYGPluginSettingItem] {
        return self.runOnQueue {
            guard let plugin = self.loaded[id], let value = plugin.call("settings"), let array = value.toArray() as? [[String: Any]] else {
                return []
            }
            var result: [AYGPluginSettingItem] = []
            for item in array {
                let text = item["text"] as? String ?? ""
                let key = item["key"] as? String ?? ""
                let subtext = (item["subtext"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                switch item["type"] as? String {
                case "header":
                    result.append(.header(text: text))
                case "divider":
                    result.append(.divider(text: (item["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
                case "switch":
                    result.append(.toggle(key: key, text: text, subtext: subtext, defaultValue: item["default"] as? Bool ?? false))
                case "input":
                    result.append(.input(key: key, text: text, subtext: subtext, defaultValue: item["default"] as? String ?? ""))
                case "selector":
                    let items = item["items"] as? [String] ?? []
                    result.append(.selector(key: key, text: text, items: items, defaultValue: (item["default"] as? NSNumber)?.intValue ?? 0))
                case "text":
                    result.append(.text(index: (item["index"] as? NSNumber)?.intValue ?? 0, text: text, isAccent: item["accent"] as? Bool ?? false, isDestructive: item["red"] as? Bool ?? false))
                default:
                    break
                }
            }
            return result
        }
    }

    public func settingValue(id: String, key: String) -> Any? {
        return AYGSharedDefaults.store.dictionary(forKey: AYGPluginManager.settingsKey(id))?[key]
    }

    public func setSettingValue(id: String, key: String, value: Any) {
        self.storeSetting(pluginId: id, key: key, value: value)
        self.queue.async {
            _ = self.loaded[id]?.call("settingChanged", [key, value])
        }
        self.notifyUpdated()
    }

    public func textItemTapped(id: String, index: Int) {
        self.queue.async {
            _ = self.loaded[id]?.call("textClicked", [index])
            self.notifyUpdated()
        }
    }

    // MARK: Menu items

    public func menuItems(type: AYGPluginMenuType) -> [AYGPluginMenuItem] {
        guard self.isEngineEnabled else {
            return []
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._menuItems.filter { $0.type == type }
    }

    public func menuItemTapped(_ item: AYGPluginMenuItem, message: Message) {
        var payload: [String: Any] = [
            "accountId": String(self.context?.account.peerId.toInt64() ?? 0),
            "peerId": String(message.id.peerId.toInt64()),
            "messageId": Int(message.id.id),
            "date": Int(message.timestamp),
            "text": message.text,
            "isOutgoing": !message.flags.contains(.Incoming),
            "hasMedia": !message.media.isEmpty
        ]
        if let author = message.author {
            payload["fromId"] = String(author.id.toInt64())
        }
        if let threadId = message.threadId {
            payload["threadId"] = String(threadId)
        }
        self.queue.async {
            _ = self.loaded[item.pluginId]?.call("menuClicked", [item.itemId, payload])
        }
    }

    private func removeMenuItems(pluginId: String) {
        self.lock.lock()
        self._menuItems.removeAll(where: { $0.pluginId == pluginId })
        self.lock.unlock()
    }

    // MARK: Logs

    private func appendLog(id: String, level: Int, text: String) {
        self.lock.lock()
        var entries = self._logs[id] ?? []
        entries.append(AYGPluginLogEntry(date: Date(), level: level, text: text))
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
        self._logs[id] = entries
        self.lock.unlock()
        #if DEBUG
        print("[AYG plugin \(id)] \(text)")
        #endif
    }

    public func logText(id: String) -> String {
        self.lock.lock()
        let entries = self._logs[id] ?? []
        self.lock.unlock()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { entry in
            let level = entry.level >= 2 ? "E" : (entry.level == 1 ? "W" : "I")
            return "\(formatter.string(from: entry.date)) \(level) \(entry.text)"
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    private func runOnQueue<T>(_ f: () -> T) -> T {
        if DispatchQueue.getSpecific(key: self.queueKey) == true {
            return f()
        }
        return self.queue.sync(execute: f)
    }

    private func notifyUpdated() {
        DispatchQueue.main.async {
            self.updatesCounter += 1
            self.updatesPromise.set(self.updatesCounter)
        }
    }
}
