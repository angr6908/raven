import Foundation
import Observation

@MainActor
@Observable
final class AutoSaveScheduler {
    enum Status: Equatable {
        case idle, saving, saved, failed(String)
    }

    private(set) var status: Status = .idle

    private var task: Task<Void, Never>?

    func schedule(_ save: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        status = .saving
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                try await save()
                guard !Task.isCancelled else { return }
                self?.status = .saved
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed((error as? PanelError)?.noticeText ?? error.localizedDescription)
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        status = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
