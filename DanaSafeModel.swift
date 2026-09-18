import Foundation

@MainActor
final class DanaSafeModel: ObservableObject {
    static let cloudflareBaseURL = DanaSafeAPIClient.productionBaseURL
    private let api = DanaSafeAPIClient()

    @Published var radarFile: RadarSystemsFile?
    @Published var tracks: [RadarTrack] = []
    @Published var contoursFile: ContoursFile?
    @Published var hydrology: SAIHFile?
    @Published var selectedFrameIndex: Int = 0
    @Published var showSignificantOnly = false
    @Published var dataSource = "Bundled fallback snapshot"
    @Published var lastRefresh: Date?
    @Published var snapshotGeneratedAt: Date?
    @Published var errorMessage: String?
    @Published var cloudflareHealth: String = "Not checked"
    @Published var cloudflareVersion: String?
    @Published var latestAEMETInfo: String = "Not checked"
    @Published var isRefreshing = false

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    var frames: [RadarFrame] { radarFile?.frames ?? [] }

    var selectedFrame: RadarFrame? {
        guard frames.indices.contains(selectedFrameIndex) else { return frames.last }
        return frames[selectedFrameIndex]
    }

    var displayedSystems: [RadarSystem] {
        let systems = selectedFrame?.systems ?? []
        return showSignificantOnly ? systems.filter(\.isSignificant) : systems
    }

    var significantCount: Int {
        selectedFrame?.systems.filter(\.isSignificant).count ?? 0
    }

    var contourLevels: [Int] {
        contoursFile?.levelsDbz ?? []
    }

    var radarAgeMinutes: Int? {
        guard let date = lastRefresh else { return nil }
        return max(0, Int(Date().timeIntervalSince(date) / 60))
    }

    var radarIsFresh: Bool {
        guard let age = radarAgeMinutes else { return false }
        return age <= 30
    }

    var freshnessText: String {
        guard let age = radarAgeMinutes else { return "Unknown age" }
        if age <= 2 { return "LIVE" }
        if age <= 30 { return "LIVE · \(age) min" }
        return "STALE · \(age) min"
    }

    func loadBundled() {
        do {
            radarFile = try loadResource("radar_systems_v03", as: RadarSystemsFile.self)
            let trackFile: ReliableTracksFile = try loadResource("reliable_tracks", as: ReliableTracksFile.self)
            tracks = trackFile.tracks
            contoursFile = try loadResource("national_marching_contours", as: ContoursFile.self)
            hydrology = try loadResource("saih_stations", as: SAIHFile.self)
            selectedFrameIndex = max(0, frames.count - 1)
            dataSource = "Bundled fallback snapshot"
            lastRefresh = radarFile.flatMap(radarObservationDate)
            snapshotGeneratedAt = nil
            errorMessage = nil
        } catch {
            errorMessage = "Bundled data error: \(error.localizedDescription)"
        }
    }

    // MARK: - Cloudflare V5.1 primary path

