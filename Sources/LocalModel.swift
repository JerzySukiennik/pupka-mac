// Pupka for macOS - the local model: a llama.cpp server started on demand on two CPU threads at low priority, asleep when idle, gone when the app quits.
import Foundation

final class LocalModel {
    static let fileName = "gemma-4-E4B_q4_0-it.gguf"
    static let sharedName = "gemma-4-E4B-it-Q4_K_M.gguf"
    static let label = "Gemma 4 E4B"

    private var process: Process?
    private var port = 0
    private var ready = false
    private var waiters: [(Result<Int, Error>) -> Void] = []
    private var pollTimer: Timer?
    private var deadline = Date()

    var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pupka", isDirectory: true)
    }
    var modelURL: URL {
        let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gzowo-concierge/local/models/" + LocalModel.sharedName)
        if FileManager.default.fileExists(atPath: shared.path) { return shared }
        return supportDir.appendingPathComponent("models", isDirectory: true).appendingPathComponent(LocalModel.fileName)
    }
    var hasModel: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    var isRunning: Bool { process?.isRunning == true && ready }
    var threads: Int {
        let v = UserDefaults.standard.integer(forKey: "llmThreads")
        return v >= 1 && v <= 8 ? v : 2
    }

    func setThreads(_ n: Int) {
        UserDefaults.standard.set(max(1, min(8, n)), forKey: "llmThreads")
        stop()
    }

    private func fail(_ text: String) -> NSError {
        NSError(domain: "Pupka", code: 10, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 28417 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return 28417 }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    func ensure(_ done: @escaping (Result<Int, Error>) -> Void) {
        if isRunning { return done(.success(port)) }
        waiters.append(done)
        if process != nil { return }
        guard hasModel else { return finish(.failure(fail("Nie ma jeszcze pliku modelu lokalnego (\(LocalModel.label)).") )) }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("llama", isDirectory: true) else { return finish(.failure(fail("Brak silnika modelu w aplikacji."))) }
        let exe = dir.appendingPathComponent("llama-server")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return finish(.failure(fail("Brak silnika modelu w aplikacji."))) }

        port = freePort()
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let log = supportDir.appendingPathComponent("model.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = exe
        p.currentDirectoryURL = dir
        let t = String(threads), batch = String(min(4, threads + 2))
        p.arguments = ["-m", modelURL.path, "--host", "127.0.0.1", "--port", String(port), "-t", t, "-tb", batch, "-c", "8192", "-np", "1", "-ngl", "0", "--poll", "0", "--reasoning", "off", "--no-webui", "--offline", "--sleep-idle-seconds", "300", "--temp", "0.5", "--top-p", "0.9"]
        p.qualityOfService = .utility
        if let handle = try? FileHandle(forWritingTo: log) {
            p.standardOutput = handle
            p.standardError = handle
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasStarting = !self.ready
                self.process = nil
                self.ready = false
                self.pollTimer?.invalidate()
                if wasStarting { self.finish(.failure(self.fail("Model lokalny nie wystartował."))) }
            }
        }
        do { try p.run() } catch { return finish(.failure(fail("Nie udało się uruchomić modelu lokalnego."))) }
        process = p
        ready = false
        deadline = Date().addingTimeInterval(240)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard process != nil, !ready else { return }
        if Date() > deadline {
            stop()
            return finish(.failure(fail("Model lokalny ładował się zbyt długo.")))
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async {
                guard let self = self, self.process != nil, !self.ready else { return }
                self.ready = true
                self.pollTimer?.invalidate()
                self.finish(.success(self.port))
            }
        }.resume()
    }

    private func finish(_ result: Result<Int, Error>) {
        let list = waiters
        waiters = []
        for w in list { w(result) }
    }

    func stop() {
        pollTimer?.invalidate()
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        ready = false
    }
}
