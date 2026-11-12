// Offers a button next to the verification code fields of a page. Clicking it asks for the website's codes and fills
// one in: right away when one account matches, or after choosing from a short list.
(() => {
    const strings = {
        en: { fill: "Fill in code from Oriel OTP", none: "Oriel OTP has no account for this website.", locked: "Oriel OTP is locked. Use the AutoFill suggestion above the keyboard instead.", off: "Turn on AutoFill from Oriel OTP in Settings to use its codes here.", failed: "Oriel OTP couldn't read its accounts. Unlock the device and try again." },
        de: { fill: "Code aus Oriel OTP einsetzen", none: "Oriel OTP hat kein Konto für diese Website.", locked: "Oriel OTP ist gesperrt. Verwende stattdessen den AutoFill-Vorschlag über der Tastatur.", off: "Schalte in den Einstellungen AutoFill von Oriel OTP ein, um seine Codes hier zu verwenden.", failed: "Oriel OTP konnte seine Konten nicht lesen. Entsperre das Gerät und versuche es erneut." },
        fr: { fill: "Remplir le code depuis Oriel OTP", none: "Oriel OTP n’a pas de compte pour ce site.", locked: "Oriel OTP est verrouillé. Utilisez plutôt la suggestion de remplissage automatique au-dessus du clavier.", off: "Activez le remplissage automatique depuis Oriel OTP dans Réglages pour utiliser ses codes ici.", failed: "Oriel OTP n’a pas pu lire ses comptes. Déverrouillez l’appareil et réessayez." },
        ja: { fill: "Oriel OTPのコードを入力", none: "Oriel OTPにこのWebサイトのアカウントがありません。", locked: "Oriel OTPはロックされています。キーボードの上の自動入力の候補を使ってください。", off: "ここでコードを使うには、設定でOriel OTPからの自動入力をオンにしてください。", failed: "Oriel OTPがアカウントを読み込めませんでした。デバイスのロックを解除してもう一度お試しください。" },
        sk: { fill: "Vyplniť kód z Oriel OTP", none: "Oriel OTP nemá účet pre túto webovú stránku.", locked: "Oriel OTP je zamknutý. Použite namiesto toho návrh automatického vypĺňania nad klávesnicou.", off: "Ak chcete používať jeho kódy tu, zapnite v Nastaveniach automatické vypĺňanie z Oriel OTP.", failed: "Oriel OTP nemohol prečítať svoje účty. Odomknite zariadenie a skúste to znova." }
    };
    const language = (navigator.language || "en").slice(0, 2);
    const text = strings[language] ?? strings.en;

    const namePattern = /(one.?time|otp|totp|2fa|mfa|two.?factor|verification.?code|auth(entication)?.?code|security.?code|passcode)/i;

    function isCodeField(input) {
        if (input.dataset.orielOtp || input.disabled || input.readOnly) {
            return false;
        }
        if (input.autocomplete === "one-time-code") {
            return true;
        }
        const type = (input.type || "text").toLowerCase();
        if (!["text", "tel", "number"].includes(type)) {
            return false;
        }
        const name = [input.name, input.id, input.getAttribute("aria-label"), input.placeholder].join(" ");
        return namePattern.test(name);
    }

    function fill(input, code) {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
        setter.call(input, code);
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
        input.focus();
    }

    function message(anchor, string) {
        const note = document.createElement("div");
        note.textContent = string;
        note.setAttribute("role", "status");
        Object.assign(note.style, popupStyle(anchor));
        document.body.append(note);
        setTimeout(() => note.remove(), 4000);
    }

    function popupStyle(anchor) {
        const rect = anchor.getBoundingClientRect();
        return {
            position: "absolute", zIndex: "2147483647", left: `${rect.left + window.scrollX}px`,
            top: `${rect.bottom + window.scrollY + 4}px`, maxWidth: "320px", padding: "8px", borderRadius: "8px",
            background: "Canvas", color: "CanvasText", boxShadow: "0 2px 12px rgba(0,0,0,0.3)",
            font: "14px -apple-system, system-ui, sans-serif"
        };
    }

    function choose(input, accounts) {
        const menu = document.createElement("div");
        menu.setAttribute("role", "menu");
        Object.assign(menu.style, popupStyle(input));
        for (const account of accounts) {
            const item = document.createElement("button");
            item.type = "button";
            item.setAttribute("role", "menuitem");
            item.textContent = account.subtitle ? `${account.title} (${account.subtitle})` : account.title;
            Object.assign(item.style, { display: "block", width: "100%", textAlign: "start", padding: "6px", border: "0", background: "transparent", color: "inherit", font: "inherit", cursor: "pointer" });
            item.addEventListener("click", () => {
                fill(input, account.code);
                menu.remove();
            });
            menu.append(item);
        }
        document.body.append(menu);
        menu.querySelector("button")?.focus();
        const close = (event) => {
            if (!menu.contains(event.target)) {
                menu.remove();
                document.removeEventListener("mousedown", close, true);
            }
        };
        document.addEventListener("mousedown", close, true);
        menu.addEventListener("keydown", (event) => {
            if (event.key === "Escape") {
                menu.remove();
                input.focus();
            }
        });
    }

    async function offerCode(input) {
        let response;
        try {
            response = await browser.runtime.sendMessage({ type: "codes" });
        } catch {
            response = { error: "unavailable" };
        }
        const accounts = response?.accounts ?? [];
        if (response?.error === "locked") {
            message(input, text.locked);
        } else if (response?.error === "noAccounts") {
            message(input, text.off);
        } else if (response?.error) {
            message(input, text.failed);
        } else if (accounts.length === 0) {
            message(input, text.none);
        } else if (accounts.length === 1) {
            fill(input, accounts[0].code);
        } else {
            choose(input, accounts);
        }
    }

    function attach(input) {
        input.dataset.orielOtp = "1";
        const button = document.createElement("button");
        button.type = "button";
        button.title = text.fill;
        button.setAttribute("aria-label", text.fill);
        button.textContent = "🔑";
        Object.assign(button.style, {
            position: "absolute", zIndex: "2147483646", width: "28px", height: "28px", padding: "0", border: "0",
            borderRadius: "14px", background: "transparent", cursor: "pointer", fontSize: "16px", lineHeight: "28px"
        });
        const place = () => {
            const rect = input.getBoundingClientRect();
            button.style.left = `${rect.right + window.scrollX - 32}px`;
            button.style.top = `${rect.top + window.scrollY + (rect.height - 28) / 2}px`;
            button.style.display = rect.width > 0 && rect.height > 0 ? "block" : "none";
        };
        place();
        window.addEventListener("resize", place);
        window.addEventListener("scroll", place, true);
        button.addEventListener("click", (event) => {
            event.preventDefault();
            offerCode(input);
        });
        document.body.append(button);
    }

    function scan(root) {
        root.querySelectorAll?.("input").forEach((input) => {
            if (isCodeField(input)) {
                attach(input);
            }
        });
    }

    scan(document);
    new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            mutation.addedNodes.forEach((node) => {
                if (node.nodeType === Node.ELEMENT_NODE) {
                    if (node.tagName === "INPUT" && isCodeField(node)) {
                        attach(node);
                    } else {
                        scan(node);
                    }
                }
            });
        }
    }).observe(document.documentElement, { childList: true, subtree: true });
})();