    /// Lightweight startup path: load the latest atomic snapshot already published in Cloudflare/R2.
    /// It never pretends that opening the app is a new AEMET observation.
    func loadFromCloudflare() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            await probeCloudflareHealth()
            let data = try await api.snapshot()
            let snapshot = try decoder.decode(DanaSafeLiveSnapshot.self, from: data)
            try validate(snapshot: snapshot)
            publish(snapshot: snapshot, source: "Cloudflare V5.1 · published atomic snapshot")
            cloudflareHealth = "Online · snapshot loaded"
        } catch {
            errorMessage = "Cloudflare snapshot: \(error.localizedDescription)"
            // Bundled fallback remains visible.
        }
    }

    /// Real V5.1 refresh. POST /radar/refresh is the remote trigger.
    /// Cloudflare checks AEMET; if a newer frame exists it executes the exact
    /// DanaSafe Python/Pillow pipeline in the bound Container, persists one
    /// validated atomic snapshot, and returns those same bytes to this app.
    func refreshFromCloudflare() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            latestAEMETInfo = "Consultando AEMET…"
            let data = try await api.refreshRadar()
            let snapshot = try decoder.decode(DanaSafeLiveSnapshot.self, from: data)
            try validate(snapshot: snapshot)

            // Independent end-to-end guard: the snapshot returned by refresh must
            // be the same observation that AEMET currently advertises.
            if let latest = try? await api.latestAEMET(),
               let aemetTimestamp = latest.timestamp {
                latestAEMETInfo = "\(aemetTimestamp) · \(latest.filename ?? "AEMET")"
                if let a = parseISO8601(aemetTimestamp),
                   let b = parseISO8601(snapshot.radarTimestamp),
                   abs(a.timeIntervalSince(b)) > 1 {
                    throw NSError(
                        domain: "DanaSafeV51",
                        code: 51,
                        userInfo: [NSLocalizedDescriptionKey: "Cloudflare returned \(snapshot.radarTimestamp), but AEMET latest is \(aemetTimestamp). Snapshot not published."]
                    )
                }
            }

            publish(snapshot: snapshot, source: "Cloudflare V5.1 · AEMET → DanaSafe engine → atomic snapshot")
            await probeCloudflareHealth()
            errorMessage = nil
        } catch {
            cloudflareHealth = "Refresh failed"
            errorMessage = "Actualización V5.1: \(error.localizedDescription)"
            // Never destroy the last validated snapshot on failure.
        }
    }

    func checkCloudflare() async {
        await probeCloudflareHealth()
        await probeLatestAEMETInfo()
    }

    private func probeCloudflareHealth() async {
        do {
            let health = try await api.health()
            cloudflareVersion = health.version
            let sync = health.inSync.map { $0 ? "SYNC" : "STALE" } ?? "?"
            cloudflareHealth = "Online · \(health.status) · \(sync)"
            if let radar = health.radarTimestamp { cloudflareHealth += " · radar \(radar)" }
            if let latest = health.latestAemetTimestamp { latestAEMETInfo = latest }
        } catch {
            cloudflareHealth = "Unavailable · \(error.localizedDescription)"
        }
    }

    private func probeLatestAEMETInfo() async {
        do {
            let latest = try await api.latestAEMET()
            if let timestamp = latest.timestamp {
                latestAEMETInfo = "\(timestamp) · \(latest.filename ?? "AEMET")"
            } else {
                latestAEMETInfo = "AEMET endpoint online"
            }
        } catch {
            latestAEMETInfo = "Unavailable · \(error.localizedDescription)"
        }
    }

    private func publish(snapshot: DanaSafeLiveSnapshot, source: String) {
        radarFile = snapshot.radar
        tracks = snapshot.tracks.tracks
        contoursFile = snapshot.contours
        hydrology = snapshot.hydrology
        selectedFrameIndex = max(0, snapshot.radar.frames.count - 1)
        dataSource = source
        lastRefresh = parseISO8601(snapshot.radarTimestamp)
        snapshotGeneratedAt = parseISO8601(snapshot.generatedAt)
        errorMessage = nil
    }

    private func validate(snapshot: DanaSafeLiveSnapshot) throws {
        guard snapshot.radar.frames.count == 10,
              snapshot.frameIntervalMinutes > 0,
              let latest = snapshot.radar.frames.last?.timestamp,
              latest == snapshot.radarTimestamp,
              parseISO8601(snapshot.radarTimestamp) != nil,
              parseISO8601(snapshot.generatedAt) != nil else {
            throw NSError(domain: "DanaSafeSnapshot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Incomplete or inconsistent radar snapshot"])
        }

        let parsed = snapshot.radar.frames.compactMap { parseISO8601($0.timestamp) }
        guard parsed.count == 10 else {
            throw NSError(domain: "DanaSafeSnapshot", code: 14, userInfo: [NSLocalizedDescriptionKey: "Radar snapshot contains an invalid timestamp"])
        }

        for (previous, current) in zip(parsed, parsed.dropFirst()) {
            let delta = Int(current.timeIntervalSince(previous).rounded())
            if delta != snapshot.frameIntervalMinutes * 60 {
                throw NSError(domain: "DanaSafeSnapshot", code: 13, userInfo: [NSLocalizedDescriptionKey: "Radar frames are not consecutive"])
            }
        }

        guard snapshot.contours.timestamp == snapshot.radarTimestamp else {
            throw NSError(domain: "DanaSafeSnapshot", code: 11, userInfo: [NSLocalizedDescriptionKey: "Contour timestamp does not match radar timestamp"])
        }

        let frameTimes = Set(snapshot.radar.frames.map(\.timestamp))
        let invalidTrack = snapshot.tracks.tracks.first {
            !frameTimes.contains($0.start.timestamp) || !frameTimes.contains($0.end.timestamp)
        }
        if invalidTrack != nil {
            throw NSError(domain: "DanaSafeSnapshot", code: 12, userInfo: [NSLocalizedDescriptionKey: "Track data belongs to another radar cycle"])
        }
    }

    private func radarObservationDate(from radar: RadarSystemsFile) -> Date? {
        guard let raw = radar.frames.last?.timestamp else { return nil }
        return parseISO8601(raw)
    }

    private func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func loadResource<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

}
