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

    /// 브라우저에 결과 페이지를 돌려주고 닫는다. `service`는 "구글 드라이브" · "노션"처럼 페이지 안내에 쓴다.
    public func respond(success: Bool, message: String, service: String? = nil) {
        let html = Self.resultPage(success: success, message: message, service: service)
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

    /// 로그인 결과 페이지. 지금 앱 아이콘(흰 메모 카드 · 먹색 줄 · 라임 점 · 빗금 친 점선 카드)과 같은 결로 그린다.
    /// 라임 점이 체크 표시가 된다. 밖에서 아무것도 불러오지 않는다. 라이트 · 다크 둘 다.
    public static func resultPage(success: Bool, message: String, service: String?) -> String {
        let title = success ? "로그인했습니다" : "로그인하지 못했습니다"
        let next: String
        if success {
            let what = service.map { "\(escape($0)) 연결이 끝났습니다. " } ?? ""
            next = "\(what)MDemo로 돌아가면 이어서 진행합니다. 이 탭은 닫아도 됩니다."
        } else {
            next = "MDemo 메뉴에서 다시 로그인해 주세요."
        }
        let detail = success || message.isEmpty ? "" : "<p class=\"err\">\(escape(message))</p>"
        let state = success ? "ok" : "fail"
        let mark = success
            ? ##"<path d="M-6 0.5l4 4L6.5-4.5" fill="none" stroke="#1C1D20" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>"##
            : ##"<path d="M-4.5-4.5l9 9M4.5-4.5l-9 9" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round"/>"##
        return #"""
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>MDemo 로그인</title>
        <style>
        :root{--bg:#EEEFF2;--ink:#1C1D20;--sub:#62646C;--card:#FAFAFA;--hatch:#C9CBD1;--dash:#A7AAB1;--lime:#D4F53C;--red:#D9505A}
        @media (prefers-color-scheme:dark){:root{--bg:#18191B;--ink:#ECEDF0;--sub:#9EA1A9;--hatch:#3A3C42;--dash:#5B5E66;--red:#F0727A}}
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);
          font:16px/1.6 -apple-system,"Apple SD Gothic Neo","Pretendard","Noto Sans KR",sans-serif;padding:24px 16px}
        main{text-align:center;max-width:420px}
        svg.icon{width:168px;height:168px;display:block;margin:0 auto 28px}
        .fail .dot{fill:var(--red)}
        h1{font-size:24px;font-weight:700;letter-spacing:-.01em;margin:0 0 8px}
        p{margin:0;color:var(--sub);word-break:keep-all;text-wrap:balance}
        p.err{margin-top:12px;color:var(--red);font-size:14px}
        .brand{margin-top:40px;font-size:13px;color:var(--sub);display:inline-flex;gap:8px;align-items:center}
        .brand i{width:8px;height:8px;border-radius:50%;background:var(--lime);display:block}
        </style></head>
        <body class="\#(state)"><main>
          <svg class="icon" viewBox="0 0 168 168" aria-hidden="true">
            <defs>
              <pattern id="h" width="9" height="9" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
                <rect width="3" height="9" fill="var(--hatch)"/></pattern>
              <filter id="s" x="-20%" y="-20%" width="140%" height="150%">
                <feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#000" flood-opacity=".16"/></filter>
            </defs>
            <rect x="56" y="22" width="88" height="88" rx="22" fill="url(#h)" stroke="var(--dash)" stroke-width="3" stroke-dasharray="7 6"/>
            <rect x="24" y="50" width="96" height="96" rx="26" fill="var(--card)" filter="url(#s)"/>
            <rect x="44" y="74" width="56" height="8" rx="4" fill="#1C1D20"/>
            <rect x="44" y="92" width="56" height="8" rx="4" fill="#1C1D20"/>
            <rect x="44" y="110" width="26" height="8" rx="4" fill="#1C1D20"/>
            <g transform="translate(88 114)"><circle class="dot" r="12" fill="#D4F53C"/>\#(mark)</g>
          </svg>
          <h1>\#(title)</h1>
          <p>\#(next)</p>\#(detail)
          <div class="brand"><i></i>MDemo</div>
        </main></body></html>
        """#
    }
}
