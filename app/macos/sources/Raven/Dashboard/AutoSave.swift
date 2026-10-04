import Foundation
import Observation

@MainActor
@Observable
final class AutoSaveScheduler {
    enum Status: Equatable {
        case idle, saving, saved, failed(String)
    }

    typealias Save = @MainActor () async throws -> Void

    private(set) var status: Status = .idle

    private var timer: Task<Void, Never>?
    private var pending: Save?
    private var running: Task<Void, Never>?

    func schedule(_ save: @escaping Save) {
        timer?.cancel()
        pending = save
        status = .saving
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    @discardableResult
    func flush() async -> Bool {
        timer?.cancel()
        timer = nil
        await drain()
        if case .failed = status { return false }
        return true
    }

    private func drain() async {
        while true {
            if let running {
                await running.value
                continue
            }
            guard let save = pending else { return }
            pending = nil
            let job = Task { [weak self] in
                do {
                    try await save()
                    self?.finish(nil)
                } catch {
                    self?.finish((error as? PanelError)?.noticeText ?? error.localizedDescription)
                }
                self?.running = nil
            }
            running = job
            await job.value
        }
    }

    private func finish(_ failure: String?) {
        guard pending == nil else { return }
        if let failure {
            status = .failed(failure)
        } else {
            status = .saved
        }
    }
}
