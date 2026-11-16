// Pupka for macOS - test hooks, active only when PUPKA_DEBUG names a folder: console output goes to console.log there, cmd.js is run in the page and answered in out.json, a file named shot produces shot.png.
import AppKit
import WebKit

final class DebugHooks: NSObject, WKScriptMessageHandler {
    private let dir: URL
    private weak var web: WKWebView?
    private var timer: Timer?

    static func folder() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["PUPKA_DEBUG"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("console.log").path, contents: nil)
    }

    func install(in cfg: WKWebViewConfiguration) {
        let source = """
        (function () {
          const send = (level, args) => { try { window.webkit.messageHandlers.pupkaLog.postMessage(level + " " + args.map((x) => { try { return typeof x === "string" ? x : (x && x.stack) || JSON.stringify(x); } catch (e) { return String(x); } }).join(" ")); } catch (e) {} };
          ["log", "warn", "error"].forEach((level) => { const orig = console[level]; console[level] = function () { send(level, [].slice.call(arguments)); orig.apply(console, arguments); }; });
          window.addEventListener("error", (e) => send("ERROR", [e.message, (e.filename || "") + ":" + e.lineno]));
          window.addEventListener("unhandledrejection", (e) => send("REJECT", [(e.reason && (e.reason.stack || e.reason.message)) || String(e.reason)]));
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.add(self, name: "pupkaLog")
    }

    func attach(_ web: WKWebView) {
        self.web = web
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let line = message.body as? String, let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent("console.log")) else { return }
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        try? handle.close()
    }

    private func poll() {
        guard let web = web else { return }
        let fm = FileManager.default
        let cmd = dir.appendingPathComponent("cmd.js"), shot = dir.appendingPathComponent("shot"), out = dir.appendingPathComponent("out.json")
        if fm.fileExists(atPath: shot.path) {
            try? fm.removeItem(at: shot)
            web.takeSnapshot(with: nil) { [dir] image, _ in
                guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: dir.appendingPathComponent("shot.png"), options: .atomic)
            }
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("quit").path) {
            try? fm.removeItem(at: dir.appendingPathComponent("quit"))
            NSApp.terminate(nil)
            return
        }
        guard let code = try? String(contentsOf: cmd, encoding: .utf8) else { return }
        try? fm.removeItem(at: cmd)
        web.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { result in
            var payload: [String: Any]
            switch result {
            case .success(let value): payload = ["ok": true, "value": JSONSerialization.isValidJSONObject([value]) ? value : String(describing: value)]
            case .failure(let error): payload = ["ok": false, "error": String(describing: error)]
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])) ?? Data("{\"ok\":false}".utf8)
            try? data.write(to: out, options: .atomic)
        }
    }
}
