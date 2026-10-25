import Foundation

struct ProtectionFailureDTO: Decodable, Sendable {
    let code: String
    let message: String
}

struct ProtectionEvidenceDTO: Decodable, Hashable, Sendable {
    let quote: String
    let signals: [String]
}

struct ProtectionAssessmentDTO: Decodable, Hashable, Sendable {
    let riskLevel: String
    let signals: [String]
    let evidence: [ProtectionEvidenceDTO]
    let explanation: String
    let recommendedAction: String
}

struct ProtectionSnapshotDTO: Decodable, Sendable {
    let id: String
    let callId: UUID
    let channel: String?
    let language: String?
    let status: String
    let puckConnected: Bool
    let maskedTranscript: String
    let assessment: ProtectionAssessmentDTO?
    let outcome: String?
    let endRequested: Bool
    let revision: Int
    let nextSequence: Int
    let startedAt: Date
    let endRequestedAt: Date?
    let endedAt: Date?
    let failure: ProtectionFailureDTO?
}

struct ProtectionAPI: Sendable {
    private struct CreateBody: Encodable {
        let callID: UUID
        let startedAt: Date
        let channel: String?
        let title: String
        let callerDetail: String
        let language: String
    }

    let baseURL: URL
    let token: String
    let session: any HTTPDataSession

    init(serverURL: String, token: String, session: any HTTPDataSession) throws {
        let value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil else {
            throw BackendAnalysisError.invalidServerURL
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendAnalysisError.session(
                code: "missing_parent_token",
                detail: "Hubungkan akun orang tua sebelum memantau panggilan."
            )
        }
        baseURL = url
        self.token = token
        self.session = session
    }

    func create(call: CallContext) async throws -> ProtectionSnapshotDTO {
        let body = CreateBody(
            callID: call.id,
            startedAt: call.startedAt,
            channel: call.metadata.channel.rawValue,
            title: call.metadata.title,
            callerDetail: call.metadata.callerDetail,
            language: call.language.backendCode
        )
        return try await request(
            endpoint("api", "protection", "sessions"),
            method: "POST",
            body: Self.encoder.encode(body)
        )
    }

    func status(id: String) async throws -> ProtectionSnapshotDTO {
        try await request(endpoint("api", "protection", "sessions", id))
    }

    func end(id: String) async throws -> ProtectionSnapshotDTO {
        try await request(
            endpoint("api", "protection", "sessions", id, "end"),
            method: "POST"
        )
    }

    func delete(id: String) async throws {
        var request = authenticatedRequest(endpoint("api", "protection", "sessions", id))
        request.httpMethod = "DELETE"
        let (data, response) = try await data(for: request)
        guard response.statusCode == 204 else {
            throw Self.httpError(response.statusCode, data: data)
        }
    }

    private func request<Response: Decodable>(
        _ url: URL,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        var request = authenticatedRequest(url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.httpError(response.statusCode, data: data)
        }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw BackendAnalysisError.decoding
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BackendAnalysisError.transport(detail: "Respons jaringan Rambu tidak valid.")
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BackendAnalysisError {
            throw error
        } catch {
            throw BackendAnalysisError.transport(detail: "Server Rambu tidak dapat dihubungi.")
        }
    }

    private func authenticatedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func endpoint(_ components: String...) -> URL {
        components.reduce(baseURL) { $0.appending(path: $1) }
    }

    private static func httpError(_ status: Int, data: Data) -> BackendAnalysisError {
        .http(
            status: status,
            detail: errorDetail(from: data) ?? "Server mengembalikan status \(status)."
        )
    }

    private static func errorDetail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let detail = object["detail"] as? [String: Any],
           let message = detail["message"] as? String { return message }
        return nil
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.keyEncodingStrategy = .convertToSnakeCase
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        value.dateDecodingStrategy = .iso8601
        return value
    }()
}
