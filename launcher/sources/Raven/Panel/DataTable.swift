import SwiftUI

@Observable
final class DataTableState {
    var sortColumn: Int?
    var sortAscending = true
    var page = 0
    var pageSize = 15
    var query = ""
    var initialized = false
}

struct DataColumn {
    var title: String
    var width: CGFloat
    var alignsRight: Bool
    var compare: ((Int, Int) -> Bool)?
    var cell: (Int) -> AnyView

    init(title: String,
         width: CGFloat,
         alignsRight: Bool = false,
         compare: ((Int, Int) -> Bool)? = nil,
         cell: @escaping (Int) -> AnyView) {
        self.title = title
        self.width = width
        self.alignsRight = alignsRight
        self.compare = compare
        self.cell = cell
    }
}

func columnByText(_ key: @escaping (Int) -> String) -> (Int, Int) -> Bool {
    { a, b in key(a).localizedCompare(key(b)) == .orderedAscending }
}

func columnByNumber(_ key: @escaping (Int) -> Double) -> (Int, Int) -> Bool {
    { a, b in key(a) < key(b) }
}

struct DataTable: View {
    var columns: [DataColumn]
    var rowCount: Int
    var state: DataTableState
    var footerCell: ((Int) -> AnyView)?
    var pagination = false
    var hidePaginationOnSinglePage = false
    var pageSizes: [Int] = [15, 30, 50]
    var emptyMessage: String? = "No results."
    var minHeight: CGFloat = 88
    var maxHeight: CGFloat = 420
    var initialSort: (column: Int, ascending: Bool)?
    var filter: ((Int) -> String)?
    var rowMenu: ((Int) -> AnyView)?

    private let rowHeight: CGFloat = 26
    private let headerHeight: CGFloat = 26
    private let rowPitch: CGFloat = 27

