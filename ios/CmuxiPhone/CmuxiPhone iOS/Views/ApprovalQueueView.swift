import SwiftUI

/// App-wide approval queue: every pending approval across the active Mac's
/// sessions, answerable in one place. Backed by `RelayService.approvalQueue`.
struct ApprovalQueueView: View {
    @EnvironmentObject private var relayService: RelayService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                if relayService.approvalQueue.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(relayService.approvalQueue) { approval in
                                ApprovalCard(approval: approval)
                                    .environmentObject(relayService)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("승인 대기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(Color.claudeOrange)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.statusGreen)
            Text("대기 중인 승인이 없습니다")
                .font(.system(size: 15))
                .foregroundStyle(Color.subtleText)
        }
    }
}

/// A single approval card — context (Mac · project · agent · cwd · reason) plus
/// the agent's option buttons. Shared by the queue and could back per-session UI.
struct ApprovalCard: View {
    let approval: ApprovalRequest
    @EnvironmentObject private var relayService: RelayService
    @State private var selections: [UUID: Set<String>] = [:]   // questionId → chosen labels
    @State private var freeform: [UUID: String] = [:]          // questionId → typed text

    private var projectName: String {
        if let cwd = approval.cwd, !cwd.isEmpty {
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? cwd : leaf
        }
        return "(unknown)"
    }

    private var agentIcon: String {
        switch (approval.agent ?? "").lowercased() {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "sparkles"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Context header — which Mac / project / agent this came from
            HStack(spacing: 6) {
                Image(systemName: agentIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.claudeOrange)
                Text(approval.macName ?? "Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("·").foregroundStyle(Color.subtleText)
                Text(projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtleText)
                Spacer()
            }

            // Question / title
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.claudeAmber)
                    .font(.system(size: 14))
                Text(approval.question ?? "\(approval.toolName) 실행을 승인할까요?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action summary (command / file)
            if !approval.actionSummary.isEmpty && approval.actionSummary != approval.toolName {
                Text(approval.actionSummary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Reason (if the agent supplied one)
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Working directory
            if let cwd = approval.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // AskUserQuestion → collect-then-submit form (handles multiSelect and
            // multiple questions). Standard permissions keep the one-tap buttons.
            if let questions = approval.askQuestions, !questions.isEmpty {
                askQuestionForm(questions)
            } else {
                ForEach(Array(approval.options.enumerated()), id: \.element.id) { index, option in
                    let color = colorForOption(index, total: approval.options.count)
                    Button {
                        relayService.respond(to: approval, optionLabel: option.label, index: index)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                                if let desc = option.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.subtleText)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(color.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(approval.status == .submitting)
                    .opacity(approval.status == .submitting ? 0.5 : 1)
                }
            }

            statusFooter
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.claudeAmber.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch approval.status {
        case .submitting:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("전송 중…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtleText)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.denyRed)
                    Text(approval.lastError ?? "전송 실패 — 위 버튼으로 다시 시도하세요")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.denyRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let screen = approval.latestScreen, !screen.isEmpty {
                    ScrollView {
                        Text(screen.split(separator: "\n").suffix(24).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 130)
                    .padding(8)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: AskUserQuestion form (multiSelect / multiple questions)

    @ViewBuilder
    private func askQuestionForm(_ questions: [ApprovalRequest.AskQuestion]) -> some View {
        ForEach(questions) { q in
            VStack(alignment: .leading, spacing: 6) {
                if questions.count > 1 {
                    Text(q.header ?? q.question)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if q.multiSelect {
                    Text("여러 개 선택 가능")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.subtleText)
                }
                ForEach(q.options) { opt in
                    let selected = (selections[q.id] ?? []).contains(opt.label)
                    Button { toggle(q, opt.label) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: q.multiSelect
                                  ? (selected ? "checkmark.square.fill" : "square")
                                  : (selected ? "largecircle.fill.circle" : "circle"))
                                .font(.system(size: 16))
                                .foregroundStyle(selected ? Color.claudeOrange : Color.subtleText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.label)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                                if let d = opt.description, !d.isEmpty {
                                    Text(d).font(.system(size: 12)).foregroundStyle(Color.subtleText).lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color.claudeOrange.opacity(0.12) : Color.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? Color.claudeOrange.opacity(0.4) : Color.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(approval.status == .submitting)
                }
                TextField("직접 입력…", text: freeformBinding(q.id), axis: .vertical)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary)
                    .tint(Color.claudeOrange)
                    .lineLimit(1...3)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
            }
            .padding(.bottom, 4)
        }

        let ready = allAnswered(questions) && approval.status != .submitting
        Button { submitAnswers(questions) } label: {
            HStack {
                Spacer()
                Text(approval.status == .submitting ? "전송 중…" : "전송")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.vertical, 12)
            .background(ready ? Color.claudeOrange : Color.subtleText.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
    }

    private func toggle(_ q: ApprovalRequest.AskQuestion, _ label: String) {
        var set = selections[q.id] ?? []
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        selections[q.id] = set
    }

    private func freeformBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { freeform[id] ?? "" }, set: { freeform[id] = $0 })
    }

    /// The answer for one question: chosen labels (in option order) + any typed
    /// text, joined by ", ". nil when nothing is selected/typed.
    private func answerFor(_ q: ApprovalRequest.AskQuestion) -> String? {
        let picked = selections[q.id] ?? []
        var parts = q.options.map { $0.label }.filter { picked.contains($0) }
        let typed = (freeform[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func allAnswered(_ questions: [ApprovalRequest.AskQuestion]) -> Bool {
        questions.allSatisfy { answerFor($0) != nil }
    }

    private func submitAnswers(_ questions: [ApprovalRequest.AskQuestion]) {
        var answers: [String: String] = [:]
        for q in questions {
            guard let a = answerFor(q) else { return }
            answers[q.question] = a
        }
        relayService.respondWithAnswers(to: approval, answers: answers)
    }

    private func colorForOption(_ index: Int, total: Int) -> Color {
        // AskUserQuestion options are neutral choices — don't paint the last one
        // red (it isn't a "deny"). Only standard permission prompts get green/red.
        if approval.question != nil { return Color.claudeOrange }
        if total <= 1 { return Color.statusGreen }
        if index == 0 { return Color.statusGreen }
        if index == total - 1 { return Color.denyRed }
        return Color.claudeOrange
    }
}
