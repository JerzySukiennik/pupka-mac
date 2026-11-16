// Pupka for macOS - serves pupka://app: the bundled web app, pictures from the notes folder, and streaming proxies to the Pupka API, the board API and the local model.
import Foundation
import WebKit

final class SchemeHandler: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    static let apiBase = "https://pupka-api.kalakasanyt.workers.dev"
    static let boardBase = "https://board-api.kalakasanyt.workers.dev"
    static let siteOrigin = "https://pupka.gzowo.fun"

    private let store: NoteStore
    private let model: LocalModel
    private let webRoot: URL
    private var alive = Set<ObjectIdentifier>()
    private var tasks: [ObjectIdentifier: WKURLSchemeTask] = [:]
    private var running: [ObjectIdentifier: URLSessionTask] = [:]
    private var keys: [Int: ObjectIdentifier] = [:]
    private var started = Set<ObjectIdentifier>()
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 900
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue.main)
    }()

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf", "ico": "image/x-icon", "txt": "text/plain; charset=utf-8",
    ]

    init(store: NoteStore, model: LocalModel) {
        self.store = store
        self.model = model
        self.webRoot = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        alive.insert(key)
        tasks[key] = task
        guard let url = task.request.url else { return send(key, 400, "text/plain", Data()) }
        let path = url.path
        if path.hasPrefix("/proxy/") { proxy(key, url) }
        else if path.hasPrefix("/media/") { media(key, String(path.dropFirst(7))) }
        else { file(key, path) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        running[key]?.cancel()
        forget(key)
    }

    private func forget(_ key: ObjectIdentifier) {
        alive.remove(key)
        tasks[key] = nil
        started.remove(key)
        if let t = running.removeValue(forKey: key) { keys[t.taskIdentifier] = nil }
    }

    private func response(_ key: ObjectIdentifier, _ status: Int, _ headers: [String: String]) -> HTTPURLResponse? {
        guard let url = tasks[key]?.request.url else { return nil }
        var h = headers
        h["Cache-Control"] = "no-store"
        h["Access-Control-Allow-Origin"] = "*"
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)
    }

    private func send(_ key: ObjectIdentifier, _ status: Int, _ type: String, _ data: Data) {
        guard alive.contains(key), let task = tasks[key], let resp = response(key, status, ["Content-Type": type, "Content-Length": String(data.count)]) else { return }
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
        forget(key)
    }

    private func sendError(_ key: ObjectIdentifier, _ status: Int, _ text: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": text])) ?? Data()
        send(key, status, "application/json; charset=utf-8", body)
    }

    private func file(_ key: ObjectIdentifier, _ rawPath: String) {
        var path = rawPath.isEmpty || rawPath == "/" ? "/index.html" : rawPath
        if path.hasSuffix("/") { path += "index.html" }
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains("..") { return send(key, 403, "text/plain", Data()) }
        let url = parts.reduce(webRoot) { $0.appendingPathComponent($1) }
        guard let data = try? Data(contentsOf: url) else { return send(key, 404, "text/plain; charset=utf-8", Data("not found".utf8)) }
        send(key, 200, SchemeHandler.types[url.pathExtension.lowercased()] ?? "application/octet-stream", data)
    }

    private func media(_ key: ObjectIdentifier, _ name: String) {
        guard let local = store.mediaFile(name) else { return send(key, 400, "text/plain", Data()) }
        let type = SchemeHandler.types[local.pathExtension.lowercased()] ?? "application/octet-stream"
        if let data = try? Data(contentsOf: local) { return send(key, 200, type, data) }
        if name.hasPrefix("local/") { return send(key, 404, "text/plain", Data()) }
        guard let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let remote = URL(string: SchemeHandler.apiBase + "/media/" + escaped) else { return send(key, 400, "text/plain", Data()) }
        URLSession.shared.dataTask(with: remote) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return self.send(key, 404, "text/plain", Data()) }
                self.store.run({ try self.store.saveMedia(name, data) }, done: { _ in })
                self.send(key, 200, (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? type, data)
            }
        }.resume()
    }

    private func proxy(_ key: ObjectIdentifier, _ url: URL) {
        let parts = url.path.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return sendError(key, 404, "Nie ma takiej ścieżki.") }
        let rest = (parts.count > 2 ? "/" + parts[2] : "/") + (url.query.map { "?" + $0 } ?? "")
        switch parts[1] {
        case "api":
            forward(key, SchemeHandler.apiBase + rest, origin: SchemeHandler.siteOrigin)
        case "board":
            forward(key, SchemeHandler.boardBase + rest, origin: SchemeHandler.siteOrigin)
        case "llm":
            model.ensure { [weak self] result in
                switch result {
                case .success(let port): self?.forward(key, "http://127.0.0.1:\(port)" + rest, origin: nil)
                case .failure(let error): self?.sendError(key, 503, error.localizedDescription)
                }
            }
        default:
            sendError(key, 404, "Nie ma takiej ścieżki.")
        }
    }

    private func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private func forward(_ key: ObjectIdentifier, _ target: String, origin: String?) {
        guard alive.contains(key), let task = tasks[key], let url = URL(string: target) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = task.request.httpMethod ?? "GET"
        for name in ["Content-Type", "Accept", "x-pupka-name"] {
            if let v = task.request.value(forHTTPHeaderField: name) { req.setValue(v, forHTTPHeaderField: name) }
        }
        if let origin = origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        req.httpBody = body(of: task.request)
        let t = session.dataTask(with: req)
        running[key] = t
        keys[t.taskIdentifier] = key
        t.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let key = keys[dataTask.taskIdentifier], alive.contains(key), let task = tasks[key] {
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            if let type = http?.value(forHTTPHeaderField: "Content-Type") { headers["Content-Type"] = type }
            if let resp = self.response(key, http?.statusCode ?? 200, headers) {
                task.didReceive(resp)
                started.insert(key)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let key = keys[dataTask.taskIdentifier], alive.contains(key), started.contains(key), let task = tasks[key] else { return }
        task.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = keys[task.taskIdentifier] else { return }
        guard alive.contains(key), let schemeTask = tasks[key] else { return forget(key) }
        if let error = error {
            if started.contains(key) {
                schemeTask.didFailWithError(error)
                forget(key)
            } else {
                let offline = (error as NSError).code == NSURLErrorNotConnectedToInternet
                sendError(key, 502, offline ? "Nie ma internetu." : "Brak połączenia z serwerem.")
            }
            return
        }
        schemeTask.didFinish()
        forget(key)
    }
}
