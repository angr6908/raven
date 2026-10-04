import SwiftUI

struct RecentsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    @State private var selection: UUID?
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var app = app
        let recents = app.recents()
        Group {
            if store.recents.isEmpty {
                EmptyState(symbol: "clock", title: "No Launches Yet",
                           message: "Every model you launch shows up here so you can pick up where you left off.")
            } else if recents.isEmpty {
                ContentUnavailableView.search(text: app.search)
            } else {
                list(recents)
            }
        }
        .navigationTitle("Recents")
        .navigationSubtitle(subtitle(recents.count))
        .searchable(text: $app.search, placement: .toolbar, prompt: "Filter launches")
        .launchChrome()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Recents", systemImage: "trash") { confirmingClear = true }
                    .disabled(store.recents.isEmpty)
                    .help("Forget every recent launch")
            }
        }
        .confirmationDialog("Clear all recent launches?", isPresented: $confirmingClear) {
            Button("Clear Recents", role: .destructive) { store.clearRecents() }
        }
        .onChange(of: selection) { _, id in
            if let recent = store.recents.first(where: { $0.id == id }) { store.restore(recent) }
        }
    }

    private func list(_ recents: [RecentLaunch]) -> some View {
        List(selection: $selection) {
            ForEach(days(recents), id: \.day) { day in
                Section(day.title) {
                    ForEach(day.items) { recent in
                        RecentRow(recent: recent).tag(recent.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let recent = store.recents.first(where: { $0.id == ids.first }) {
                Button("Launch Again", systemImage: "play.fill") { app.relaunch(recent) }
                Button("Restore Selection", systemImage: "arrow.uturn.backward") { store.restore(recent) }
                Divider()
                Button("Copy Model ID", systemImage: "document.on.document") { app.copy(recent.modelID) }
            }
        } primaryAction: { ids in
            if let recent = store.recents.first(where: { $0.id == ids.first }) { app.relaunch(recent) }
        }
    }

    private struct Day {
        var day: Date
        var title: String
        var items: [RecentLaunch]
    }

    private func days(_ recents: [RecentLaunch]) -> [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recents) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = day.formatted(.dateTime.weekday(.wide).month().day())
            }
            return Day(day: day, title: title, items: grouped[day] ?? [])
        }
    }

    private func subtitle(_ count: Int) -> String {
        if app.isSearching { return count == 1 ? "1 match" : "\(count) matches" }
        return count == 0 ? "No launches yet" : (count == 1 ? "1 launch" : "\(count) launches")
    }
}

private struct RecentRow: View {
    @Environment(AppModel.self) private var app
    @Environment(ProviderStore.self) private var store
    let recent: RecentLaunch

    var body: some View {
        let provider = store.provider(id: recent.providerID)
        HStack(spacing: Space.md) {
            Glyph(symbol: recent.client.symbol, tint: provider?.accent ?? .secondary, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.modelID)
                    .font(.identifier)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Space.xs) {
                    Text(provider?.name ?? "Removed provider")
                    Text("·")
                    Image(systemName: "folder").imageScale(.small)
                    Text(recent.folderName)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Badge(text: recent.client.displayName)
            Text(recent.date, format: .dateTime.hour().minute())
                .font(.figure)
                .foregroundStyle(.secondary)
            Button {
                app.relaunch(recent)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(provider == nil || app.isLaunching)
            .help("Launch this again")
        }
        .padding(.vertical, 3)
        .help(recent.workdir)
    }
}
