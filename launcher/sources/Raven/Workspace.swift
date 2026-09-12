import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
final class Workspace {
    let store: ProviderStore

    var destination: Destination = .library
    var search = ""

    var providerDraft: ProviderDraft?
    var windowDraft: WindowDraft?
    var pendingRemoval: Provider?
    var launchError: String?
    var isChoosingWorkdir = false
    var isShowingScript = false
    var isLaunching = false
    var didCopyScript = false

    init(store: ProviderStore) {
        self.store = store
    }

    var query: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var isSearching: Bool { !query.isEmpty }

    var focusedProvider: Provider? {
        guard case .provider(let id) = destination else { return nil }
        return store.provider(id: id)
    }

    var activeProvider: Provider? {
        focusedProvider ?? store.selectedItem?.provider
    }

    var title: String {
        switch destination {
        case .library: "All Models"
        case .pinned: "Pinned"
        case .recents: "Recents"
        case .provider(let id): store.provider(id: id)?.name ?? "Provider"
        }
    }

    var visibleRecents: [RecentLaunch] {
        guard isSearching else { return store.recents }
        return store.recents.filter {
            $0.modelID.lowercased().contains(query)
                || $0.folderName.lowercased().contains(query)
                || $0.client.displayName.lowercased().contains(query)
        }
    }

    var subtitle: String {
        if case .recents = destination {
            let count = visibleRecents.count
            if isSearching { return count == 1 ? "1 match" : "\(count) matches" }
            return count == 0 ? "No launches yet" : (count == 1 ? "1 launch" : "\(count) launches")
        }
        let shown = sections.reduce(0) { $0 + $1.items.count }
        if isSearching {
            return shown == 1 ? "1 match" : "\(shown) matches"
        }
        if let provider = focusedProvider {
            return "\(store.status(of: provider).subtitle) · \(provider.host)"
        }
        if case .pinned = destination {
            return shown == 1 ? "1 model" : "\(shown) models"
        }
        let providers = store.providers.count
        let label = shown == 1 ? "1 model" : "\(shown) models"
        return providers == 1 ? label : "\(label) · \(providers) providers"
    }

    private func matches(_ item: ModelItem) -> Bool {
        guard isSearching else { return true }
        return item.entry.modelID.lowercased().contains(query)
            || item.entry.owner.lowercased().contains(query)
            || item.provider.name.lowercased().contains(query)
    }

    private func byProvider(_ items: [ModelItem]) -> [ModelSection] {
        store.providers.compactMap { provider in
            let owned = items.filter { $0.provider.id == provider.id }
            return owned.isEmpty ? nil : ModelSection(kind: .provider(provider), items: owned)
        }
    }

    var sections: [ModelSection] {
        switch destination {
        case .recents:
            return []
        case .pinned:
            return byProvider(store.pinnedItems.filter(matches))
        case .library:
            return byProvider(store.libraryItems.filter(matches))
        case .provider(let id):
            guard let provider = store.provider(id: id) else { return [] }
            let items = store.items(of: provider).filter(matches)
            return Dictionary(grouping: items) { $0.entry.owner }
                .map { ModelSection(kind: .owner($0.key), items: $0.value) }
                .sorted { $0.kind.title.localizedStandardCompare($1.kind.title) == .orderedAscending }
        }
    }

    var isEmptyResult: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }

    var isConfirmingRemoval: Bool {
        get { pendingRemoval != nil }
        set { if !newValue { pendingRemoval = nil } }
    }

    var isShowingLaunchError: Bool {
        get { launchError != nil }
        set { if !newValue { launchError = nil } }
    }

    func addProvider() {
        providerDraft = ProviderDraft()
    }

    func addLocalProxy() {
        providerDraft = .localProxy()
    }

    func edit(_ provider: Provider) {
        providerDraft = ProviderDraft(provider)
    }

    func commitProviderDraft() {
        guard let draft = providerDraft, let provider = store.apply(draft) else { return }
        providerDraft = nil
        destination = .provider(provider.id)
    }

    func confirmRemoval(of provider: Provider) {
        pendingRemoval = provider
    }

    func removePendingProvider() {
        guard let provider = pendingRemoval else { return }
        if focusedProvider?.id == provider.id {
            destination = .library
        }
        store.removeProvider(provider)
        pendingRemoval = nil
    }

    func refresh(_ provider: Provider) {
        Task { await store.refresh(provider) }
    }

    func refreshActive() {
        if let provider = activeProvider {
            Task { await store.refresh(provider) }
        } else {
            Task { await store.refreshAll() }
        }
    }

    func refreshAll() {
        Task { await store.refreshAll() }
    }

    func beginEditingWindow(_ item: ModelItem) {
        windowDraft = WindowDraft(providerID: item.provider.id,
                                  modelID: item.entry.modelID,
                                  current: store.effectiveWindow(item),
                                  advertised: item.entry.contextWindow)
    }

    func commitWindowDraft() {
        guard let draft = windowDraft else { return }
        store.apply(draft)
        windowDraft = nil
    }

    func setWindow(_ item: ModelItem, tokens: Int?) {
        store.setWindowOverride(item.ref, tokens: tokens)
    }

    func launch(_ item: ModelItem? = nil) {
        if let item { store.selection = item.ref }
        guard store.canLaunch, !isLaunching else { return }
        isLaunching = true
        Task {
            defer { isLaunching = false }
            do {
                try await store.launch()
            } catch {
                launchError = error.localizedDescription
            }
        }
    }

    func restore(_ recent: RecentLaunch) {
        store.restore(recent)
    }

    func relaunch(_ recent: RecentLaunch) {
        store.restore(recent)
        launch()
    }

    func chooseWorkdir() {
        isChoosingWorkdir = true
    }

    func copyScript() {
        guard let script = store.launchScript() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        didCopyScript = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            didCopyScript = false
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([ProviderStore.configFile])
    }

    func revealWorkdir() {
        NSWorkspace.shared.activateFileViewerSelecting([store.workdir])
    }
}
