import Foundation
import Network

/**
 An authenticated relay in front of the local proxy (port 8317), meant to be
 exposed through a Cloudflare quick tunnel so tools that cannot reach
 localhost (e.g. Cursor) can use VibeProxy.

 Every request must carry `Authorization: Bearer <api key>`. Authorized
 requests are forwarded to the local proxy with the dummy local key, so all
 providers and models available on 8317 work through the relay. Chat
 completion requests for "-extra" alias models are rewritten via
 CursorRelayAliasMapper, and /v1/models responses get the aliases injected.
 */
class CursorRelayServer {
    let listenPort: UInt16
    private let targetHost = "127.0.0.1"
    private let targetPort: UInt16 = 8317
    private var listener: NWListener?
    private(set) var isRunning = false
    private let stateQueue = DispatchQueue(label: "io.automaze.vibeproxy.cursor-relay-state")

    /// The Bearer key required on incoming requests. Set before start().
    var apiKey: String = ""

    init(listenPort: UInt16 = 8319) {
        self.listenPort = listenPort
    }

    func start() {
        guard !isRunning else {
            NSLog("[CursorRelay] Already running")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback only — the tunnel connects locally; nothing else should.
            guard let port = NWEndpoint.Port(rawValue: listenPort) else {
                NSLog("[CursorRelay] Invalid port: %d", listenPort)
                return
            }
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self?.isRunning = true
                    }
                    NSLog("[CursorRelay] Listening on 127.0.0.1:\(self?.listenPort ?? 0)")
                case .failed(let error):
                    NSLog("[CursorRelay] Failed: \(error)")
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                case .cancelled:
                    NSLog("[CursorRelay] Cancelled")
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                self?.receiveNextChunk(from: connection, accumulated: Data())
            }

            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            NSLog("[CursorRelay] Failed to start: \(error)")
        }
    }

    func stop() {
        stateQueue.sync {
            guard isRunning else { return }
            listener?.cancel()
            listener = nil
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
            }
            NSLog("[CursorRelay] Stopped")
        }
    }

    // MARK: - Request receiving

    private func receiveNextChunk(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data = data, !data.isEmpty {
                buffer.append(data)
            }

            if let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEndRange.lowerBound)
                let bodySoFar = buffer.subdata(in: headerEndRange.upperBound..<buffer.endIndex)
                let headerText = String(decoding: headerData, as: UTF8.self)

                let expectedBodyLength = Self.contentLength(inHeader: headerText)
                if bodySoFar.count < expectedBodyLength && !isComplete {
                    self.receiveNextChunk(from: connection, accumulated: buffer)
                    return
                }

                self.handleRequest(headerText: headerText, body: bodySoFar, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveNextChunk(from: connection, accumulated: buffer)
            }
        }
    }

    private static func contentLength(inHeader headerText: String) -> Int {
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let lowered = line.lowercased()
            guard lowered.hasPrefix("content-length:") else { continue }
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            return Int(value) ?? 0
        }
        return 0
    }

    // MARK: - Request handling

    private func handleRequest(headerText: String, body: Data, connection: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendJSONResponse(to: connection, statusCode: 400, reason: "Bad Request",
                             jsonBody: Self.errorBody(message: "Invalid request", type: "relay_error"))
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            sendJSONResponse(to: connection, statusCode: 400, reason: "Bad Request",
                             jsonBody: Self.errorBody(message: "Invalid request line", type: "relay_error"))
            return
        }

        let method = parts[0]
        let path = parts[1]
        let httpVersion = parts[2]

        // Collect headers while preserving original casing
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let authorization = headers.first(where: { $0.0.lowercased() == "authorization" })?.1 ?? ""
        guard !apiKey.isEmpty, authorization == "Bearer \(apiKey)" else {
            NSLog("[CursorRelay] Rejected unauthorized request: %@ %@", method, path)
            sendJSONResponse(to: connection, statusCode: 401, reason: "Unauthorized",
                             jsonBody: Self.errorBody(message: "Unauthorized", type: "auth_error"))
            return
        }

        if method == "OPTIONS" {
            sendPreflight(to: connection)
            return
        }

        NSLog("[CursorRelay] -> %@ %@ (%d bytes)", method, path, body.count)

        if method == "GET" && (path == "/v1/models" || path.hasPrefix("/v1/models?")) {
            forwardModelsRequest(path: path, connection: connection)
            return
        }

        var forwardBody = body
        if method == "POST" && path.contains("/chat/completions") {
            forwardBody = CursorRelayAliasMapper.rewriteChatBody(body)
        }

        forwardRequest(method: method, path: path, version: httpVersion, headers: headers, body: forwardBody, clientConnection: connection)
    }

    // MARK: - /v1/models (buffered so aliases can be injected)

    private func forwardModelsRequest(path: String, connection: NWConnection) {
        guard let url = URL(string: "http://\(targetHost):\(targetPort)\(path)") else {
            sendJSONResponse(to: connection, statusCode: 502, reason: "Bad Gateway",
                             jsonBody: Self.errorBody(message: "Invalid upstream URL", type: "relay_error"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer dummy-not-used", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, let data = data else {
                self.sendJSONResponse(to: connection, statusCode: 502, reason: "Bad Gateway",
                                      jsonBody: Self.errorBody(message: error?.localizedDescription ?? "Upstream unavailable", type: "relay_error"))
                return
            }

            let payload = http.statusCode == 200 ? CursorRelayAliasMapper.injectAliases(intoModelsResponse: data) : data
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            self.sendRawResponse(to: connection, statusCode: http.statusCode, reason: "OK", contentType: contentType, body: payload)
        }.resume()
    }

    // MARK: - Generic forwarding (streams responses back as-is)

    private func forwardRequest(method: String, path: String, version: String, headers: [(String, String)], body: Data, clientConnection: NWConnection) {
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            sendJSONResponse(to: clientConnection, statusCode: 502, reason: "Bad Gateway",
                             jsonBody: Self.errorBody(message: "Invalid upstream port", type: "relay_error"))
            return
        }

        // Build the forwarded request up front; only the auth header changes.
        var head = "\(method) \(path) \(version)\r\n"
        let excludedHeaders: Set<String> = [
            "host", "content-length", "connection", "authorization",
            "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailer", "transfer-encoding", "upgrade"
        ]
        for (name, value) in headers where !excludedHeaders.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Host: \(targetHost):\(targetPort)\r\n"
        head += "Authorization: Bearer dummy-not-used\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        let upstream = NWConnection(to: .hostPort(host: NWEndpoint.Host(targetHost), port: port), using: .tcp)

        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                upstream.send(content: payload, completion: .contentProcessed { error in
                    if error != nil {
                        upstream.cancel()
                        clientConnection.cancel()
                        return
                    }
                    self?.pipe(from: upstream, to: clientConnection)
                })
            case .failed(let error):
                NSLog("[CursorRelay] Upstream connection failed: \(error)")
                self?.sendJSONResponse(to: clientConnection, statusCode: 502, reason: "Bad Gateway",
                                       jsonBody: Self.errorBody(message: "Local proxy unavailable", type: "relay_error"))
                upstream.cancel()
            default:
                break
            }
        }

        upstream.start(queue: .global(qos: .userInitiated))
    }

    /// Streams upstream response bytes to the client until the upstream closes.
    private func pipe(from upstream: NWConnection, to client: NWConnection) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                client.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete || error != nil {
                        upstream.cancel()
                        client.cancel()
                    } else {
                        self?.pipe(from: upstream, to: client)
                    }
                })
            } else if isComplete || error != nil {
                upstream.cancel()
                client.cancel()
            } else {
                self?.pipe(from: upstream, to: client)
            }
        }
    }

    // MARK: - Responses

    private static func errorBody(message: String, type: String) -> Data {
        let json: [String: Any] = ["error": ["message": message, "type": type]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private func sendPreflight(to connection: NWConnection) {
        let head = "HTTP/1.1 204 No Content\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Headers: *\r\n"
            + "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJSONResponse(to connection: NWConnection, statusCode: Int, reason: String, jsonBody: Data) {
        sendRawResponse(to: connection, statusCode: statusCode, reason: reason, contentType: "application/json", body: jsonBody)
    }

    private func sendRawResponse(to connection: NWConnection, statusCode: Int, reason: String, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
