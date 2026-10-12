import Foundation
import Observation
import PorchlightCore

/// Requests waiting for the owner's answer: apps asking to connect, and tool calls that need
/// approval. Each waits until it's answered or times out; the prompt panel shows one at a time.
@MainActor @Observable
final class Prompts {
    enum Prompt {
        case pairing(PairingRequest)
        case approval(ToolApprovalRequest)

        var key: String {
            switch self {
            case .pairing(let request): "pairing:\(request.id)"
            case .approval(let request): "approval:\(request.id)"
            }
        }
    }

    /// Apps waiting to connect, oldest first.
    private(set) var pairings: [PairingRequest] = []
    /// Tool calls waiting for approval, oldest first.
    private(set) var approvals: [ToolApprovalRequest] = []
    /// The prompt on screen. Set by the panel as it shows one.
    var shown: String?

    /// Unanswered tool approvals are denied after this long.
    static let approvalTimeout: Duration = .seconds(120)
    /// Requests saved while the Mac was offline have nobody waiting on them: ask for longer.
    static let queuedApprovalTimeout: Duration = .seconds(24 * 3600)
    /// The relay forgets a pairing after this long (its consent page expires).
    static let pairingLifetime: Duration = .seconds(10 * 60)

    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<ToolApproval, Never>] = [:]
    /// Each request's timeout, cancelled when it's answered.
    @ObservationIgnored private var expiries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let log: (String) -> Void
    /// Called whenever the requests change, so the panel can show or hide.
    @ObservationIgnored var onChange: () -> Void = {}

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// What the panel shows: the one already on screen until it's answered, so a new request
    /// (anyone can ask to connect) never takes its place under the owner's cursor. Otherwise
    /// pairings first.
    var current: Prompt? {
        let all = pairings.map(Prompt.pairing) + approvals.map(Prompt.approval)
        return all.first { $0.key == shown } ?? all.first
    }

    var count: Int { pairings.count + approvals.count }

    // MARK: Tool approvals

    /// Waits for the owner's answer. No answer in time is a no.
    func approval(for request: ToolApprovalRequest) async -> ToolApproval {
        await withCheckedContinuation { continuation in
            waiters[request.id] = continuation
            approvals.append(request)
            let timeout = request.queuedAt == nil ? Self.approvalTimeout : Self.queuedApprovalTimeout
            expire(Prompt.approval(request).key, after: timeout) { [weak self] in
                guard let self, self.resolve(request, with: .deny) else { return }
                self.log("No answer about \(request.tool) in time; denied")
            }
            onChange()
        }
    }

    /// Answers a tool call. False if it was already answered (or timed out).
    @discardableResult
    func resolve(_ request: ToolApprovalRequest, with approval: ToolApproval) -> Bool {
        guard let waiter = waiters.removeValue(forKey: request.id) else { return false }
        approvals.removeAll { $0.id == request.id }
        expiries.removeValue(forKey: Prompt.approval(request).key)?.cancel()
        waiter.resume(returning: approval)
        onChange()
        return true
    }

    // MARK: Pairings

    func add(_ pairing: PairingRequest) {
        guard !pairings.contains(where: { $0.id == pairing.id }) else { return }
        pairings.append(pairing)
        expire(Prompt.pairing(pairing).key, after: Self.pairingLifetime) { [weak self] in self?.remove(pairing) }
        onChange()
    }

    func remove(_ pairing: PairingRequest) {
        pairings.removeAll { $0.id == pairing.id }
        expiries.removeValue(forKey: Prompt.pairing(pairing).key)?.cancel()
        onChange()
    }

    /// Porchlight stopped: tool calls are denied, and pairings are dropped (the relay re-sends
    /// those still waiting when it reconnects).
    func clear() {
        for request in approvals { resolve(request, with: .deny) }
        for pairing in pairings { remove(pairing) }
    }

    private func expire(_ key: String, after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        expiries[key] = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    #if DEBUG
    /// For snapshots: a tool call shown as waiting, with nobody awaiting the answer.
    func showSample(_ request: ToolApprovalRequest) {
        approvals.append(request)
    }
    #endif
}
