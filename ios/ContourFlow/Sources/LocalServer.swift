import Foundation
import Network

/// Serves the bundled web app over a loopback-only HTTP port.
///
/// WKWebView does not treat `file://` as a secure context, so
/// `navigator.mediaDevices` does not exist there. `http://127.0.0.1:<port>`
/// *is* a secure context, which is why the page is loaded from here.
final class LocalServer {

    enum ServerError: LocalizedError {
        case missingPort

        var errorDescription: String? {
            "The local server did not report a port."
        }
    }

    private final class Flag {
        var isSet = false
    }

    private let root: URL
    private let queue = DispatchQueue(label: "com.contourflow.localserver")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    init(root: URL) {
        self.root = root
    }

    /// Starts the server, preferring a loopback-only socket and falling back to
    /// an all-interfaces socket if the system refuses the loopback bind.
    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        attemptStart(loopbackOnly: true) { [weak self] result in
            if case .success = result {
                completion(result)
            } else {
                self?.attemptStart(loopbackOnly: false, completion: completion)
            }
        }
    }

    private func attemptStart(loopbackOnly: Bool,
                              completion: @escaping (Result<URL, Error>) -> Void) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            completion(.failure(error))
            return
        }

        // Network does not retain the listener for us; keep a strong reference
        // from here on or it can be deallocated before it ever reports .ready.
        self.listener = listener

        let flag = Flag()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !flag.isSet else { return }
            switch state {
            case .ready:
                flag.isSet = true
                guard let port = listener.port,
                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                    completion(.failure(ServerError.missingPort))
                    return
                }
                self.listener = listener
                completion(.success(url))
            case .failed(let error):
                flag.isSet = true
                listener.cancel()
                completion(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, buffer: Data())
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.cancel()
    }

    private func receive(on connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            if error != nil || buffer.count > 128 * 1024 {
                self.close(id)
                return
            }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(header: header, id: id)
            } else if isComplete {
                self.close(id)
            } else {
                self.receive(on: connection, id: id, buffer: buffer)
            }
        }
    }

    // MARK: - Responses

    private func respond(header: String, id: UUID) {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        let method = request.count > 0 ? String(request[0]) : "GET"
        let target = request.count > 1 ? String(request[1]) : "/"

        guard method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed",
                 body: Data("Method Not Allowed".utf8),
                 contentType: "text/plain; charset=utf-8",
                 includeBody: false,
                 id: id)
            return
        }

        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? "/"

        guard let fileURL = resolve(path: path), let body = try? Data(contentsOf: fileURL) else {
            send(status: "404 Not Found",
                 body: Data("Not Found".utf8),
                 contentType: "text/plain; charset=utf-8",
                 includeBody: method != "HEAD",
                 id: id)
            return
        }

        send(status: "200 OK",
             body: body,
             contentType: contentType(for: fileURL.pathExtension),
             includeBody: method != "HEAD",
             id: id)
    }

    private func resolve(path: String) -> URL? {
        var requested = path
        if requested.isEmpty || requested == "/" {
            requested = "/contourflow.html"
        }

        let decoded = requested.removingPercentEncoding ?? requested
        let components = decoded.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !components.isEmpty else { return nil }

        let fileURL = components.reduce(root) { $0.appendingPathComponent($1) }
        let base = root.standardizedFileURL.path
        guard fileURL.standardizedFileURL.path.hasPrefix(base) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return fileURL
    }

    private func send(status: String,
                      body: Data,
                      contentType: String,
                      includeBody: Bool,
                      id: UUID) {
        guard let connection = connections[id] else { return }

        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        var payload = Data(head.utf8)
        if includeBody {
            payload.append(body)
        }

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close(id)
        })
    }

    private func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "woff2": return "font/woff2"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4", "webm": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
