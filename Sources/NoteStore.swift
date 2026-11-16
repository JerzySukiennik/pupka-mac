// Pupka for macOS - notes as files: one .pupka file per card in Documents/Szkoła/Pupka/<Przedmiot>/, the index in Pupka.spis, pictures in Obrazki/.
import Foundation

struct CardMeta {
    var subject = ""
    var title = ""
    var date = ""
    var kind = "lesson"
    var owner = ""
    var name = ""
    var text = ""
    var deleted = false

    init(_ d: [String: Any]) {
        subject = d["subject"] as? String ?? ""
        title = d["title"] as? String ?? ""
        date = d["date"] as? String ?? ""
        kind = d["kind"] as? String ?? "lesson"
        owner = d["owner"] as? String ?? ""
        name = d["name"] as? String ?? ""
        text = d["text"] as? String ?? ""
        deleted = d["deleted"] as? Bool ?? false
    }
}

final class NoteStore {
    let root: URL
    let mediaDir: URL
    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "fun.gzowo.pupka.store")
    private var paths: [String: URL] = [:]
    private var scanned = false

    init() {
        if let test = ProcessInfo.processInfo.environment["PUPKA_ROOT"], !test.isEmpty {
            root = URL(fileURLWithPath: test, isDirectory: true)
        } else {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            root = docs.appendingPathComponent("Szkoła", isDirectory: true).appendingPathComponent("Pupka", isDirectory: true)
        }
        mediaDir = root.appendingPathComponent("Obrazki", isDirectory: true)
    }

    func run<T>(_ work: @escaping () throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result = Result { try work() }
            DispatchQueue.main.async { done(result) }
        }
    }

    private func prepare() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if scanned { return }
        scanned = true
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "pupka" {
            if let id = headerId(url) { paths[id] = url }
        }
    }

    private func headerId(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 400), let text = String(data: head, encoding: .utf8) ?? String(data: head.prefix(300), encoding: .utf8) else { return nil }
        guard let range = text.range(of: "\"id\":\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func clean(_ s: String, fallback: String, limit: Int = 80) -> String {
        var out = ""
        for ch in s.precomposedStringWithCanonicalMapping {
            if ch == "/" || ch == ":" || ch == "\\" { out.append("-") }
            else if ch.isNewline || ch == "\t" { out.append(" ") }
            else if ch.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) { out.append(ch) }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > limit { out = String(out.prefix(limit)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? fallback : out
    }

    private func desired(_ id: String, _ m: CardMeta) -> URL {
        var dir = root
        if m.deleted { dir = dir.appendingPathComponent("Kosz", isDirectory: true) }
        dir = dir.appendingPathComponent(clean(m.subject, fallback: "Bez przedmiotu"), isDirectory: true)
        var base: String
        if m.kind == "test" {
            dir = dir.appendingPathComponent("Testy", isDirectory: true)
            base = clean(m.name.isEmpty ? m.title : m.name, fallback: "test") + (m.owner.isEmpty ? "" : " (\(clean(m.owner, fallback: "")))")
            if !m.date.isEmpty { base = m.date + " " + base }
        } else {
            base = (m.date.isEmpty ? "" : m.date + " ") + clean(m.title, fallback: "bez tematu")
        }
        var url = dir.appendingPathComponent(base + ".pupka")
        var n = 2
        while fm.fileExists(atPath: url.path), paths[id] != url, headerId(url) != id {
            url = dir.appendingPathComponent("\(base) \(n).pupka")
            n += 1
        }
        return url
    }

    private func place(_ id: String, _ m: CardMeta) throws -> URL {
        let want = desired(id, m)
        if let have = paths[id], have != want, fm.fileExists(atPath: have.path) {
            try fm.createDirectory(at: want.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: have, to: want)
            prune(have.deletingLastPathComponent())
        }
        paths[id] = want
        return want
    }

    private func prune(_ dir: URL) {
        var d = dir
        while d.path.hasPrefix(root.path), d != root, d != mediaDir {
            let items = (try? fm.contentsOfDirectory(atPath: d.path))?.filter { $0 != ".DS_Store" } ?? ["x"]
            if !items.isEmpty { return }
            try? fm.removeItem(at: d)
            d = d.deletingLastPathComponent()
        }
    }

    private func ydoc(in url: URL) throws -> String? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let y = obj["ydoc"] as? String else {
            throw NSError(domain: "Pupka", code: 2, userInfo: [NSLocalizedDescriptionKey: "Plik \(url.lastPathComponent) jest uszkodzony."])
        }
        return y
    }

    private func writeJSON(_ fields: [(String, Any)], to url: URL) throws {
        var parts: [String] = []
        for (key, value) in fields {
            let v = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            parts.append("\"\(key)\":" + String(data: v, encoding: .utf8)!)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("{" + parts.joined(separator: ",\n") + "}\n").data(using: .utf8)!.write(to: url, options: .atomic)
    }

    func readIndex() throws -> String? {
        try prepare()
        return try ydoc(in: root.appendingPathComponent("Pupka.spis"))
    }

    func writeIndex(_ y: String) throws {
        try prepare()
        try writeJSON([("pupka", 1), ("kind", "index"), ("ydoc", y)], to: root.appendingPathComponent("Pupka.spis"))
    }

    func readCard(_ id: String) throws -> String? {
        try prepare()
        guard let url = paths[id] else { return nil }
        return try ydoc(in: url)
    }

    func writeCard(_ id: String, _ meta: CardMeta, _ y: String) throws {
        try prepare()
        let url = try place(id, meta)
        try writeJSON([("id", id), ("pupka", 1), ("kind", meta.kind), ("subject", meta.subject), ("title", meta.title), ("date", meta.date), ("text", meta.text), ("ydoc", y)], to: url)
    }

    func reconcile(_ cards: [String: CardMeta]) throws {
        try prepare()
        for (id, meta) in cards where paths[id] != nil { _ = try place(id, meta) }
    }

    func knownIds() throws -> [String] {
        try prepare()
        return Array(paths.keys)
    }

    func mediaFile(_ name: String) -> URL? {
        let parts = name.split(separator: "/").map(String.init)
        if parts.isEmpty || parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) { return nil }
        return parts.reduce(mediaDir) { $0.appendingPathComponent($1) }
    }

    func hasMedia(_ name: String) -> Bool {
        guard let url = mediaFile(name) else { return false }
        return fm.fileExists(atPath: url.path)
    }

    func saveMedia(_ name: String, _ data: Data) throws {
        guard let url = mediaFile(name) else { throw NSError(domain: "Pupka", code: 3, userInfo: [NSLocalizedDescriptionKey: "Zła nazwa pliku."]) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func newMediaName(ext: String) -> String {
        let safe = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let rand = String(UInt32.random(in: 0..<UInt32.max), radix: 36)
        return "local/\(stamp)-\(rand).\(safe.isEmpty ? "jpg" : safe)"
    }
}
