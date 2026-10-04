import Observation
import SwiftUI

enum InteractionFeedbackKind: Equatable {
    case selection
    case success
    case warning
    case error
}

struct InteractionFeedbackEvent: Equatable {
    let id = UUID()
    let kind: InteractionFeedbackKind
}

struct InteractionBanner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
    let offersUndo: Bool
}

@MainActor
@Observable
final class InteractionCoordinator {
    private(set) var selectionCount: Int?
    private(set) var addSelectionRequest = 0
    private(set) var cancelSelectionRequest = 0
    private(set) var banner: InteractionBanner?
    private(set) var feedbackEvent: InteractionFeedbackEvent?
    var isCommitting = false

    @ObservationIgnored private var bannerDismissalTask: Task<Void, Never>?
    @ObservationIgnored private var undoAction: (() -> Void)?

    func beginSelection(count: Int = 0) {
        selectionCount = count
    }

    func updateSelection(count: Int, announceChange: Bool = true) {
        selectionCount = count
        if announceChange {
            feedbackEvent = InteractionFeedbackEvent(kind: .selection)
        }
    }

    func announceSelectionChange() {
        feedbackEvent = InteractionFeedbackEvent(kind: .selection)
    }

    func endSelection() {
        selectionCount = nil
        isCommitting = false
    }

    func requestAddSelection() {
        guard selectionCount ?? 0 > 0, !isCommitting else { return }
        addSelectionRequest += 1
    }

    func requestCancelSelection() {
        cancelSelectionRequest += 1
    }

    func showSuccess(_ message: String) {
        presentBanner(
            InteractionBanner(
                message: message,
                systemImage: "checkmark.circle.fill",
                offersUndo: false
            ),
            feedback: .success
        )
    }

    func showRemoval(_ message: String, undo: @escaping () -> Void) {
        undoAction = undo
        presentBanner(
            InteractionBanner(
                message: message,
                systemImage: "trash.fill",
                offersUndo: true
            ),
            feedback: .warning
        )
    }

    func showError(_ message: String) {
        presentBanner(
            InteractionBanner(
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                offersUndo: false
            ),
            feedback: .error
        )
    }

    func performUndo() {
        guard let undoAction else { return }
        self.undoAction = nil
        bannerDismissalTask?.cancel()
        banner = nil
        undoAction()
    }

    func dismissBanner() {
        bannerDismissalTask?.cancel()
        bannerDismissalTask = nil
        undoAction = nil
        banner = nil
    }

    private func presentBanner(
        _ newBanner: InteractionBanner,
        feedback: InteractionFeedbackKind
    ) {
        bannerDismissalTask?.cancel()
        undoAction = newBanner.offersUndo ? undoAction : nil
        banner = newBanner
        feedbackEvent = InteractionFeedbackEvent(kind: feedback)

        bannerDismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismissBanner()
        }
    }
}
