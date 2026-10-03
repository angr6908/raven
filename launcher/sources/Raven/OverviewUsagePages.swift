import AppKit

@MainActor
final class OverviewViewController: PanelScrollViewController {
    private let store = UsageStore.shared
    private let tracker = ObservationTracker()

    private let notice = PanelNoticeView()
    private let tokenChart = TokenAreaChartView()
    private let costChart = CostBarChartView()
    private let requestChart = RequestsBarChartView()
    private let statsHost = NSStackView()
    private let statsGlass: NSGlassEffectContainerView
    private let tokenCard: ChartCardView
    private let costCard: ChartCardView
    private let requestCard: ChartCardView
    private let chartRow: NSStackView
    private let loader = CenteredLoaderView(message: "Loading usage…")
    private let emptyState = UnavailableView(symbol: "chart.xyaxis.line",
                                             title: "No usage recorded yet",
                                             description: "Requests proxied through Raven will appear here.")
    private var renderedOnce = false

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        tokenCard = ChartCardView(title: "Token usage",
                                  subtitle: "Input vs output tokens per hour",
                                  chart: tokenChart,
                                  chartHeight: 256,
                                  legend: [
                                      (ChartPalette.output, "Output"),
                                      (ChartPalette.input, "Input"),
                                  ])
        costCard = ChartCardView(title: "Cost over time",
                                 subtitle: "Estimated spend per hour (USD)",
                                 chart: costChart,
                                 chartHeight: 208)
        requestCard = ChartCardView(title: "Requests per hour",
                                    subtitle: "Successful + failed calls",
                                    chart: requestChart,
                                    chartHeight: 208)
        chartRow = NSStackView(views: [costCard, requestCard])
        statsGlass = NSGlassEffectContainerView()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        addFullWidth(notice)
        statsGlass.translatesAutoresizingMaskIntoConstraints = false
        let glassContent = NSView()
        glassContent.translatesAutoresizingMaskIntoConstraints = false
        statsGlass.contentView = glassContent
        statsHost.orientation = .vertical
        statsHost.alignment = .leading
        statsHost.spacing = RavenMetrics.spacing3
        statsHost.translatesAutoresizingMaskIntoConstraints = false
        glassContent.addSubview(statsHost)
        NSLayoutConstraint.activate([
            statsHost.topAnchor.constraint(equalTo: glassContent.topAnchor),
            statsHost.leadingAnchor.constraint(equalTo: glassContent.leadingAnchor),
            statsHost.trailingAnchor.constraint(equalTo: glassContent.trailingAnchor),
            statsHost.bottomAnchor.constraint(equalTo: glassContent.bottomAnchor),
        ])
        addFullWidth(statsGlass)
        buildStats(UsageTotals(), empty: true)
        addFullWidth(tokenCard)
        chartRow.orientation = .horizontal
        chartRow.distribution = .fillEqually
        chartRow.spacing = RavenMetrics.spacing4
        chartRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(chartRow)
        chartRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: RavenMetrics.contentMargin).isActive = true
        chartRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -RavenMetrics.contentMargin).isActive = true
        loader.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        loader.isHidden = true
        emptyState.isHidden = true
        addFullWidth(loader)
        addFullWidth(emptyState)
        setChartsHidden(true)
    }

    private func setChartsHidden(_ hidden: Bool) {
        tokenCard.isHidden = hidden
        chartRow.isHidden = hidden
        statsGlass.isHidden = hidden
    }

    private func setState(loading: Bool, empty: Bool) {
        loader.isHidden = !loading
        emptyState.isHidden = !empty || loading
        setChartsHidden(loading || empty)
    }

    private func buildStats(_ totals: UsageTotals, empty: Bool) {
        let cards = [
            StatCardView(icon: "chart.bar.fill",
                         label: "Total tokens",
                         value: empty ? "—" : PanelFormats.formatTokens(totals.total),
                         sub: empty ? nil : "\(PanelFormats.formatTokens(totals.input)) in · \(PanelFormats.formatTokens(totals.output)) out",
                         badge: nil),
            StatCardView(icon: "bolt.fill",
                         label: "Requests",
                         value: empty ? "—" : String(totals.requests),
                         sub: empty ? nil : "\(totals.usedModels) model\(totals.usedModels == 1 ? "" : "s") used",
                         badge: nil),
            StatCardView(icon: "dollarsign.circle.fill",
                         label: "Est. cost",
                         value: empty ? "—" : PanelFormats.formatCost(totals.cost),
                         sub: nil,
                         badge: empty ? nil : "\(PanelFormats.formatPercent(totals.cacheRate)) cache hit rate"),
            StatCardView(icon: "gauge.with.dots.needle.67percent",
                         label: "Duration",
                         value: empty ? "—" : PanelFormats.formatDuration(totals.avgLatency),
                         sub: empty ? nil : "avg TTFT \(PanelFormats.formatDuration(totals.avgTTFT))",
                         badge: nil),
        ]
        for subview in statsHost.arrangedSubviews {
            statsHost.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        let row1 = NSStackView(views: [cards[0], cards[1]])
        row1.orientation = .horizontal
        row1.distribution = .fillEqually
        row1.spacing = 12
        let row2 = NSStackView(views: [cards[2], cards[3]])
        row2.orientation = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 12
        for row in [row1, row2] {
            row.translatesAutoresizingMaskIntoConstraints = false
            statsHost.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: statsHost.widthAnchor).isActive = true
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        onPullToRefresh = { [weak self] in
            guard let self else { return }
            self.store.start()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.endRefreshing()
            }
        }
        render()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.revision
            _ = self.store.error
            self.render()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
        store.start()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func render() {
        notice.show(store.error)
        let hasRecords = !store.records.isEmpty
        if !hasRecords {
            let loading = !renderedOnce && store.error == nil
            setState(loading: loading, empty: !loading)
            if !loading {
                renderedOnce = false
                tokenChart.points = []
                costChart.points = []
                requestChart.points = []
                buildStats(UsageTotals(), empty: true)
            }
            return
        }
        renderedOnce = true
        setState(loading: false, empty: false)
        let records = store.records
        let totals = PanelAggregation.totals(records)
        buildStats(totals, empty: false)
        let points = PanelAggregation.hourly(records)
        tokenChart.points = points
        costChart.points = points
        requestChart.points = points
    }
}

