import SwiftUI

struct QuickLaunchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    @State private var text = ""
    @State private var highlighted: ModelRef?
    @FocusState private var focused: Bool

    private var results: [ModelItem] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        let pinned = Set(store.pinned)
        let recentRefs = store.recents.map(\.ref)
        func priority(_ item: ModelItem) -> Int {
            if pinned.contains(item.ref) { return 0 }
            if recentRefs.contains(item.ref) { return 1 }
            return 2
        }
        let filtered = store.libraryItems.filter { item in
            needle.isEmpty
                || item.entry.modelID.lowercased().contains(needle)
                || item.provider.name.lowercased().contains(needle)
                || item.entry.owner.lowercased().contains(needle)
        }
        let ranked = filtered.sorted { lhs, rhs in
            let left = needle.isEmpty ? priority(lhs) : (lhs.entry.modelID.lowercased().hasPrefix(needle) ? 0 : 1)
            let right = needle.isEmpty ? priority(rhs) : (rhs.entry.modelID.lowercased().hasPrefix(needle) ? 0 : 1)
            if left != right { return left < right }
            return lhs.entry.modelID.localizedStandardCompare(rhs.entry.modelID) == .orderedAscending
        }
        return Array(ranked.prefix(80))
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Image(systemName: "bolt.fill").foregroundStyle(.tint)
                TextField("Launch a model…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { launch(list) }
                    .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
                    .onKeyPress(.escape) { app.sheet = nil; return .handled }
                Picker("Client", selection: Binding(get: { store.client }, set: { store.client = $0 })) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(Space.lg)

            Divider()

            if list.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $highlighted) {
                        ForEach(list) { item in
                            QuickRow(item: item)
                                .tag(item.ref)
                                .contentShape(Rectangle())
                                .onTapGesture { app.sheet = nil; app.launch(item) }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: highlighted) { _, ref in
                        if let ref { proxy.scrollTo(ref) }
                    }
                }
            }

            Divider()

            HStack(spacing: Space.md) {
                Label(store.workdirLabel, systemImage: "folder")
                Spacer()
                Text("↑↓ Navigate").foregroundStyle(.tertiary)
                Text("↩ Launch").foregroundStyle(.tertiary)
                Text("esc Close").foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
        }
        .frame(width: 620, height: 460)
        .onAppear {
            focused = true
            highlighted = results.first?.ref
        }
        .onChange(of: text) { _, _ in highlighted = results.first?.ref }
    }

    private func move(_ delta: Int, in list: [ModelItem]) {
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.ref == highlighted } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(current + delta, 0), list.count - 1)
        highlighted = list[next].ref
    }

    private func launch(_ list: [ModelItem]) {
        guard let item = list.first(where: { $0.ref == highlighted }) ?? list.first else { return }
        app.sheet = nil
        app.launch(item)
    }
}

private struct QuickRow: View {
    @Environment(ProviderStore.self) private var store
    let item: ModelItem

    var body: some View {
        HStack(spacing: Space.md) {
            FamilyGlyph(family: item.entry.family, size: 24)
            Text(item.entry.modelID)
                .font(.identifier)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if store.isPinned(item) {
                Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(.orange)
            }
            Text(item.provider.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
