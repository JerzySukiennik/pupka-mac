// Pupka for macOS - calls from the web app: read and write note files, save and fetch pictures, model status, Finder.
import AppKit
import WebKit

final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    private let store: NoteStore
    private let model: LocalModel

    init(store: NoteStore, model: LocalModel) {
        self.store = store
        self.model = model
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return replyHandler(nil, "Złe wywołanie.") }
        let answer: (Result<Any?, Error>) -> Void = { result in
            switch result {
            case .success(let value): replyHandler(value ?? NSNull(), nil)
            case .failure(let error): replyHandler(nil, error.localizedDescription)
            }
        }
        let store = self.store

        switch op {
        case "store.readIndex":
            store.run({ try store.readIndex() as Any? }, done: answer)
        case "store.writeIndex":
            let y = body["ydoc"] as? String ?? ""
            store.run({ try store.writeIndex(y); return true as Any? }, done: answer)
        case "store.readCard":
            let id = body["id"] as? String ?? ""
            store.run({ try store.readCard(id) as Any? }, done: answer)
        case "store.writeCard":
            let id = body["id"] as? String ?? ""
            let y = body["ydoc"] as? String ?? ""
            let meta = CardMeta(body["meta"] as? [String: Any] ?? [:])
            guard !id.isEmpty, !y.isEmpty else { return replyHandler(nil, "Pusta karta.") }
            store.run({ try store.writeCard(id, meta, y); return true as Any? }, done: answer)
        case "store.reconcile":
            var cards: [String: CardMeta] = [:]
            for (id, raw) in body["cards"] as? [String: Any] ?? [:] { cards[id] = CardMeta(raw as? [String: Any] ?? [:]) }
            store.run({ try store.reconcile(cards); return true as Any? }, done: answer)
        case "store.ids":
            store.run({ try store.knownIds() as Any? }, done: answer)
        case "media.save":
            guard let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else { return replyHandler(nil, "Zły obrazek.") }
            let name = store.newMediaName(ext: body["ext"] as? String ?? "jpg")
            store.run({ try store.saveMedia(name, data); return ("pupka://app/media/" + name) as Any? }, done: answer)
        case "media.ensure":
            ensureMedia(body["names"] as? [String] ?? [], answer)
        case "model.status":
            replyHandler(["label": LocalModel.label, "hasModel": model.hasModel, "running": model.isRunning, "threads": model.threads], nil)
        case "model.threads":
            model.setThreads(body["n"] as? Int ?? 2)
            replyHandler(model.threads, nil)
        case "model.stop":
            model.stop()
            replyHandler(true, nil)
        case "app.reveal":
            try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.root)
            replyHandler(true, nil)
        case "app.open":
            if let s = body["url"] as? String, let url = URL(string: s), url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
            replyHandler(true, nil)
        case "app.info":
            replyHandler(["folder": store.root.path, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""], nil)
        default:
            replyHandler(nil, "Nieznane wywołanie: \(op)")
        }
    }

    private func ensureMedia(_ names: [String], _ answer: @escaping (Result<Any?, Error>) -> Void) {
        let store = self.store
        let missing = names.filter { !$0.hasPrefix("local/") && store.mediaFile($0) != nil && !store.hasMedia($0) }
        if missing.isEmpty { return answer(.success(["fetched": 0, "failed": 0])) }
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 4)
        let lock = NSLock()
        var fetched = 0, failed = 0
        DispatchQueue.global(qos: .utility).async {
            for name in missing {
                guard let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: SchemeHandler.apiBase + "/media/" + escaped) else { continue }
                gate.wait()
                group.enter()
                URLSession.shared.dataTask(with: url) { data, resp, _ in
                    let ok = data != nil && (resp as? HTTPURLResponse)?.statusCode == 200 && (try? store.saveMedia(name, data!)) != nil
                    lock.lock()
                    if ok { fetched += 1 } else { failed += 1 }
                    lock.unlock()
                    gate.signal()
                    group.leave()
                }.resume()
            }
            group.notify(queue: .main) { answer(.success(["fetched": fetched, "failed": failed])) }
        }
    }
}
