# AyuGram iOS plugins

Port of exteraGram's plugin system. exteraGram for Android runs Python plugins on
Chaquopy and hooks Java methods; iOS has neither, so AyuGram iOS runs the same plugin
model in **JavaScript** on the system JavaScriptCore.

Settings → AyuGram → **Plugins**: master switch, install from file / clipboard / link,
per-plugin switch, per-plugin page with the plugin's own settings, log, source and delete.

Code: `submodules/AyuGramUI/Sources/AYGPluginEngine.swift` (engine),
`AYGPluginsController.swift` (UI), `submodules/TelegramCore/Sources/AYGPlugins/AYGPluginHooks.swift`
(send / incoming hooks). Full example: [`example.plugin.js`](example.plugin.js).

## File format

One UTF-8 `.js` or `.plugin` file. Metadata is read without running the file, so it must
be plain string literals:

```js
const __id__ = "my_plugin";          // required, 2–64 chars: A-Z a-z 0-9 _ - .
const __name__ = "My Plugin";        // required
const __description__ = "...";
const __author__ = "@ibuybalenciaga";
const __version__ = "1.0.0";
const __min_version__ = "1.0.0";     // minimum plugin engine version
```

Then `class Plugin extends BasePlugin { ... }` (or `registerPlugin(instance)`).

## API

| exteraGram (Python)                         | AyuGram iOS (JS)                                  |
|---------------------------------------------|---------------------------------------------------|
| `on_plugin_load` / `on_plugin_unload`       | `onPluginLoad()` / `onPluginUnload()`             |
| `create_settings()`                         | `createSettings()` → array of items below         |
| `on_send_message_hook(account, params)`     | `onSendMessageHook(params)` (or 2-arg form)       |
| `HookResult(strategy=HookStrategy.MODIFY)`  | `HookResult.modify(params)` / `new HookResult({strategy, params})` |
| `HookStrategy.CANCEL`                       | `HookResult.cancel()`                             |
| `add_menu_item(MenuItemData(...))`          | `addMenuItem({ menuType: MenuItemType.MESSAGE_CONTEXT_MENU, text, icon, onClick(ctx) })` |
| `get_setting` / `set_setting`               | `getSetting(key, default)` / `setSetting(key, value)` |
| `BulletinHelper.show_info/success/error`    | `BulletinHelper.showInfo/showSuccess/showError`   |
| `send_message({"peer":..., "message":...})` | `sendMessage({ peer, message, replyToMessageId, threadId })` |
| `log(...)`                                  | `this.log(...)`, `console.log/warn/error`         |
| `on_update_hook` (new messages)             | `onIncomingMessage(message)` (read-only)          |

snake_case method names are accepted as well, so Python plugins port by syntax only.

Settings items: `Header({text})`, `Switch({key, text, subtext, default, onChange})`,
`Input({key, text, subtext, default, onChange})`, `Selector({key, text, items, default, onChange})`,
`Divider({text})`, `Text({text, accent, red, onClick})`.

`onSendMessageHook` params: `accountId`, `peer`/`peerId`, `message`/`text`, `hasMedia`,
`threadId?`, `replyToMessageId?`. Change `params.message` and return `HookResult.modify(params)`;
`HookStrategy.MODIFY_FINAL` stops later plugins. Returning a string is a shortcut for modify,
`false` for cancel.

`onIncomingMessage` / menu `onClick` context: `accountId`, `peerId`, `messageId`, `date`,
`text`, `isOutgoing`, `hasMedia`, `fromId?`, `threadId?`.

Globals: `AyuGram.name`, `AyuGram.version`, `AyuGram.engineVersion`, `AyuGram.developer`,
`setTimeout` / `clearTimeout`.

Peer and account ids are strings (Telegram's 64-bit ids do not fit in a JS number).

## Limits

* No arbitrary method hooking (no Xposed equivalent on iOS) — only the hooks above.
* Plugins run in the main app only, not in the Share / Notification extensions.
* Send hooks run synchronously before a message is queued: keep them fast.
