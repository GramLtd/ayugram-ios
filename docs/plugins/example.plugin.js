// Example AyuGram iOS plugin (exteraGram plugin format, JavaScript).
// Install: Settings → AyuGram → Plugins → Install from File / Clipboard / Link.

const __id__ = "ayg_example";
const __name__ = "Example";
const __description__ = "Replaces .shrug, adds a \"Message info\" item to the message menu and shows how settings work.";
const __author__ = "@ibuybalenciaga";
const __version__ = "1.0.0";
const __min_version__ = "1.0.0";

class Plugin extends BasePlugin {
    onPluginLoad() {
        this.log("loaded on", AyuGram.name, AyuGram.version);
        this.addMenuItem({
            menuType: MenuItemType.MESSAGE_CONTEXT_MENU,
            text: "Message info",
            icon: "Chat/Context Menu/Info",
            onClick: (ctx) => {
                BulletinHelper.showInfo("Chat " + ctx.peerId + ", message " + ctx.messageId);
            }
        });
    }

    onPluginUnload() {
        this.log("unloaded");
    }

    createSettings() {
        return [
            Header({ text: "Commands" }),
            Switch({ key: "shrug", text: "Replace .shrug", subtext: "Turns \".shrug\" into ¯\\_(ツ)_/¯", default: true }),
            Input({ key: "signature", text: "Signature appended to messages", default: "" }),
            Selector({ key: "case", text: "Text case", items: ["As typed", "UPPERCASE", "lowercase"], default: 0 }),
            Divider({ text: "Messages starting with \"!nosend\" are cancelled." }),
            Text({ text: "Say hello", accent: true, onClick: () => BulletinHelper.showSuccess("Hello from " + __name__ + "!") })
        ];
    }

    onSendMessageHook(params) {
        let text = params.message;
        if (text.startsWith("!nosend")) {
            BulletinHelper.showError("Message cancelled by plugin");
            return HookResult.cancel();
        }
        if (this.getSetting("shrug", true)) {
            text = text.replace(/\.shrug\b/g, "¯\\_(ツ)_/¯");
        }
        const mode = this.getSetting("case", 0);
        if (mode === 1) { text = text.toUpperCase(); }
        if (mode === 2) { text = text.toLowerCase(); }
        const signature = this.getSetting("signature", "");
        if (signature) { text = text + "\n" + signature; }
        if (text === params.message) {
            return HookResult.default();
        }
        params.message = text;
        return HookResult.modify(params);
    }

    onIncomingMessage(message) {
        if (!message.isOutgoing && message.text === "ping") {
            this.log("ping from", message.fromId, "in", message.peerId);
        }
    }
}