@MainActor
final class UsageViewController: PanelScrollViewController {
    private let store = UsageStore.shared
    private let tracker = ObservationTracker()

    private let notice = PanelNoticeView()
    private let modelTable = PanelReadTableView()
    private let requestTable = PanelReadTableView()
    private var modelAggs: [UsageModelAgg] = []
    private var requests: [UsageRecord] = []
    private var totals = UsageTotals()
    private var clearButton: NSButton!
    private var searchField: NSSearchField!
    private var lastRevision = -1
    private var lastError: String?
    private var lastIndexSignature: String?
    private var providerIndex: PanelLogic.ProviderModelIndex = [:]

    private func shortModel(_ key: String) -> String {
        PanelLogic.resolveModelDisplay(key, providerIndex).short
    }

    private func providerLabel(_ key: String) -> String? {
        PanelLogic.resolveModelDisplay(key, providerIndex).provider
    }

    private func refreshProviderIndex() {
        let panel = ProvidersPanelStore.shared
        guard let providers = panel.providers else {
            providerIndexSignature = "\u{1}"
            providerIndex = [:]
            return
        }
        let signature = providers.map { "\($0.name)|\($0.models.map { "\($0.name)|\($0.alias ?? "")" }.joined(separator: ","))" }
            .joined(separator: ";")
        guard signature != providerIndexSignature else { return }
        providerIndexSignature = signature
        providerIndex = PanelLogic.buildProviderModelIndex(providers)
    }

    private var providerIndexSignature = "\u{0}"

