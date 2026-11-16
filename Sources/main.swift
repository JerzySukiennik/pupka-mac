// Pupka for macOS - one opaque window with the Pupka web app served from the bundle, Polish menus, printing, clean shutdown.
import AppKit
import WebKit
import notify

let ivory = NSColor(srgbRed: 245 / 255, green: 244 / 255, blue: 238 / 255, alpha: 1)

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private let store = NoteStore()
    private let model = LocalModel()
    private lazy var scheme = SchemeHandler(store: store, model: model)
    private lazy var bridge = Bridge(store: store, model: model)
    private var quitting = false
    private var quitToken: Int32 = 0
    private var debug: DebugHooks?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(scheme, forURLScheme: "pupka")
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "pupka")
        cfg.websiteDataStore = ProcessInfo.processInfo.environment["PUPKA_ROOT"] == nil ? .default() : .nonPersistent()
        if let dir = DebugHooks.folder() {
            debug = DebugHooks(dir: dir)
            debug?.install(in: cfg)
        }
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        cfg.preferences.isElementFullscreenEnabled = true

        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.underPageBackgroundColor = ivory
        web.isInspectable = true
        debug?.attach(web)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Pupka"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = ivory
        window.minSize = NSSize(width: 720, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("PupkaMain")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        web.load(URLRequest(url: URL(string: "pupka://app/index.html")!))
        notify_register_dispatch("fun.gzowo.pupka.quit", &quitToken, DispatchQueue.main) { _ in NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        var answered = false
        let finish = { [weak self] in
            if answered { return }
            answered = true
            self?.model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        web.callAsyncJavaScript("if (window.pupkaFlush) { await window.pupkaFlush(); } return true;", arguments: [:], in: nil, in: .page) { _ in finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        return it
    }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            top.submenu = menu
            main.addItem(top)
        }
        add("Pupka", [
            item("O Pupce", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Pobierz nowości z Pupki online", #selector(pullOnline), "r", [.command, .shift]),
            item("Pokaż folder z notatkami", #selector(revealNotes)),
            .separator(),
            item("Ukryj Pupkę", #selector(NSApplication.hide(_:)), "h"),
            item("Ukryj pozostałe", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Pokaż wszystkie", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Zakończ Pupkę", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Plik", [
            item("Drukuj…", #selector(printPage), "p"),
        ])
        add("Edycja", [
            item("Cofnij", #selector(undoWeb)),
            item("Ponów", #selector(redoWeb)),
            .separator(),
            item("Wytnij", #selector(NSText.cut(_:)), "x"),
            item("Kopiuj", #selector(NSText.copy(_:)), "c"),
            item("Wklej", #selector(NSText.paste(_:)), "v"),
            item("Zaznacz wszystko", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("Widok", [
            item("Powiększ", #selector(zoomIn), "+"),
            item("Pomniejsz", #selector(zoomOut), "-"),
            item("Rzeczywisty rozmiar", #selector(zoomReset), "0"),
            .separator(),
            item("Pełny ekran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        add("Okno", [
            item("Zminimalizuj", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Powiększ okno", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.mainMenu = main
    }

    private func js(_ code: String) { web.evaluateJavaScript(code, completionHandler: nil) }
    private func key(_ k: String, shift: Bool) {
        js("(document.activeElement || document.body).dispatchEvent(new KeyboardEvent('keydown', { key: '\(k)', code: 'Key\(k.uppercased())', metaKey: true, shiftKey: \(shift), bubbles: true, cancelable: true }));")
    }
    @objc private func undoWeb() { key("z", shift: false) }
    @objc private func redoWeb() { key("z", shift: true) }
    @objc private func pullOnline() { js("window.pupkaPull && window.pupkaPull();") }
    @objc private func revealNotes() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.root)
    }
    @objc private func zoomIn() { web.pageZoom = min(2, web.pageZoom + 0.1) }
    @objc private func zoomOut() { web.pageZoom = max(0.6, web.pageZoom - 0.1) }
    @objc private func zoomReset() { web.pageZoom = 1 }

    @objc private func printPage() {
        web.evaluateJavaScript("document.body.classList.add('printing'); true") { [weak self] _, _ in
            guard let self = self else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.topMargin = 0
            info.bottomMargin = 0
            info.leftMargin = 0
            info.rightMargin = 0
            let op = self.web.printOperation(with: info)
            op.view?.frame = self.web.bounds
            op.runModal(for: self.window, delegate: self, didRun: #selector(self.printDone(_:success:contextInfo:)), contextInfo: nil)
        }
    }
    @objc private func printDone(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        js("document.body.classList.remove('printing');")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "pupka" || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return decisionHandler(.allow) }
        if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
        if url.scheme == "https" || url.scheme == "http" || url.scheme == "mailto" { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if url.scheme == "pupka" { webView.load(action.request) }
            else if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Anuluj")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Anuluj")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "pupka" ? .grant : .deny)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
