import AppKit
import SwiftUI

@Observable
final class ModelFiller {
    static let shared = ModelFiller()

    private(set) var done = 0
    private(set) var total = 0
    private(set) var note: String?
    private var task: Task<Void, Never>?

    var running: Bool { task != nil }

    func fill(_ source: RouteSource, rows: [Int]) {
        guard task == nil else { return }
        let store = ProvidersPanelStore.shared
        let models = store.entry(source)?.models ?? []
        let targets = rows.sorted().compactMap { row -> (Int, String)? in
            guard row < models.count else { return nil }
            let name = models[row].name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (row, models[row].name)
        }
        guard !targets.isEmpty else { return }
        let wantsEfforts = source != .channel("antigravity")
        let known = store.effortLevels
        done = 0
        total = targets.count
        note = nil
        task = Task { [weak self] in
            var failure: String?
            for (row, name) in targets {
                guard !Task.isCancelled else { break }
                do {
                    let lookup = try await store.fetchModelsDev(model: name)
                    let efforts = wantsEfforts ? lookup.efforts : []
                    if lookup.context != nil || !efforts.isEmpty {
                        store.updateModel(source, at: row) { model in
                            guard model.name == name else { return }
                            if !efforts.isEmpty {
                                let custom = (model.thinking?.levels ?? []).filter { !known.contains($0) && !efforts.contains($0) }
                                model = PanelLogic.withLevels(model, next: efforts + custom)
                            }
                            if let window = lookup.context { model = PanelLogic.withContext(model, tokens: window) }
                        }
                    }
                } catch PanelError.api(code: "model_not_found", _) {
                } catch {
                    failure = (error as? PanelError)?.noticeText ?? error.localizedDescription
                }
                self?.done += 1
            }
            self?.finish(failure: failure)
        }
    }

    private func finish(failure: String?) {
        task = nil
        note = failure
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        note = nil
    }
}

struct ContextCell: View {
    let value: Int?
    let commit: (Int?) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Context", text: Binding(
            get: { draft ?? value.map(PanelFormats.formatContextWindow) ?? "" },
            set: { draft = $0 }), prompt: Text("Default"))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.figure)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .help("Window the client compacts against, e.g. 200k or 1m. It never caps what Raven forwards.")
    }

    private func save() {
        guard let text = draft else { return }
        draft = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if value != nil { commit(nil) }
        } else if let tokens = PanelFormats.parseTokenCount(trimmed) {
            if tokens != value { commit(tokens) }
        } else {
            NSSound.beep()
        }
    }
}

struct EffortPicker: View {
    private let store = ProvidersPanelStore.shared
    let source: RouteSource
    let index: Int

    var body: some View {
        let model = store.entry(source).flatMap { index < $0.models.count ? $0.models[index] : nil }
        let levels = model?.thinking?.levels ?? []
        let order = store.effortLevels
        let custom = levels.filter { !order.contains($0) }
        VStack(alignment: .leading, spacing: Space.md) {
            let all = order + custom
            Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.sm) {
                ForEach(Array(stride(from: 0, to: all.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(all[start..<min(start + 2, all.count)], id: \.self) { level in
                            Toggle(level, isOn: Binding(get: { levels.contains(level) }, set: { _ in toggle(level) }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack {
                Button("Allow All") {
                    store.updateModel(source, at: index) { $0 = PanelLogic.withLevels($0, next: []) }
                }
                .disabled(levels.isEmpty)
                Spacer()
            }
        }
    }

    private func toggle(_ level: String) {
        let order = store.effortLevels
        store.updateModel(source, at: index) { model in
            var current = model.thinking?.levels ?? []
            if current.contains(level) { current.removeAll { $0 == level } } else { current.append(level) }
            model = PanelLogic.withLevels(model, next: RoutingTable.ordered(current, order: order))
        }
    }
}
