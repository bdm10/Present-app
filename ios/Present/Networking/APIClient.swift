import Foundation

struct ServerConfig: Equatable, Hashable {
    var baseURL: URL
    var token: String
}

enum APIError: LocalizedError {
    case unauthorized
    case spendLimit(String)
    case server(code: String, message: String, status: Int)
    case offline
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The server didn't accept the access token."
        case .spendLimit(let message):
            return message
        case .server(_, let message, _):
            return message
        case .offline:
            return "You seem to be offline. Downloaded sessions are still here."
        case .invalidResponse:
            return "The server sent something unexpected."
        }
    }

    var isSpendLimit: Bool {
        if case .spendLimit = self { return true }
        return false
    }
}

/// Thin async client for the Present backend (docs/API.md).
struct APIClient {
    let config: ServerConfig
    var urlSession: URLSession = .shared

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(config: ServerConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    // MARK: Request building

    func url(for path: String) -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        var base = config.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + suffix) ?? config.baseURL
    }

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .timedOut, .dataNotAllowed, .internationalRoamingOff:
                throw APIError.offline
            default:
                throw error
            }
        }
        try check(response, data: data)
        return data
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
            let code = envelope?.error.code ?? "http_\(http.statusCode)"
            let message = envelope?.error.message ?? "Something went wrong (\(http.statusCode))."
            if code == "spend_limit" || http.statusCode == 402 { throw APIError.spendLimit(message) }
            throw APIError.server(code: code, message: message, status: http.statusCode)
        }
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await send(request(path))
        return try decoder.decode(T.self, from: data)
    }

    private func sendJSON<Body: Encodable, T: Decodable>(_ path: String, method: String, body: Body, as type: T.Type) async throws -> T {
        var req = request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let data = try await send(req)
        return try decoder.decode(T.self, from: data)
    }

    private func sendJSONNoContent<Body: Encodable>(_ path: String, method: String, body: Body) async throws {
        var req = request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        _ = try await send(req)
    }

    // MARK: Endpoints

    func health() async throws {
        var req = URLRequest(url: url(for: "/health"))
        req.timeoutInterval = 10
        _ = try await send(req)
    }

    func status() async throws -> ServerStatus {
        try await get("/api/status", as: ServerStatus.self)
    }

    func today() async throws -> TodayResponse {
        try await get("/api/today", as: TodayResponse.self)
    }

    func sessions(limit: Int = 100) async throws -> [Session] {
        try await get("/api/sessions?limit=\(limit)", as: SessionsResponse.self).sessions
    }

    func session(id: String) async throws -> Session {
        try await get("/api/sessions/\(id)", as: Session.self)
    }

    func createSession(theme: Theme?, durationMinutes: Int?) async throws -> Session {
        try await sendJSON("/api/sessions", method: "POST",
                           body: CreateSessionRequest(theme: theme, durationMinutes: durationMinutes),
                           as: Session.self)
    }

    func setFavorite(id: String, favorite: Bool) async throws -> Session {
        try await sendJSON("/api/sessions/\(id)", method: "PATCH",
                           body: FavoriteRequest(favorite: favorite), as: Session.self)
    }

    func deleteSession(id: String) async throws {
        _ = try await send(request("/api/sessions/\(id)", method: "DELETE"))
    }

    func settings() async throws -> UserSettings {
        try await get("/api/settings", as: UserSettings.self)
    }

    func updateSettings(_ settings: UserSettings) async throws -> UserSettings {
        try await sendJSON("/api/settings", method: "PUT", body: settings, as: UserSettings.self)
    }

    func voices() async throws -> [Voice] {
        try await get("/api/voices", as: VoicesResponse.self).voices
    }

    func music() async throws -> [MusicTrack] {
        try await get("/api/music", as: TracksResponse.self).tracks
    }

    func updateTrack(id: String, enabled: Bool?, title: String? = nil) async throws -> MusicTrack {
        try await sendJSON("/api/music/\(id)", method: "PATCH",
                           body: TrackPatchRequest(enabled: enabled, title: title), as: MusicTrack.self)
    }

    func deleteTrack(id: String) async throws {
        _ = try await send(request("/api/music/\(id)", method: "DELETE"))
    }

    func uploadTrack(fileURL: URL, title: String) async throws -> MusicTrack {
        let fileData = try Data(contentsOf: fileURL)
        let boundary = "PresentBoundary-\(UUID().uuidString)"
        var req = request("/api/music", method: "POST")
        req.timeoutInterval = 300
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let filename = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "mp3": mime = "audio/mpeg"
        case "m4a", "mp4", "aac": mime = "audio/mp4"
        case "wav": mime = "audio/wav"
        default: mime = "application/octet-stream"
        }

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"title\"\r\n\r\n")
        append("\(title)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let (data, response) = try await urlSession.upload(for: req, from: body)
        try check(response, data: data)
        return try decoder.decode(MusicTrack.self, from: data)
    }

    func registerDevice(token: String, environment: String) async throws {
        try await sendJSONNoContent("/api/devices", method: "POST",
                                    body: DeviceRequest(apnsToken: token, environment: environment))
    }

    func deleteAllData() async throws {
        try await sendJSONNoContent("/api/data", method: "DELETE", body: DeleteDataRequest())
    }

    /// Raw bytes for small media such as voice previews.
    func data(at path: String) async throws -> Data {
        var req = request(path)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return try await send(req)
    }

    /// Downloads a file to a temporary location and returns that location.
    func download(_ path: String) async throws -> URL {
        var req = request(path)
        req.timeoutInterval = 120
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (tempURL, response) = try await urlSession.download(for: req)
        try check(response, data: Data())
        // The system deletes `tempURL` when this call returns, so move it somewhere we own.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: path).pathExtension)
        try FileManager.default.moveItem(at: tempURL, to: owned)
        return owned
    }
}
