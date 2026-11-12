// Asks the app's extension for the codes of the tab's website. The website is the one Safari says the tab shows,
// never one the page names, so a page can't ask for another website's codes.
browser.runtime.onMessage.addListener((message, sender) => {
    if (message?.type !== "codes") {
        return undefined;
    }
    let host = "";
    try {
        const url = new URL(sender.tab?.url ?? sender.url ?? "");
        if (url.protocol === "https:") {
            host = url.hostname;
        }
    } catch {
        host = "";
    }
    if (!host) {
        return Promise.resolve({ error: "noWebsite" });
    }
    return browser.runtime.sendNativeMessage("io.github.sinf-ken.OrielOTP", { host });
});
