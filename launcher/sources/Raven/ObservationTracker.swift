import Foundation
import Observation

@MainActor
final class ObservationTracker {
    private var apply: (@MainActor () -> Void)?
    private var stopped = true
    private var scheduled = false

    init() {}

    func start(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        stopped = false
        schedule()
    }

    func resume() {
        guard stopped, apply != nil else { return }
        stopped = false
        schedule()
    }

    func pause() {
        stopped = true
    }

    func stop() {
        stopped = true
        apply = nil
    }

    func refresh() {
        guard !stopped, apply != nil else { return }
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.observe()
        }
    }

    private func observe() {
        guard !stopped, let apply else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.schedule()
            }
        }
    }
}
