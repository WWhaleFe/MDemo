import Foundation
import Network

/// 로그인 뒤 브라우저가 돌아오는 주소(127.0.0.1)를 받는 작은 서버.
///
/// 임의 포트 하나를 열고, 첫 요청 하나만 받은 뒤 더 받지 않는다. 5분이 지나면 포기한다.
/// 이 맥 안에서만 닿는 주소라 밖으로 열리지 않는다.
public final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mdemo.loopback")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    public private(set) var port: UInt16 = 0
    /// 브라우저가 요청한 경로(질의 제외). 노션 로그인처럼 경로를 확인해야 할 때 쓴다.
    public private(set) var requestPath: String = ""

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: parameters)
    }

    public var redirectURI: String { "http://127.0.0.1:\(port)" }

    /// 포트를 열고 준비될 때까지 기다린다.
    public static func start() async throws -> LoopbackReceiver {
        let receiver = try LoopbackReceiver()
        try await receiver.open()
        return receiver
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func open() async throws {
        let once = Once()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: self?.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: GoogleAuthError.timedOut) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
        self.port = port
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if self.connection != nil {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        lock.unlock()
        // 첫 요청 하나만 받는다.
        listener.cancel()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            if let error {
                self?.deliver(.failure(error))
                return
            }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self?.setRequestPath(Self.parsePath(fromRequest: text))
            self?.deliver(.success(Self.parseQuery(fromRequest: text)))
        }
    }

    private func setRequestPath(_ path: String) {
        lock.lock(); requestPath = path; lock.unlock()
    }

    /// "GET /notion?code=.. HTTP/1.1" 첫 줄에서 경로("/notion")를 뽑는다.
    public static func parsePath(fromRequest request: String) -> String {
        guard let line = request.components(separatedBy: "\r\n").first ?? request.components(separatedBy: "\n").first else { return "" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return "" }
        return components.path
    }

    /// "GET /?code=..&state=.. HTTP/1.1" 첫 줄에서 질의 값을 뽑는다.
    static func parseQuery(fromRequest request: String) -> [String: String] {
        guard let line = request.components(separatedBy: "\r\n").first ?? request.components(separatedBy: "\n").first else { return [:] }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return [:] }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
        return values
    }

    private func deliver(_ result: Result<[String: String], Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
        } else {
            if pending == nil { pending = result }
            lock.unlock()
        }
    }

    /// 브라우저가 돌아올 때까지 기다린다. 시간이 지나면 `timedOut`.
    public func waitForRequest(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending {
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            waiter = continuation
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.deliver(.failure(GoogleAuthError.timedOut))
                self.close()
            }
        }
    }

    /// 브라우저에 결과 페이지를 돌려주고 닫는다.
    public func respond(success: Bool, message: String) {
        let title = success ? "MDemo에 로그인했습니다. 이 창을 닫아도 됩니다." : "로그인하지 못했습니다"
        let detail = success ? "" : "<p>\(Self.escape(message))</p>"
        let html = "<!doctype html><html lang=\"ko\"><head><meta charset=\"utf-8\"><title>MDemo</title></head>"
            + "<body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\"><h2>\(title)</h2>\(detail)</body></html>"
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { close(); return }
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    public func close() {
        listener.cancel()
        lock.lock()
        let connection = self.connection
        lock.unlock()
        connection?.cancel()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