    override func loadView() {
        super.loadView()
        addFullWidth(notice)

        let modelHeader = sectionHeader("Usage by model", trailing: nil)
        addFullWidth(modelHeader)
        addFullWidth(modelTable)
        modelTable.heightAnchor.constraint(equalToConstant: 300).isActive = true
        modelTable.paginationEnabled = true
        modelTable.hidePaginationOnSinglePage = true
        modelTable.autoSortFirstSortableColumn = false
        modelTable.footerProvider = { [weak self] in self?.modelFooter() }

        let logHeader = sectionHeader("Request log", trailing: makeLogTrailing())
        addFullWidth(logHeader)
        addFullWidth(requestTable)
        requestTable.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        requestTable.paginationEnabled = true
        requestTable.initialSortColumn = 0
        requestTable.initialSortAscending = false
        requestTable.showsSearchControl = false
        requestTable.searchPlaceholder = "Filter by model…"
        requestTable.searchText = { [weak self] row in
            guard let self, self.requests.indices.contains(row) else { return "" }
            return self.requests[row].displayKey
        }
    }

    private func sectionHeader(_ title: String, trailing: NSView?) -> NSView {
        let label = AppKitTheme.sectionHeader(title)
        guard let trailing else { return label }
        let spacer = NSView()
        let row = NSStackView(views: [label, spacer, trailing])
        row.orientation = .horizontal
        row.spacing = RavenMetrics.spacing2
        row.alignment = .centerY
        label.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeLogTrailing() -> NSView {
        searchField = NSSearchField()
        searchField.placeholderString = "Filter by model…"
        searchField.controlSize = .small
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        searchField.target = self
        searchField.action = #selector(filterChanged)

        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.contentTintColor = .systemRed

        return NSStackView(views: [searchField, clearButton])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        modelTable.configure(modelColumns())
        requestTable.configure(requestColumns())
        render()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.revision
            _ = self.store.error
            self.render()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
        store.start()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
    }

    private func render() {
        notice.show(store.error)
        refreshProviderIndex()
        let revision = store.revision
        let error = store.error
        let indexSignature = providerIndexSignature
        if revision == lastRevision, error == lastError, indexSignature == lastIndexSignature { return }
        lastRevision = revision
        lastError = error
        lastIndexSignature = indexSignature
        modelAggs = PanelAggregation.byModel(store.records)
        totals = PanelAggregation.totals(store.records)
        refreshRows()
    }

    @objc private func refreshRows() {
        requests = store.records
        clearButton.isEnabled = !store.records.isEmpty
        modelTable.reload(rowCount: modelAggs.count)
        requestTable.reload(rowCount: requests.count)
    }

    @objc private func filterChanged() {
        requestTable.setSearchQuery(searchField.stringValue)
    }

    @objc private func clearLog() {
        clearButton.isEnabled = false
        clearButton.title = "Clearing…"
        Task { [weak self] in
            guard let self else { return }
            let message = await self.store.clear()
            self.clearButton.title = "Clear"
            self.clearButton.isEnabled = !self.store.records.isEmpty
            self.notice.show(message)
        }
    }

    private func modelFooter() -> [NSAttributedString?] {
        let ok = totals.latCount
        let duration = ok > 0 ? PanelFormats.formatDuration(totals.latSum / Double(ok)) : "—"
        let ttft = totals.ttftCount > 0 ? PanelFormats.formatDuration(totals.avgTTFT) : nil
        let tps = ok > 0 ? String(format: "%.1f", totals.tpsSum / Double(ok)) : "—"
        let success = totals.requests > 0 ? Double(ok) / Double(totals.requests) : 0
        let successText = totals.requests > 0 ? PanelFormats.formatPercent(success) : "—"
        let cacheText = totals.input > 0 ? PanelFormats.formatPercent(totals.cacheRate) : "—"
        return [
            PanelText.strong("Total"),
            nil,
            PanelText.strong(successText),
            PanelText.strong(PanelFormats.formatTokens(totals.input),
                             suffix: totals.cached > 0 ? "\(PanelFormats.formatTokens(totals.cached)) cached" : nil),
            PanelText.strong(cacheText),
            PanelText.strong(PanelFormats.formatTokens(totals.output)),
            PanelText.strong(duration, suffix: ttft.map { "\($0) first" }),
            PanelText.strong(tps),
            PanelText.strong(PanelFormats.formatCost(totals.cost)),
        ]
    }

    private func modelColumns() -> [PanelColumn] {
        [
            PanelColumn(title: "Model", width: 180, value: { self.shortModel(self.modelAggs[$0].model) },
                        tooltip: { self.modelAggs[$0].model },
                        sort: PanelColumn.byText { self.modelAggs[$0].model }),
            PanelColumn(title: "Provider", width: 110, value: { row in
                self.providerLabel(self.modelAggs[row].model) ?? "—"
            }, sort: PanelColumn.byText { row in
                self.providerLabel(self.modelAggs[row].model) ?? ""
            }),
            PanelColumn(title: "Success", width: 64, alignsRight: true, value: { row in
                let agg = self.modelAggs[row]
                return PanelFormats.formatPercent(agg.requests > 0 ? Double(agg.requests - agg.errors) / Double(agg.requests) : 0)
            }, sort: PanelColumn.byNumber { row in
                let agg = self.modelAggs[row]
                return agg.requests > 0 ? Double(agg.requests - agg.errors) / Double(agg.requests) : 0
            }),
            PanelColumn(title: "Input", width: 120, alignsRight: true, value: { row in
                let agg = self.modelAggs[row]
                let suffix = agg.cached > 0 ? "\(PanelFormats.formatTokens(agg.cached)) cached" : nil
                return PanelFormats.formatTokens(agg.input) + (suffix.map { " · \($0)" } ?? "")
            }, sort: PanelColumn.byNumber { self.modelAggs[$0].input }),
            PanelColumn(title: "Cache hit", width: 72, alignsRight: true, value: { row in
                let agg = self.modelAggs[row]
                let rate = agg.input > 0 ? agg.cached / agg.input : 0
                return rate > 0 ? PanelFormats.formatPercent(rate) : "—"
            }, sort: PanelColumn.byNumber { row in
                let agg = self.modelAggs[row]
                return agg.input > 0 ? agg.cached / agg.input : 0
            }),
            PanelColumn(title: "Output", width: 74, alignsRight: true,
                        value: { PanelFormats.formatTokens(self.modelAggs[$0].output) },
                        sort: PanelColumn.byNumber { self.modelAggs[$0].output }),
            PanelColumn(title: "Avg duration", width: 118, alignsRight: true, value: { row in
                let agg = self.modelAggs[row]
                guard agg.ok > 0 else { return "—" }
                let ttft = agg.ttftOk > 0 ? agg.ttftSum / Double(agg.ttftOk) : 0
                var text = PanelFormats.formatDuration(agg.latSum / Double(agg.ok))
                if ttft > 0 { text += " · \(PanelFormats.formatDuration(ttft)) first" }
                return text
            }, sort: PanelColumn.byNumber { row in
                let agg = self.modelAggs[row]
                return agg.ok > 0 ? agg.latSum / Double(agg.ok) : 0
            }),
            PanelColumn(title: "Avg TPS", width: 66, alignsRight: true, value: { row in
                let agg = self.modelAggs[row]
                return agg.ok > 0 ? String(format: "%.1f", agg.tpsSum / Double(agg.ok)) : "—"
            }, sort: PanelColumn.byNumber { row in
                let agg = self.modelAggs[row]
                return agg.ok > 0 ? agg.tpsSum / Double(agg.ok) : 0
            }),
            PanelColumn(title: "Cost", width: 78, alignsRight: true,
                        value: { PanelFormats.formatCost(self.modelAggs[$0].cost) },
                        sort: PanelColumn.byNumber { self.modelAggs[$0].cost }),
        ]
    }

    private func requestColumns() -> [PanelColumn] {
        [
            PanelColumn(title: "Time", width: 108, value: { row in
                let endMs = PanelAggregation.recordEndTimeMs(self.requests[row])
                return PanelFormats.formatDateTime(Date(timeIntervalSince1970: endMs / 1000))
            }, sort: PanelColumn.byNumber { row in
                Double(PanelAggregation.recordEndTimeMs(self.requests[row]))
            }),
            PanelColumn(title: "Model", width: 160, value: { self.shortModel(self.requests[$0].displayKey) },
                        tooltip: { PanelLogic.resolveModelDisplay(self.requests[$0].displayKey, self.providerIndex).short },
                        sort: PanelColumn.byText { self.requests[$0].displayKey }),
            PanelColumn(title: "Provider", width: 96, value: { row in
                self.providerLabel(self.requests[row].displayKey) ?? "—"
            }, sort: PanelColumn.byText { row in
                self.providerLabel(self.requests[row].displayKey) ?? ""
            }),
            PanelColumn(title: "Status", width: 60, alignsRight: false,
                        value: { row in "\(self.requests[row].status)" },
                        attributed: { row in
                            let status = self.requests[row].status
                            return PanelText.badge("\(status)", color: status < 400 ? .systemGreen : .systemRed)
                        },
                        sort: PanelColumn.byNumber { Double(self.requests[$0].status) }),
            PanelColumn(title: "Effort", width: 66, value: { self.requests[$0].reasoningEffort ?? "—" },
                        sort: PanelColumn.byText { self.requests[$0].reasoningEffort ?? "" }),
            PanelColumn(title: "Input", width: 130, alignsRight: true, value: { row in
                let r = self.requests[row]
                let total = PanelAggregation.inputTotal(r)
                let cached = PanelAggregation.cacheRead(r)
                return PanelFormats.formatTokens(total) + (cached > 0 ? " · \(PanelFormats.formatTokens(cached)) cached" : "")
            }, sort: PanelColumn.byNumber { PanelAggregation.inputTotal(self.requests[$0]) }),
            PanelColumn(title: "Cache hit", width: 72, alignsRight: true, value: { row in
                let r = self.requests[row]
                let total = PanelAggregation.inputTotal(r)
                let rate = total > 0 ? PanelAggregation.cacheRead(r) / total : 0
                return rate > 0 ? PanelFormats.formatPercent(rate) : "—"
            }, sort: PanelColumn.byNumber { row in
                let r = self.requests[row]
                let total = PanelAggregation.inputTotal(r)
                return total > 0 ? PanelAggregation.cacheRead(r) / total : 0
            }),
            PanelColumn(title: "Output", width: 74, alignsRight: true,
                        value: { PanelFormats.formatTokens(self.requests[$0].outputTokens) },
                        sort: PanelColumn.byNumber { Double(self.requests[$0].outputTokens) }),
            PanelColumn(title: "Duration", width: 118, alignsRight: true, value: { row in
                let r = self.requests[row]
                var text = PanelFormats.formatDuration(Double(r.latencyMs))
                if r.ttftMs > 0 && r.ttftMs <= r.latencyMs {
                    text += " · \(PanelFormats.formatDuration(Double(r.ttftMs))) first"
                }
                return text
            }, sort: PanelColumn.byNumber { Double(self.requests[$0].latencyMs) }),
            PanelColumn(title: "TPS", width: 56, alignsRight: true, value: { row in
                let r = self.requests[row]
                guard let tps = PanelFormats.tps(outputTokens: r.outputTokens, latencyMs: r.latencyMs), tps > 0 else { return "—" }
                return String(format: "%.1f", tps)
            }, sort: PanelColumn.byNumber { row in
                let r = self.requests[row]
                return PanelFormats.tps(outputTokens: r.outputTokens, latencyMs: r.latencyMs) ?? 0
            }),
            PanelColumn(title: "Cost", width: 76, alignsRight: true, value: { row in
                let cost = self.requests[row].costUsd
                return cost > 0 ? PanelFormats.formatCost(cost) : "—"
            }, sort: PanelColumn.byNumber { self.requests[$0].costUsd }),
        ]
    }
}
