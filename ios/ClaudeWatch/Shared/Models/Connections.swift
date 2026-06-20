import Foundation

/// One saved Mac bridge: name + address + its pairing token.
/// Holding the token lets us switch Macs with a tap — no re-pairing.
struct SavedConnection: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int
    var token: String
}

/// Persists the list of paired Macs and which one is active.
/// Backs the "Macs" switcher in Settings.
final class ConnectionStore: ObservableObject {

    static let shared = ConnectionStore()

    @Published private(set) var connections: [SavedConnection] = []
    @Published private(set) var activeID: UUID?

    private let listKey = "saved_connections_v1"
    private let activeKey = "active_connection_id"

    private init() {
        load()
    }

    var active: SavedConnection? {
        connections.first { $0.id == activeID }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: listKey),
           let list = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            connections = list
        }
        if let s = UserDefaults.standard.string(forKey: activeKey) {
            activeID = UUID(uuidString: s)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: activeKey)
    }

    /// Insert or update a connection (matched by host:port) and make it active.
    @discardableResult
    func upsert(name: String, host: String, port: Int, token: String) -> SavedConnection {
        if let idx = connections.firstIndex(where: { $0.host == host && $0.port == port }) {
            connections[idx].name = name
            connections[idx].token = token
            activeID = connections[idx].id
            persist()
            return connections[idx]
        }
        let conn = SavedConnection(name: name, host: host, port: port, token: token)
        connections.append(conn)
        activeID = conn.id
        persist()
        return conn
    }

    func setActive(_ id: UUID) {
        activeID = id
        persist()
    }

    /// Rename a saved connection (e.g. to "office-1").
    func rename(_ id: UUID, to name: String) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[idx].name = name
        persist()
    }

    func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        if activeID == id {
            activeID = connections.first?.id
        }
        persist()
    }
}
