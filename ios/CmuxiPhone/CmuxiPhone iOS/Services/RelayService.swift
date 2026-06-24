import Foundation
import Combine
import UIKit

/// Coordinates communication between the bridge server, SSE event stream,
/// and the Apple Watch via WCSession.
///
/// Acts as the central hub: bridge events are received via SSE/polling,
/// parsed, and forwarded to the watch. Commands from the watch are
/// received via WCSession and forwarded to the bridge via HTTP.
@MainActor
final class RelayService: ObservableObject {

    // MARK: - Singleton

    static let shared = RelayService()

    // MARK: - Published state

    @Published private(set) var isPaired: Bool = false
    /// True while the user is pairing an ADDITIONAL Mac (shows PairingView over the list).
    @Published var isAddingMac: Bool = false
    @Published private(set) var machineName: String?
    @Published private(set) var modelName: String?
    @Published private(set) var workingDirectory: String?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var recentTerminalLines: [TerminalLine] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastConnected: Date?

    /// True if ANY session is thinking. Per-session state lives on AgentSession
    /// .thinking; this derived flag exists only for non-session-scoped readers.
    var isThinking: Bool { sessions.contains { $0.thinking } }

    /// Set a session's "thinking" flag. With no sessionId, turning OFF clears all
    /// sessions (a global stop); turning ON requires a sessionId (no-op otherwise).
    func setThinking(_ on: Bool, sessionId: String?) {
        if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].thinking = on
        } else if !on {
            for i in sessions.indices { sessions[i].thinking = false }
        }
    }

    // Multi-session
    @Published private(set) var sessions: [AgentSession] = []

    // Permission prompt state (uses shared ApprovalRequest model)
    // `pendingApproval` is the head of the queue, kept for existing per-session UI.
    @Published var pendingApproval: ApprovalRequest? = nil
    /// Global approval queue across all sessions of the active Mac. Drives the
    /// app-wide badge + queue sheet.
    @Published private(set) var approvalQueue: [ApprovalRequest] = []
    var pendingApprovalCount: Int { approvalQueue.count }
    /// permissionIds we've already answered/cleared — makes responses single-use
    /// and lets us ignore the bridge's reconnect re-sends of resolved approvals.
    private var resolvedPermissionIds: Set<String> = []

    // cmux mirror — populated when the connected Mac runs cmux.
    @Published private(set) var cmuxAvailable: Bool = false
    @Published private(set) var cmuxWorkspaces: [CmuxWorkspace] = []
    /// Bumped on every cmux event so terminal views refetch their screen live.
    @Published private(set) var cmuxScreenTick: Int = 0

    /// Supervise mode — when ON, the bridge routes mutating tools through phone
    /// approval (all permission modes). Mirrors the bridge's state.
    @Published var superviseMode: Bool = false

    // MARK: - Private

    /// All connected bridges — one per paired Mac, each with its own HTTP client
    /// and SSE stream, all live at once. Sessions/approvals are tagged with their
    /// bridge's id so commands and approvals route back to the right Mac.
    private var connections: [BridgeConnection] = []
    /// Which bridge the cmux mirror, supervise toggle, and "active" label follow
    /// (the Mac whose detail is on screen). Per-session routing ignores this.
    @Published var focusedBridgeID: UUID?

    /// Set when a notification deep link resolves to a loaded session — the root
    /// view observes this to navigate to that session, then clears it.
    @Published var navigateToSessionId: String?
    /// A deep-link target waiting for its session to arrive (cold-launch case).
    private var pendingDeepLinkSessionId: String?

    private let fallbackClient = BridgeClient() // ponytail: inert stand-in; real calls go through a connection
    /// The focused bridge's client — for non-session-scoped calls (cmux, supervise,
    /// status). Falls back to an inert client when nothing is connected.
    private var bridgeClient: BridgeClient { focusedConn?.client ?? fallbackClient }
    private var focusedConn: BridgeConnection? {
        connections.first { $0.id == focusedBridgeID } ?? connections.first
    }
    /// The connection for a given bridge id (or the focused one when id is nil).
    private func conn(_ id: UUID?) -> BridgeConnection? {
        if let id, let c = connections.first(where: { $0.id == id }) { return c }
        return focusedConn
    }
    /// The client that owns a given session, for routing its commands/approvals.
    private func client(forSession sid: String?) -> BridgeClient {
        let bid = sid.flatMap { s in sessions.first(where: { $0.id == s })?.bridgeID }
        return conn(bid)?.client ?? bridgeClient
    }

    private let discovery = BonjourDiscovery()
    private let notificationService = NotificationService()
    private let sessionManager = WatchSessionManager.shared

    private let terminalBuffer = OutputRingBuffer<TerminalLine>(capacity: 50)
    private var terminalBatchTimer: Timer?
    private var pendingTerminalLines: [TerminalLine] = []

    private var elapsedTimer: Timer?
    private var sessionStartDate: Date?
    private var sseRetryTimer: Timer?   // periodic SSE re-attempt while degraded to polling
    private var macGeneration = 0       // bumped on every Mac switch/forget/unpair; guards late async results

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        setupWatchMessageHandler()
        connectAllSaved()
    }

    // MARK: - Multi-bridge connection management

    /// Build + connect a live BridgeConnection for every saved Mac that has a
    /// token, so all paired Macs stream simultaneously.
    private func connectAllSaved() {
        let store = ConnectionStore.shared
        for saved in store.connections where !saved.token.isEmpty {
            addConnection(saved, focus: saved.id == store.activeID)
        }
        if focusedBridgeID == nil { focusedBridgeID = connections.first?.id }
        isPaired = !connections.isEmpty
        if isPaired {
            machineName = focusedConn?.name
            connectionState = .connecting
            startElapsedTimer()
        }
    }

    /// Add (or focus, if already present) a connection for a saved Mac and open
    /// its SSE stream. Additive — never tears down the other live bridges.
    @discardableResult
    private func addConnection(_ saved: SavedConnection, focus: Bool) -> BridgeConnection {
        if let existing = connections.first(where: { $0.id == saved.id }) {
            if focus { focusedBridgeID = saved.id }
            return existing
        }
        let c = BridgeConnection(saved: saved)
        wireSSE(c)
        connections.append(c)
        if focus || focusedBridgeID == nil { focusedBridgeID = c.id }
        isPaired = true
        if let url = c.client.baseURL, let token = c.client.token {
            c.sse.connect(baseURL: url, token: token)
        }
        return c
    }

    /// Tear down one bridge and drop only its sessions/approvals. Keeps the
    /// focused bridge and the store's active id in lockstep when reassigning.
    private func removeConnection(_ id: UUID) {
        connections.first(where: { $0.id == id })?.sse.disconnect()
        connections.removeAll { $0.id == id }
        dropState(forBridge: id)
        if focusedBridgeID == id {
            focusedBridgeID = connections.first?.id
            if let f = focusedBridgeID { ConnectionStore.shared.setActive(f) }
        }
        isPaired = !connections.isEmpty
        machineName = focusedConn?.name
        recomputeConnectionState()
    }

    /// Wire one connection's SSE callbacks, tagging every event with its bridge id.
    private func wireSSE(_ c: BridgeConnection) {
        let bid = c.id
        c.sse.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleBridgeEvent(event, bridgeID: bid) }
        }
        c.sse.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleSSEStateChange(state, bridgeID: bid) }
        }
    }

    private func handleSSEStateChange(_ state: SSEClient.SSEState, bridgeID: UUID) {
        if state == .connected {
            lastConnected = Date()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")
        }
        recomputeConnectionState()
        updateWatchState()
    }

    /// The global status pill reflects the best state across all bridges; the
    /// office list shows each Mac's own state via `state(of:)`.
    private func recomputeConnectionState() {
        let states = connections.map { $0.sse.state }
        if !states.contains(.polling) { stopSSERetry() } else { scheduleSSERetry() }
        if states.contains(.connected) { connectionState = .connected }
        else if states.contains(.polling) { connectionState = .degraded }
        else if states.contains(.connecting) { connectionState = .connecting }
        else { connectionState = .disconnected }
    }

    // MARK: - Per-bridge accessors (for the office list / focused workspace view)

    /// Sessions belonging to the focused Mac — drives the per-Mac workspace view.
    var focusedSessions: [AgentSession] {
        guard let fid = focusedBridgeID else { return sessions }
        return sessions.filter { $0.bridgeID == fid }
    }
    func sessionCount(_ bridgeID: UUID) -> Int { sessions.filter { $0.bridgeID == bridgeID }.count }
    func folderCount(_ bridgeID: UUID) -> Int {
        let keys = sessions.filter { $0.bridgeID == bridgeID }.map { s -> String in
            if !s.folderName.isEmpty { return s.folderName }
            let leaf = (s.cwd as NSString).lastPathComponent
            return leaf.isEmpty ? "(unknown)" : leaf
        }
        return Set(keys).count
    }
    func state(of bridgeID: UUID) -> ConnectionState {
        guard let c = connections.first(where: { $0.id == bridgeID }) else { return .disconnected }
        switch c.sse.state {
        case .connected:   return .connected
        case .polling:     return .degraded
        case .connecting:  return .connecting
        case .disconnected: return .disconnected
        }
    }

    // MARK: - Deep links (notification tap → session)

    /// Handle a `cmuxiphone://session/<sessionId>` URL from an ntfy notification.
    /// The session id is globally unique, so we find its Mac, focus it, and route
    /// there — even if the app cold-launched and the session hasn't loaded yet.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "cmuxiphone", url.host == "session" else { return }
        guard let sessionId = url.pathComponents.first(where: { $0 != "/" }), !sessionId.isEmpty else { return }
        pendingDeepLinkSessionId = sessionId
        resolvePendingDeepLink()
        // Stop waiting after a cold-launch grace period so a late session can't
        // trigger a surprise navigation long after the tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.pendingDeepLinkSessionId == sessionId { self?.pendingDeepLinkSessionId = nil }
        }
    }

    /// Route to the pending deep-link session once it exists: focus its Mac and
    /// signal the root view to navigate. Re-tried as sessions arrive.
    private func resolvePendingDeepLink() {
        guard let sid = pendingDeepLinkSessionId,
              let session = sessions.first(where: { $0.id == sid }) else { return }
        if let bid = session.bridgeID { focusedBridgeID = bid }
        pendingDeepLinkSessionId = nil
        navigateToSessionId = sid
    }

    // MARK: - Pairing

    /// Discovers the bridge on LAN and pairs with the given code, then connects it
    /// ADDITIVELY — any already-paired Macs stay connected and streaming.
    func pair(code: String) async throws {
        let service = try await discovery.discover()
        try await pairAndConnect(service: service, code: code)
    }

    /// Pairs using a manual IP address (fallback when Bonjour fails on real devices).
    func pairWithIP(_ ip: String, code: String) async throws {
        let service = try await discovery.discoverAtIP(ip)
        try await pairAndConnect(service: service, code: code)
    }

    /// Shared pairing tail: pair over a throwaway client, persist the token
    /// per-bridge, then open a live connection alongside the existing ones.
    private func pairAndConnect(service: BonjourDiscovery.DiscoveredService, code: String) async throws {
        let pairing = BridgeClient()
        pairing.configure(host: service.host, port: service.port)
        try await pairing.pair(code: code)
        guard let token = pairing.token else { throw BridgeClient.BridgeError.networkError }

        let saved = ConnectionStore.shared.upsert(
            name: service.machineName ?? service.host,
            host: service.host, port: Int(service.port), token: token
        )
        isAddingMac = false
        lastConnected = Date()
        addConnection(saved, focus: true)
        machineName = saved.name
        startElapsedTimer()
        updateWatchState()
    }

    /// Disconnects every bridge and clears all live state (keeps the saved Mac
    /// list — use forget/remove to drop a specific Mac).
    func unpair() {
        connections.forEach { $0.sse.disconnect() }
        connections = []
        focusedBridgeID = nil
        stopSSERetry()
        stopElapsedTimer()
        terminalBatchTimer?.invalidate()
        terminalBatchTimer = nil

        isPaired = false
        machineName = nil
        modelName = nil
        workingDirectory = nil
        resetPerMacState()
        connectionState = .disconnected

        sessionManager.updateApplicationContext(with: SessionState.disconnected)
    }

    // MARK: - Multi-Mac switching

    /// Switch to an already-paired Mac with one tap (no re-pairing).
    /// Focus a paired Mac (show ITS cmux mirror / workspaces). All bridges stay
    /// connected and streaming — this only changes which Mac the cmux mirror and
    /// supervise toggle follow; sessions/approvals from every Mac remain merged.
    func switchTo(_ conn: SavedConnection) {
        let c = addConnection(conn, focus: true)   // connect if it wasn't (offline-added), then focus
        ConnectionStore.shared.setActive(conn.id)
        macGeneration &+= 1                          // invalidate focused-bridge async results
        machineName = c.name
        isAddingMac = false
        cmuxAvailable = false                        // mirror is focused-bridge-specific
        cmuxWorkspaces = []
        refreshCmuxTree()
        refreshSupervise()
        recomputeConnectionState()
        startElapsedTimer()
        updateWatchState()
    }

    /// Reflect a rename of the active connection into the live UI label.
    func refreshActiveName() {
        if let active = ConnectionStore.shared.active {
            machineName = active.name
            connections.first(where: { $0.id == active.id })?.name = active.name
            updateWatchState()
        }
    }

    // MARK: - cmux mirror

    /// Fetch the live cmux workspace/terminal tree.
    func refreshCmuxTree() {
        let gen = macGeneration
        Task { @MainActor in
            do {
                let data = try await bridgeClient.fetchCmuxTree()
                let decoded = try JSONDecoder().decode(CmuxTreeResponse.self, from: data)
                // Drop a response that arrived after a Mac switch — it belongs to
                // the previous Mac and would repopulate stale workspaces.
                guard gen == macGeneration else { return }
                cmuxAvailable = decoded.available
                cmuxWorkspaces = decoded.workspaces
            } catch {
                // keep previous state on transient failures
            }
        }
    }

    /// Read one cmux terminal's plain-text screen (with hash for safe responses).
    func cmuxScreen(_ terminalId: String) async -> CmuxScreen? {
        try? await bridgeClient.fetchCmuxScreen(terminalId: terminalId)
    }

    /// Send a prompt straight to a cmux terminal (types + Enter). Unguarded —
    /// for normal prompts where the screen is expected to keep changing.
    func sendCmux(terminalId: String, text: String) {
        Task { try? await bridgeClient.sendCommand(text: text, terminalId: terminalId) }
    }

    /// Transactional cmux prompt send — returns false on failure so the caller
    /// keeps the text in the input for retry.
    @discardableResult
    func sendCmuxPrompt(terminalId: String, text: String) async -> Bool {
        do {
            try await bridgeClient.sendCommand(text: text, terminalId: terminalId)
            return true
        } catch {
            return false
        }
    }

    /// Uploads an image to the bridge and returns the saved temp-file path on the
    /// Mac (or nil on failure). The caller references that path in a prompt.
    func uploadImage(_ data: Data, filename: String) async -> String? {
        do {
            return try await bridgeClient.uploadImage(data: data, filename: filename)
        } catch {
            return nil
        }
    }

    /// Awaitable cmux text send with explicit submit control — used by the codex
    /// model/effort driver, which types a slash command (submit) then picks rows
    /// with single digits (no submit). Unguarded by design (it drives the screen).
    func sendCmuxText(terminalId: String, text: String, submit: Bool) async {
        try? await bridgeClient.sendCommand(text: text, terminalId: terminalId, submit: submit)
    }

    /// Send a named special key (up/down/enter/escape/…) to a cmux terminal —
    /// drives interactive TUI pickers like codex's `/model` popup.
    func sendCmuxKey(terminalId: String, key: String) async {
        try? await bridgeClient.sendKey(terminalId: terminalId, key: key)
    }

    /// Send an approval response guarded by the screen hash the user was viewing.
    /// Returns .screenChanged if the bridge rejected because the screen moved.
    func sendCmuxGuarded(terminalId: String, text: String, expectedScreenHash: String?, submit: Bool = true) async -> CmuxSendResult {
        await bridgeClient.sendCmuxGuarded(terminalId: terminalId, text: text, expectedScreenHash: expectedScreenHash, submit: submit)
    }

    // MARK: - Supervise mode

    /// Toggle broad phone-approval (PreToolUse) on the bridge. Optimistic.
    func setSupervise(_ on: Bool) {
        superviseMode = on
        Task {
            do { try await bridgeClient.setSupervise(on: on) }
            catch { await MainActor.run { self.refreshSupervise() } } // resync on failure
        }
    }

    /// Sync the toggle with the bridge's actual state.
    func refreshSupervise() {
        let gen = macGeneration
        Task { @MainActor in
            if let st = try? await bridgeClient.fetchStatus() {
                // Drop a response that arrived after a Mac switch — the previous
                // Mac's supervise value must not overwrite the new Mac's toggle.
                guard gen == macGeneration else { return }
                superviseMode = st.supervise ?? false
            }
        }
    }

    /// Start pairing an additional Mac (PairingView is shown over the list).
    func beginAddMac() { isAddingMac = true }
    func cancelAddMac() { isAddingMac = false }

    /// Forget a SPECIFIC Mac (focused or not) — always disconnects its live bridge
    /// and drops only its sessions/approvals; the other connected Macs are
    /// untouched. The single entry point for deletion so a non-focused Mac can't be
    /// removed from the store while leaving its SSE stream + state leaked behind.
    func forget(_ id: UUID) {
        let wasFocused = (id == focusedBridgeID)
        ConnectionStore.shared.remove(id)
        removeConnection(id)

        if connections.isEmpty {
            // No Macs left — fall back to the pairing screen.
            stopElapsedTimer()
            terminalBatchTimer?.invalidate()
            terminalBatchTimer = nil
            isPaired = false
            isAddingMac = false
            machineName = nil
            resetPerMacState()
            connectionState = .disconnected
            sessionManager.updateApplicationContext(with: SessionState.disconnected)
        } else if wasFocused, let next = ConnectionStore.shared.active {
            switchTo(next)   // refresh the cmux mirror/supervise for the new focus
        }
    }

    /// Forget the currently focused Mac (toolbar / no-arg path).
    func forgetActive() {
        if let id = focusedBridgeID ?? ConnectionStore.shared.activeID { forget(id) }
    }

    /// Reset ALL live state across every bridge (used by unpair / forgetting the
    /// last Mac). Per-bridge removal uses `dropState(forBridge:)` instead.
    private func resetPerMacState() {
        macGeneration &+= 1
        sessions = []
        recentTerminalLines = []
        terminalBuffer.clear()
        pendingApproval = nil
        approvalQueue = []
        resolvedPermissionIds = []
        elapsedSeconds = 0
        cmuxAvailable = false
        cmuxWorkspaces = []
        cmuxScreenTick = 0
    }

    /// Drop one bridge's sessions + approvals when that Mac is removed.
    private func dropState(forBridge id: UUID) {
        sessions.removeAll { $0.bridgeID == id }
        let removed = approvalQueue.filter { $0.bridgeID == id }
        approvalQueue.removeAll { $0.bridgeID == id }
        for a in removed { if let pid = a.permissionId { resolvedPermissionIds.insert(pid) } }
        pendingApproval = approvalQueue.first
    }

    // MARK: - SSE recovery (degraded -> retry)

    private func scheduleSSERetry() {
        guard sseRetryTimer == nil else { return }
        sseRetryTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.connections.forEach { $0.sse.retrySSE() } }
        }
    }

    private func stopSSERetry() {
        sseRetryTimer?.invalidate()
        sseRetryTimer = nil
    }

    private func handleBridgeEvent(_ event: SSEClient.SSEEvent, bridgeID: UUID) {
        guard let eventType = event.event else { return }
        let data = event.data

        switch eventType {
        case "pty-output":
            handlePtyOutput(data)

        case "permission-request":
            handlePermissionRequest(data, bridgeID: bridgeID)

        case "permission-cleared":
            handlePermissionCleared(data)

        case "permission-sync":
            handlePermissionSync(data, bridgeID: bridgeID)

        case "session":
            handleSessionEvent(data, bridgeID: bridgeID)

        case "tool-output":
            handleToolOutput(data)

        case "task-complete":
            handleTaskComplete(data)

        case "error":
            handleError(data)

        case "stop":
            handleStop(data)

        case "cmux-event":
            // The cmux mirror only shows the focused Mac — ignore other bridges'
            // cmux churn so we don't refetch the focused tree for the wrong Mac.
            guard bridgeID == focusedBridgeID else { break }
            refreshCmuxTree()
            cmuxScreenTick &+= 1

        case "poll-status":
            // Polling fallback -- just keep alive
            break

        default:
            break
        }
    }

    // MARK: - Event handlers

    private func handlePtyOutput(_ data: String) {
        guard let json = parseJSON(data),
              let text = json["text"] as? String else { return }
        let sessionId = json["sessionId"] as? String

        // Strip ANSI escape codes for display
        let cleaned = text.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )

        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let line = TerminalLine(text: cleaned, type: .output, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        // Batch terminal updates to the watch (1-second window)
        pendingTerminalLines.append(line)
        scheduleBatchSend()
    }

    private func handlePermissionRequest(_ data: String, bridgeID: UUID) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let sessionId = json["sessionId"] as? String

        var question: String? = nil
        var desc = toolName
        var options: [ApprovalRequest.OptionItem] = []

        // Parse questions/options (Codex format with questions array)
        if let questions = toolInput["questions"] as? [[String: Any]],
           let firstQ = questions.first {
            question = firstQ["question"] as? String
            desc = toolInput["command"] as? String
                ?? firstQ["header"] as? String
                ?? toolName
            if let opts = firstQ["options"] as? [[String: Any]] {
                options = opts.map { opt in
                    ApprovalRequest.OptionItem(
                        label: opt["label"] as? String ?? "",
                        description: opt["description"] as? String
                    )
                }
            }
        } else if let path = toolInput["file_path"] as? String {
            let filename = (path as NSString).lastPathComponent
            desc = "\(toolName) \(filename)"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else if let cmd = toolInput["command"] as? String {
            desc = "Run: \(String(cmd.prefix(100)))"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else {
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        }

        print("[RelayService] Permission requested: \(toolName) — \(desc)")

        let reason = toolInput["reason"] as? String ?? (json["reason"] as? String)
        let session = sessionId.flatMap { sid in sessions.first(where: { $0.id == sid && $0.bridgeID == bridgeID }) }
        // Live-terminal pin (codex/cmux approvals): the bridge snapshots the
        // terminal + its screen hash so the answer can't land on a wrong/changed screen.
        let terminalId = json["terminalId"] as? String
        let expectedHash = json["screenHash"] as? String ?? (json["expectedScreenHash"] as? String)
        let approval = ApprovalRequest(
            permissionId: permissionId,
            toolName: toolName,
            actionSummary: desc,
            question: question,
            options: options,
            sessionId: sessionId,
            macName: conn(bridgeID)?.name ?? machineName,
            cwd: session?.cwd,
            agent: session?.agent.rawValue ?? (json["source"] as? String),
            reason: reason,
            terminalId: terminalId,
            expectedScreenHash: expectedHash,
            bridgeID: bridgeID
        )

        // Ignore re-sends of an approval we've already answered/cleared.
        if let pid = approval.permissionId, resolvedPermissionIds.contains(pid) { return }

        // De-dupe: the bridge re-sends pending approvals on every SSE reconnect.
        if let idx = approvalQueue.firstIndex(where: { $0.dedupeKey == approval.dedupeKey }) {
            // Preserve in-flight/failed interaction state — a reconnect resend
            // must NOT reset .submitting back to .pending (which would re-enable
            // the buttons mid-POST and allow a double answer) or wipe a 409
            // re-verify (.failed + refreshed hash/screen). Only refresh a card
            // that is still plain .pending.
            if approvalQueue[idx].status == .submitting || approvalQueue[idx].status == .failed {
                return
            }
            approvalQueue[idx] = approval               // refresh in place
            pendingApproval = approvalQueue.first
            if let sid = sessionId, let sIdx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[sIdx].pendingApproval = approval
                sessions[sIdx].activity = .waitingApproval
            }
            return                                       // no new haptic / notification
        }

        approvalQueue.append(approval)
        pendingApproval = approvalQueue.first

        // Track on specific session
        if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].pendingApproval = approval
            sessions[idx].activity = .waitingApproval
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        // Add to terminal
        let line = TerminalLine(text: "⚠ Permission: \(desc)", type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        // Forward to watch
        let watchRequest = ApprovalRequest(toolName: toolName, actionSummary: desc, question: question, options: options)
        let message = WatchMessage.approvalRequestMessage(watchRequest)
        sessionManager.send(message)

        // Notification if backgrounded
        notificationService.postApprovalNeeded(toolName: toolName, summary: desc)
    }

    // MARK: - Permission response

    /// Respond to a SPECIFIC approval with a selected option (queue-aware).
    /// Single-use: a permissionId can only be answered once, even if the card
    /// is shown in both the queue sheet and a session detail.
    func respond(to approval: ApprovalRequest, optionLabel: String, index: Int) {
        let permissionId = approval.permissionId ?? ""
        // Transactional: don't double-submit, and don't re-answer a resolved id.
        // The card is removed ONLY after the bridge confirms (HTTP 2xx).
        if currentStatus(of: approval) == .submitting { return }
        if !permissionId.isEmpty, resolvedPermissionIds.contains(permissionId) { return }

        let isLast = index == approval.options.count - 1
        // Heavy "deny" haptic only for a standard permission's last (deny) option —
        // an AskUserQuestion's last option is a normal choice, not a denial.
        let isDeny = approval.question == nil && isLast
        UIImpactFeedbackGenerator(style: isDeny ? .heavy : .medium).impactOccurred()
        setStatus(.submitting, for: approval)

        let tid = approval.terminalId
        let hash = approval.expectedScreenHash
        let api = conn(approval.bridgeID)?.client ?? bridgeClient   // answer goes to the approval's own Mac
        Task { @MainActor in
            do {
                if approval.question != nil {
                    // AskUserQuestion: send the option label (index -1 == freeform text)
                    try await api.respondToApprovalWithOption(
                        requestId: permissionId, optionLabel: optionLabel, index: index,
                        terminalId: tid, expectedScreenHash: hash)
                } else if optionLabel.lowercased().contains("allow all") || optionLabel.lowercased().contains("don't ask") {
                    try await api.respondToApprovalAllowAll(
                        requestId: permissionId, terminalId: tid, expectedScreenHash: hash)
                } else {
                    try await api.respondToApproval(
                        requestId: permissionId, allow: !isLast, terminalId: tid, expectedScreenHash: hash)
                }
                // Success — only NOW mark resolved + remove the card.
                if !permissionId.isEmpty { resolvedPermissionIds.insert(permissionId) }
                // Only a standard-permission DENY is an error; an AskUserQuestion
                // choice (even the last) is a normal selection.
                let line = TerminalLine(text: "→ \(optionLabel)", type: isDeny ? .error : .output)
                terminalBuffer.append(line)
                recentTerminalLines = terminalBuffer.getLast(15)
                clearPendingApproval(for: approval)
            } catch {
                // Failure — keep the card, surface the error, allow retry.
                if case BridgeClient.BridgeError.screenChanged = error, let tid {
                    // 409: the live screen moved since the user saw it. Pull the
                    // CURRENT screen + hash so the card re-shows it and a retry
                    // sends the fresh hash (otherwise it would 409 forever).
                    await reverifyApproval(approval, terminalId: tid)
                } else {
                    setStatus(.failed, for: approval, error: friendlyError(error))
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                let line = TerminalLine(text: "✗ 승인 전송 실패 — 다시 시도하세요", type: .error)
                terminalBuffer.append(line)
                recentTerminalLines = terminalBuffer.getLast(15)
            }
        }
    }

    /// After a 409, fetch the live screen + hash for the approval's terminal and
    /// fold them into the card so the user re-confirms before retrying with the
    /// fresh hash (the bridge requires the answer hash == current screen hash).
    private func reverifyApproval(_ approval: ApprovalRequest, terminalId: String) async {
        let fresh = await cmuxScreen(terminalId)
        if let i = approvalQueue.firstIndex(where: { $0.dedupeKey == approval.dedupeKey }) {
            approvalQueue[i].status = .failed
            approvalQueue[i].lastError = "화면이 바뀌었습니다 — 아래 최신 화면을 확인하고 다시 누르세요"
            approvalQueue[i].expectedScreenHash = fresh?.hash
            approvalQueue[i].latestScreen = fresh?.text
        }
        pendingApproval = approvalQueue.first
        for i in sessions.indices where sessions[i].pendingApproval?.permissionId == approval.permissionId {
            sessions[i].pendingApproval?.status = .failed
            sessions[i].pendingApproval?.lastError = "화면이 바뀌었습니다 — 다시 확인 후 누르세요"
            sessions[i].pendingApproval?.expectedScreenHash = fresh?.hash
            sessions[i].pendingApproval?.latestScreen = fresh?.text
        }
    }

    /// Live status of an approval (the `approval` argument is a value snapshot).
    private func currentStatus(of approval: ApprovalRequest) -> ApprovalRequest.ApprovalStatus {
        approvalQueue.first(where: { $0.dedupeKey == approval.dedupeKey })?.status ?? approval.status
    }

    /// Update an approval's status (+optional error) in BOTH the queue and the
    /// owning session — ApprovalRequest is a value type, so we patch every copy.
    private func setStatus(_ status: ApprovalRequest.ApprovalStatus, for approval: ApprovalRequest, error: String? = nil) {
        if let i = approvalQueue.firstIndex(where: { $0.dedupeKey == approval.dedupeKey }) {
            approvalQueue[i].status = status
            approvalQueue[i].lastError = error
        }
        pendingApproval = approvalQueue.first
        for i in sessions.indices where sessions[i].pendingApproval?.permissionId == approval.permissionId {
            sessions[i].pendingApproval?.status = status
            sessions[i].pendingApproval?.lastError = error
        }
    }

    private func friendlyError(_ error: Error) -> String {
        if let be = error as? BridgeClient.BridgeError {
            switch be {
            case .screenChanged: return "화면이 바뀌었습니다 — 다시 확인 후 시도하세요"
            case .networkError:  return "브리지에 연결할 수 없습니다"
            case .rateLimited:   return "잠시 후 다시 시도하세요"
            default:             return be.errorDescription ?? "전송 실패"
            }
        }
        return "전송 실패"
    }

    /// Back-compat: respond to the current head of the queue.
    func respondToApprovalWithOption(_ optionLabel: String, index: Int) {
        guard let approval = pendingApproval else { return }
        respond(to: approval, optionLabel: optionLabel, index: index)
    }

    /// Explicit "allow for this session" — adds a permission rule so it won't ask again.
    func respondAllowSession(_ approval: ApprovalRequest) {
        let permissionId = approval.permissionId ?? ""
        if currentStatus(of: approval) == .submitting { return }
        if !permissionId.isEmpty, resolvedPermissionIds.contains(permissionId) { return }

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        setStatus(.submitting, for: approval)

        let tid = approval.terminalId
        let hash = approval.expectedScreenHash
        let api = conn(approval.bridgeID)?.client ?? bridgeClient
        Task { @MainActor in
            do {
                try await api.respondToApprovalAllowAll(
                    requestId: permissionId, terminalId: tid, expectedScreenHash: hash)
                if !permissionId.isEmpty { resolvedPermissionIds.insert(permissionId) }
                clearPendingApproval(for: approval)
            } catch {
                setStatus(.failed, for: approval, error: friendlyError(error))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Send command

    /// Sends a text command to the bridge (iOS equivalent of watchOS voice input).
    /// Send a prompt to a hook session's agent. Transactional: returns false on
    /// failure (the caller keeps the text in the input for retry) and only marks
    /// the session "thinking" once the bridge accepted it.
    @discardableResult
    func sendCommand(text: String, sessionId: String? = nil) async -> Bool {
        // No explicit session → fall back to a running session on the FOCUSED Mac
        // (never a random other bridge's session).
        let sid = sessionId ?? sessions.first(where: { $0.activity == .running && $0.bridgeID == focusedBridgeID })?.id

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        do {
            try await client(forSession: sid).sendCommand(text: text + "\n", sessionId: sid)
            // Echo the command into the transcript ONLY after the bridge accepts
            // it — appending before the send duplicated the line on retry.
            let cmdLine = TerminalLine(text: "> \(text)", type: .userPrompt, sessionId: sid)
            terminalBuffer.append(cmdLine)
            appendToSession(cmdLine, sessionId: sid)
            setThinking(true, sessionId: sid)
            recentTerminalLines = terminalBuffer.getLast(15)
            return true
        } catch {
            let errLine = TerminalLine(text: "✗ 전송 실패 — 다시 시도하세요", type: .error, sessionId: sid)
            terminalBuffer.append(errLine)
            appendToSession(errLine, sessionId: sid)
            recentTerminalLines = terminalBuffer.getLast(15)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    // MARK: - Clear terminal

    func clearTerminal(sessionId: String? = nil) {
        if let sid = sessionId,
           let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].terminalLines.removeAll()
        }
        terminalBuffer.clear()
        recentTerminalLines = []
        setThinking(false, sessionId: sessionId)
    }

    // MARK: - Helpers (approval)

    private func clearPendingApproval(for approval: ApprovalRequest) {
        approvalQueue.removeAll { $0.dedupeKey == approval.dedupeKey }
        pendingApproval = approvalQueue.first
        for idx in sessions.indices {
            if sessions[idx].pendingApproval?.permissionId == approval.permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
    }

    /// Server told us an approval was resolved/timed-out elsewhere (or on another
    /// device) — drop it from the queue + sessions so the card disappears.
    private func handlePermissionCleared(_ data: String) {
        guard let json = parseJSON(data),
              let permissionId = json["permissionId"] as? String else { return }
        resolvedPermissionIds.insert(permissionId) // ignore any late re-send
        approvalQueue.removeAll { $0.permissionId == permissionId }
        pendingApproval = approvalQueue.first
        for idx in sessions.indices {
            if sessions[idx].pendingApproval?.permissionId == permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
    }

    /// The bridge's authoritative pending-approval set (sent on every reconnect).
    /// Drop any of THIS bridge's cards the bridge no longer considers pending —
    /// they were answered on the PC, resolved while we were away, or orphaned
    /// across a bridge restart, and would otherwise linger as zombie cards.
    private func handlePermissionSync(_ data: String, bridgeID: UUID) {
        guard let json = parseJSON(data) else { return }
        let live = Set((json["permissionIds"] as? [String]) ?? [])
        approvalQueue.removeAll { a in
            a.bridgeID == bridgeID && (a.permissionId.map { !live.contains($0) } ?? false)
        }
        pendingApproval = approvalQueue.first
        for idx in sessions.indices where sessions[idx].bridgeID == bridgeID {
            if let pid = sessions[idx].pendingApproval?.permissionId, !live.contains(pid) {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
    }

    private func appendToSession(_ line: TerminalLine, sessionId: String?) {
        guard let sid = sessionId,
              let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }
        sessions[idx].terminalLines.append(line)
        if sessions[idx].terminalLines.count > 500 {
            sessions[idx].terminalLines.removeFirst(sessions[idx].terminalLines.count - 500)
        }
    }

    private func handleSessionEvent(_ data: String, bridgeID: UUID) {
        guard let json = parseJSON(data),
              let state = json["state"] as? String else { return }

        let sessionId = json["sessionId"] as? String
        let agent = json["agent"] as? String
        let cwd = json["cwd"] as? String ?? ""
        let folderName = json["folderName"] as? String ?? ""

        switch state {
        case "running":
            sessionStartDate = Date()
            if let sid = sessionId {
                if let idx = sessions.firstIndex(where: { $0.id == sid && $0.bridgeID == bridgeID }) {
                    sessions[idx].activity = .running
                } else {
                    let agentType = AgentType(rawValue: agent ?? "claude") ?? .claude
                    sessions.append(AgentSession(
                        id: sid, agent: agentType, cwd: cwd,
                        folderName: folderName, activity: .running, bridgeID: bridgeID
                    ))
                }
            }
        case "ended":
            setThinking(false, sessionId: sessionId)
            stopElapsedTimer()
            notificationService.postTaskComplete()
            if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid && $0.bridgeID == bridgeID }) {
                sessions[idx].activity = .ended
            }
        case "connected":
            recomputeConnectionState()
        default:
            break
        }

        resolvePendingDeepLink()   // a cold-launch deep link may be waiting for this session
        updateWatchState()
    }

    private func handleToolOutput(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let toolName = json["tool_name"] as? String ?? "tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let toolOutput = json["tool_output"] as? String
        let sessionId = json["sessionId"] as? String
        let source = json["source"] as? String ?? "claude"
        let prefix = source == "codex" ? "[codex] " : ""

        // Format like a real terminal: show what Claude did and the result
        var lines: [TerminalLine] = []

        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)$ \(cmd)", type: .command, sessionId: sessionId))
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let outputLines = output.components(separatedBy: "\n")
                for line in outputLines.prefix(10) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append(TerminalLine(text: cleaned, type: .output, sessionId: sessionId))
                    }
                }
                if outputLines.count > 10 {
                    lines.append(TerminalLine(text: "  ... (\(outputLines.count - 10) more lines)", type: .system, sessionId: sessionId))
                }
            }

        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Read \(filename)", type: .tool, sessionId: sessionId))

        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Write \(filename)", type: .tool, sessionId: sessionId))

        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            let oldStr = toolInput["old_string"] as? String ?? ""
            let newStr = toolInput["new_string"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)Edit \(filename)", type: .tool, sessionId: sessionId))
            if !oldStr.isEmpty {
                let preview = oldStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  - \(String(preview.prefix(60)))", type: .error, sessionId: sessionId))
            }
            if !newStr.isEmpty {
                let preview = newStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  + \(String(preview.prefix(60)))", type: .output, sessionId: sessionId))
            }

        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)grep \"\(pattern)\"", type: .tool, sessionId: sessionId))
            if let output = toolOutput, !output.isEmpty {
                let resultLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                lines.append(TerminalLine(text: "  \(resultLines.count) matches", type: .system, sessionId: sessionId))
            }

        case "Glob":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)find \"\(pattern)\"", type: .tool, sessionId: sessionId))

        case "CodexMessage":
            if let output = toolOutput {
                lines.append(TerminalLine(text: "\(prefix)\(String(output.prefix(100)))", type: .output, sessionId: sessionId))
            }

        case "Task":
            // A sub-agent the main agent spawned — show its type + task distinctly
            // so its work isn't confused with the main agent's own actions.
            let subType = toolInput["subagent_type"] as? String ?? "agent"
            let desc = toolInput["description"] as? String
                ?? toolInput["prompt"] as? String
                ?? ""
            let header = desc.isEmpty ? "서브에이전트 [\(subType)]" : "서브에이전트 [\(subType)] · \(desc)"
            lines.append(TerminalLine(text: "\(prefix)\(header)", type: .subagent, sessionId: sessionId))
            if let output = toolOutput {
                for raw in output.components(separatedBy: "\n").prefix(8) {
                    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append(TerminalLine(text: "  \(cleaned)", type: .output, sessionId: sessionId))
                    }
                }
            }

        default:
            lines.append(TerminalLine(text: "\(prefix)[\(toolName)]", type: .tool, sessionId: sessionId))
            if let output = toolOutput {
                let preview = String(output.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    lines.append(TerminalLine(text: preview, type: .output, sessionId: sessionId))
                }
            }
        }

        for line in lines {
            terminalBuffer.append(line)
            pendingTerminalLines.append(line)
            appendToSession(line, sessionId: sessionId)
        }

        // Mark as thinking (cursor will be shown in the view)
        setThinking(true, sessionId: sessionId)

        recentTerminalLines = terminalBuffer.getLast(10)
        scheduleBatchSend()
    }

    private func handleTaskComplete(_ data: String) {
        let sid = parseJSON(data)?["sessionId"] as? String
        setThinking(false, sessionId: sid)
        let line = TerminalLine(text: "Task completed", type: .system, sessionId: sid)
        terminalBuffer.append(line)
        appendToSession(line, sessionId: sid)
        recentTerminalLines = terminalBuffer.getLast(15)
        notificationService.postTaskComplete()
        updateWatchState()
    }

    private func handleError(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let sid = json["sessionId"] as? String
        let errorMsg = json["error"] as? String ?? "Unknown error"
        let line = TerminalLine(text: errorMsg, type: .error, sessionId: sid)
        terminalBuffer.append(line)
        appendToSession(line, sessionId: sid)
        recentTerminalLines = terminalBuffer.getLast(15)
    }

    private func handleStop(_ data: String) {
        let json = parseJSON(data)
        let sessionId = json?["sessionId"] as? String
        setThinking(false, sessionId: sessionId)

        // Reasoning first (when extended thinking is on) — shown distinctly above
        // the answer so the user can tell the AI's thought process from its reply.
        if let thinking = json?["thinkingText"] as? String,
           !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let head = TerminalLine(text: "💭 사고 과정", type: .reasoning, sessionId: sessionId)
            terminalBuffer.append(head)
            appendToSession(head, sessionId: sessionId)
            pendingTerminalLines.append(head)
            for raw in thinking.components(separatedBy: "\n") {
                let line = TerminalLine(text: raw, type: .reasoning, sessionId: sessionId)
                terminalBuffer.append(line)
                appendToSession(line, sessionId: sessionId)
                pendingTerminalLines.append(line)
            }
        }

        // Render Claude's final answer. The bridge reads it from the transcript
        // on Stop and forwards it as `assistantText` — this is the only place the
        // reply text appears (tool actions arrive separately via tool-output).
        if let answer = json?["assistantText"] as? String,
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for raw in answer.components(separatedBy: "\n") {
                let line = TerminalLine(text: raw, type: .assistant, sessionId: sessionId)
                terminalBuffer.append(line)
                appendToSession(line, sessionId: sessionId)
                pendingTerminalLines.append(line)
            }
        }

        let stopLine = TerminalLine(text: "Session stopped", type: .system, sessionId: sessionId)
        terminalBuffer.append(stopLine)
        appendToSession(stopLine, sessionId: sessionId)
        recentTerminalLines = terminalBuffer.getLast(15)
        scheduleBatchSend()
        updateWatchState()
    }

    // MARK: - Watch communication

    private func setupWatchMessageHandler() {
        sessionManager.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                self?.handleWatchMessage(message)
            }
        }
    }

    private func handleWatchMessage(_ message: WatchMessage) {
        switch message {
        case .voiceCommand(let cmd):
            // Forward voice command to bridge as PTY input
            Task {
                try? await bridgeClient.sendCommand(text: cmd.transcribedText + "\n")
            }

        case .approvalResponse(let response):
            // Forward approval response to bridge
            let key = "pending_permission_\(response.requestId.uuidString)"
            if let permissionId = UserDefaults.standard.string(forKey: key) {
                Task {
                    try? await bridgeClient.respondToApproval(
                        requestId: permissionId,
                        allow: response.approved
                    )
                }
                UserDefaults.standard.removeObject(forKey: key)
            }

        default:
            break
        }
    }

    private func updateWatchState() {
        let state = SessionState(
            connection: connectionState,
            activity: currentActivity,
            machineName: machineName,
            modelName: modelName,
            workingDirectory: workingDirectory,
            elapsedSeconds: elapsedSeconds,
            filesChanged: 0,
            linesAdded: 0,
            transportMode: .lan
        )

        sessionManager.updateApplicationContext(with: state)
    }

    private var currentActivity: SessionActivity {
        switch connectionState {
        case .connected: return .running
        case .degraded: return .running   // still alive, just no realtime stream
        case .connecting: return .idle
        case .disconnected: return .ended
        case .iPhoneUnreachable: return .idle
        }
    }

    // MARK: - Terminal batching

    private func scheduleBatchSend() {
        guard terminalBatchTimer == nil else { return }

        terminalBatchTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushTerminalBatch()
            }
        }
    }

    private func flushTerminalBatch() {
        terminalBatchTimer = nil

        guard !pendingTerminalLines.isEmpty else { return }

        let lines = pendingTerminalLines
        pendingTerminalLines = []

        let update = WatchMessage.TerminalUpdate(lines: lines)
        let message = WatchMessage.terminalUpdate(update)
        sessionManager.send(message)
    }

    // MARK: - Elapsed time

    private func startElapsedTimer() {
        sessionStartDate = sessionStartDate ?? Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartDate else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - JSON helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// One live bridge connection: a configured HTTP client + its own SSE stream.
/// RelayService holds several so multiple Macs stay connected simultaneously.
@MainActor
final class BridgeConnection {
    let id: UUID
    var name: String
    let client = BridgeClient()
    let sse = SSEClient()

    init(saved: SavedConnection) {
        self.id = saved.id
        self.name = saved.name
        client.setEndpoint(host: saved.host, port: UInt16(saved.port), token: saved.token)
    }
}
