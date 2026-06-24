import Foundation

struct ApprovalRequest: Identifiable, Codable {
    let id: UUID
    let permissionId: String?
    let toolName: String
    let actionSummary: String
    let timestamp: Date
    var status: ApprovalStatus
    var question: String?
    var options: [OptionItem]

    // Context for the global approval queue (joined from the session/Mac on receipt).
    var sessionId: String? = nil
    var macName: String? = nil
    var cwd: String? = nil
    var agent: String? = nil
    var reason: String? = nil
    /// Which paired Mac (bridge) this approval came from — used to route the
    /// answer back to the right bridge when several are connected at once.
    var bridgeID: UUID? = nil

    // Live-terminal pinning for cmux/codex approvals: the terminal the approval
    // belongs to, and the hash of the screen the user was shown. Sent back on
    // answer so the bridge refuses (409) if the screen changed since.
    var terminalId: String? = nil
    var expectedScreenHash: String? = nil

    /// Last error from a failed answer attempt (status == .failed), for retry UI.
    var lastError: String? = nil

    /// Latest live terminal screen, captured after a 409 (screen changed) so the
    /// user can re-confirm what they're approving before retrying.
    var latestScreen: String? = nil

    /// Stable identity for de-duplicating re-sent approvals (bridge re-sends
    /// pending permission-requests on every SSE reconnect).
    var dedupeKey: String { permissionId ?? id.uuidString }

    enum ApprovalStatus: String, Codable {
        case pending
        case submitting   // answer POST in flight — buttons disabled, spinner shown
        case failed       // answer POST failed — card stays, retry offered
        case approved
        case denied
        case expired
    }

    struct OptionItem: Identifiable, Codable {
        let id: UUID
        let label: String
        let description: String?

        init(label: String, description: String? = nil) {
            self.id = UUID()
            self.label = label
            self.description = description
        }
    }

    /// One AskUserQuestion question — carries multiSelect + its own options so the
    /// app can render checkboxes vs radio, and handle several questions at once.
    struct AskQuestion: Identifiable, Codable, Equatable {
        let id: UUID
        let question: String
        let header: String?
        let multiSelect: Bool
        let options: [OptionItem]

        init(question: String, header: String? = nil, multiSelect: Bool = false, options: [OptionItem] = []) {
            self.id = UUID()
            self.question = question
            self.header = header
            self.multiSelect = multiSelect
            self.options = options
        }

        static func == (lhs: AskQuestion, rhs: AskQuestion) -> Bool { lhs.id == rhs.id }
    }

    /// Full AskUserQuestion question set (nil for standard permissions). When set,
    /// the card renders a collect-then-submit form instead of one-tap buttons.
    var askQuestions: [AskQuestion]? = nil

    init(permissionId: String? = nil, toolName: String, actionSummary: String, question: String? = nil, options: [OptionItem] = [],
         sessionId: String? = nil, macName: String? = nil, cwd: String? = nil, agent: String? = nil, reason: String? = nil,
         terminalId: String? = nil, expectedScreenHash: String? = nil, bridgeID: UUID? = nil,
         askQuestions: [AskQuestion]? = nil) {
        self.id = UUID()
        self.permissionId = permissionId
        self.toolName = toolName
        self.actionSummary = actionSummary
        self.timestamp = Date()
        self.status = .pending
        self.question = question
        self.options = options
        self.sessionId = sessionId
        self.macName = macName
        self.cwd = cwd
        self.agent = agent
        self.reason = reason
        self.terminalId = terminalId
        self.expectedScreenHash = expectedScreenHash
        self.bridgeID = bridgeID
        self.askQuestions = askQuestions
    }
}
