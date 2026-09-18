import Foundation

struct DanaSafeBackendHealth: Decodable {
    let service: String
    let status: String
    let version: String?
    let radarTimestamp: String?
    let snapshotGeneratedAt: String?
    let latestAemetTimestamp: String?
    let inSync: Bool?
    let aemetError: String?
}

struct DanaSafeAEMETLatestInfo: Decodable {
    let status: String?
    let timestamp: String?
    let filename: String?
    let source: String?
}

enum DanaSafeAPIError: LocalizedError {
    case http(Int, String)
    case invalidResponse
    case unsupportedPayload

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .invalidResponse: return "Invalid DanaSafe backend response"
        case .unsupportedPayload: return "Unsupported DanaSafe snapshot payload"
        }
    }
}

struct DanaSafeAPIClient {
    static let productionBaseURL = URL(string: "https://danasafe-radar.firefritz.workers.dev")!

    let baseURL: URL

    init(baseURL: URL = Self.productionBaseURL) {
        self.baseURL = baseURL
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func health() async throws -> DanaSafeBackendHealth {
        let (data, _) = try await request(path: "health", method: "GET", timeout: 20)
        return try decoder.decode(DanaSafeBackendHealth.self, from: data)
    }

    func latestAEMET() async throws -> DanaSafeAEMETLatestInfo {
        let (data, _) = try await request(path: "aemet/latest-image-info", method: "GET", timeout: 30)
        return try decoder.decode(DanaSafeAEMETLatestInfo.self, from: data)
    }

    /// Loads the last atomic snapshot already published by the backend.
    /// This does not execute the expensive radar algorithm.
    func snapshot() async throws -> Data {
        let (data, _) = try await request(path: "radar/snapshot", method: "GET", timeout: 60)
        return data
    }

    /// V5.1 real refresh: this POST is the trigger that asks Cloudflare to compare
    /// AEMET with the published snapshot and, only when necessary, execute the
    /// DanaSafe Python/Pillow engine in the bound Cloudflare Container.
    func refreshRadar() async throws -> Data {
        let (data, _) = try await request(path: "radar/refresh", method: "POST", timeout: 300)
        return data
    }

    private func request(path: String, method: String, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("DanaSafe-iOS/5.1.1-cloud-only", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanaSafeAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Backend error"
            throw DanaSafeAPIError.http(http.statusCode, String(message.prefix(500)))
        }
        return (data, http)
    }
}
