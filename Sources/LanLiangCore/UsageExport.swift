import Foundation

struct UsageExportSnapshot {
    struct Group: Equatable {
        let service: Service
        let hasTokenData: Bool
        let shares: [ModelDistribution.Share]?
    }

    let range: TokenRange
    let start: String
    let end: String
    let bars: [StackedBar]
    let groups: [Group]

    var total: Int64 {
        bars.reduce(0) { current, bar in
            let (next, overflow) = current.addingReportingOverflow(bar.total)
            return overflow ? Int64.max : next
        }
    }

    var dateText: String { start == end ? start : "\(start) 至 \(end)" }

    init(range: TokenRange, bars: [StackedBar], selection: ModelPeriodSelection,
         now: Date, calendar: Calendar, groups: [(Service, Bool, DailyModelWeights?)]) {
        self.range = range
        let scope = selection.resolve(in: bars.map(\.bar), now: now, calendar: calendar)
        let first = scope?.start ?? DayKey.of(now, calendar: calendar)
        let last = scope?.end ?? first
        start = first
        end = last
        self.bars = scope?.selected.map { selected in bars.filter { $0.bar.key == selected.key } } ?? bars
        self.groups = groups.map { service, hasTokens, days in
            Group(service: service, hasTokenData: hasTokens,
                  shares: days.map { Self.shares($0, start: first, end: last) })
        }
    }

    private static func shares(_ days: DailyModelWeights, start: String, end: String) -> [ModelDistribution.Share] {
        var sanitized: DailyModelWeights = [:]
        for (day, models) in days where day >= start && day <= end {
            for (model, weight) in models {
                let name = model.lowercased()
                // Do not export account identifiers, paths, URLs, or resource-scoped model labels.
                let privateLabel = name.contains("@") || name.contains("/") || name.contains("\\")
                    || name.contains(":") || name.contains("~")
                ModelDistribution.append(weight, model: privateLabel ? nil : model, day: day, to: &sanitized)
            }
        }
        return ModelDistribution.shares(sanitized, start: start, through: end)
    }
}