    var body: some View {
        let ordered = order
        let pages = totalPages(ordered)
        let currentPage = min(max(0, state.page), pages - 1)
        let visible = visibleIndices(ordered, currentPage: currentPage)
        let paginationShown = pagination && !(hidePaginationOnSinglePage && ordered.count <= state.pageSize)
        return VStack(alignment: .leading, spacing: 6) {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if visible.isEmpty, let emptyMessage {
                            Text(emptyMessage)
                                .font(RavenFont.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 64)
                        }
                        ForEach(visible, id: \.self) { row in
                            rowView(row)
                        }
                        if footerCell != nil {
                            footerRow
                        }
                    } header: {
                        headerRow
                    }
                }
                .frame(minWidth: contentWidth, alignment: .leading)
            }
            .frame(height: tableHeight(visibleCount: visible.count))

            if paginationShown {
                paginationBar(ordered: ordered, pages: pages, currentPage: currentPage)
            }
        }
        .onAppear(perform: applyInitialSort)
    }

    private var contentWidth: CGFloat {
        columns.reduce(0) { $0 + $1.width }
    }

    private var order: [Int] {
        var indices = Array(0..<rowCount)
        if let filter {
            let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
            if !query.isEmpty {
                indices = indices.filter { filter($0).lowercased().contains(query) }
            }
        }
        if let column = state.sortColumn, columns.indices.contains(column), let compare = columns[column].compare {
            let ascending = state.sortAscending
            indices.sort { a, b in
                if ascending {
                    if compare(a, b) { return true }
                    if compare(b, a) { return false }
                } else {
                    if compare(b, a) { return true }
                    if compare(a, b) { return false }
                }
                return a < b
            }
        }
        return indices
    }

    private func totalPages(_ ordered: [Int]) -> Int {
        max(1, Int(ceil(Double(ordered.count) / Double(max(1, state.pageSize)))))
    }

    private func visibleIndices(_ ordered: [Int], currentPage: Int) -> [Int] {
        guard pagination else { return ordered }
        let start = currentPage * state.pageSize
        let end = min(ordered.count, start + state.pageSize)
        return start < end ? Array(ordered[start..<end]) : []
    }

    private func tableHeight(visibleCount: Int) -> CGFloat {
        var height = headerHeight + 2
        height += CGFloat(visibleCount) * rowPitch
        if footerCell != nil { height += rowPitch }
        return min(max(height, minHeight), maxHeight)
    }

    private func applyInitialSort() {
        guard !state.initialized else { return }
        state.initialized = true
        guard let initialSort, columns.indices.contains(initialSort.column) else { return }
        state.sortColumn = initialSort.column
        state.sortAscending = initialSort.ascending
    }

    private func toggleSort(_ column: Int) {
        guard columns[column].compare != nil else { return }
        if state.sortColumn == column {
            state.sortAscending.toggle()
        } else {
            state.sortColumn = column
            state.sortAscending = true
        }
        state.page = 0
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { column in
                headerCell(column)
            }
        }
        .frame(height: headerHeight)
        .background(.bar)
    }

    private func headerCell(_ column: Int) -> some View {
        let spec = columns[column]
        return Button {
            toggleSort(column)
        } label: {
            HStack(spacing: 3) {
                if spec.alignsRight { Spacer(minLength: 0) }
                Text(spec.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if state.sortColumn == column {
                    Image(systemName: state.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if !spec.alignsRight { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 4)
            .frame(width: spec.width, height: headerHeight, alignment: spec.alignsRight ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(spec.compare == nil)
    }

    @ViewBuilder
    private func rowView(_ row: Int) -> some View {
        let content = HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { column in
                let spec = columns[column]
                spec.cell(row)
                    .padding(.horizontal, 4)
                    .frame(width: spec.width, height: rowHeight, alignment: spec.alignsRight ? .trailing : .leading)
            }
        }
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary.opacity(0.5))
                .frame(height: 1)
        }

        if let rowMenu {
            content.contextMenu { rowMenu(row) }
        } else {
            content
        }
    }

    private var footerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { column in
                let spec = columns[column]
                Group {
                    if let footerCell {
                        footerCell(column)
                    } else {
                        EmptyView()
                    }
                }
                .padding(.horizontal, 4)
                .frame(width: spec.width, height: rowHeight, alignment: spec.alignsRight ? .trailing : .leading)
            }
        }
        .frame(height: rowHeight)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(
            get: { state.pageSize },
            set: { state.pageSize = $0; state.page = 0 })
    }

    private func paginationBar(ordered: [Int], pages: Int, currentPage: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(ordered.count) row\(ordered.count == 1 ? "" : "s")")
                .font(RavenFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker("Rows per page", selection: pageSizeBinding) {
                ForEach(pageSizes, id: \.self) { size in
                    Text("\(size) / page").tag(size)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Button {
                state.page = max(0, currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .controlSize(.small)
            .disabled(currentPage == 0)
            .help("Previous page")
            ForEach(Array(pageItems(pages: pages, currentPage: currentPage).enumerated()), id: \.offset) { _, item in
                if let number = item {
                    Button("\(number)") {
                        state.page = number - 1
                    }
                    .buttonStyle(.plain)
                    .font(RavenFont.numeric(11))
                    .foregroundStyle(number - 1 == currentPage ? Color.accentColor : .secondary)
                    .frame(minWidth: 20)
                    .help("Page \(number)")
                } else {
                    Text("…")
                        .font(RavenFont.numeric(11))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                state.page = min(pages - 1, currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .controlSize(.small)
            .disabled(currentPage >= pages - 1)
            .help("Next page")
        }
    }

    private func pageItems(pages: Int, currentPage: Int) -> [Int?] {
        if pages <= 7 { return (1...pages).map { $0 } }
        let current = currentPage + 1
        let wanted = Set([1, pages, current - 1, current, current + 1].filter { $0 >= 1 && $0 <= pages })
        var items: [Int?] = []
        var previous = 0
        for number in wanted.sorted() {
            if number - previous > 1 { items.append(nil) }
            items.append(number)
            previous = number
        }
        return items
    }
}
