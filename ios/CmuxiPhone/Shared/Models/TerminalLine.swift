import Foundation

struct TerminalLine: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let type: LineType
    let sessionId: String?

    enum LineType: String, Codable {
        case output      // Tool result / stdout (subordinate to a tool/command)
        case command     // A shell command the agent ran ($ ...)
        case system      // System/feedback messages (connected, stopped, etc.)
        case thinking    // Pulsing cursor indicator
        case error       // Error messages / removed diff lines
        case userPrompt  // What the user typed or said
        case assistant   // The agent's reply text (the actual answer)
        case tool        // A non-shell tool action header (Read/Edit/Write/Grep…)
        case subagent    // A sub-agent (Task tool) invocation header
        case reasoning   // The agent's thinking / reasoning (extended thinking)
    }

    init(text: String, type: LineType = .output, sessionId: String? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.type = type
        self.sessionId = sessionId
    }
}
