//
//  StatsPage.swift
//  Wiser
//
//  Created by Marlin on 01/11/2026.
//

import SwiftUI
import SwiftData
import Charts

/// The stats as a page of their own, on iPhone Duo: how long you focused in a day, a week, a month or a
/// year, the periods before it a swipe back on the chart, a few highlights, and the sessions it was made
/// of, all in one scroll.
struct StatsPage<Background: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var widthClass
    @Query(sort: \FocusSession.startDate) private var sessions: [FocusSession]
    @State private var kind = StatsPeriod.week
    /// The period the chart is on: 0 for the current one, -1 for the one before, and so on.
    @State private var shown: Int? = 0
    /// The bar tapped on the chart, if any.
    @State private var picked: Int?
    var tint: Color
    /// What the page stands on, and the history it leads to.
    @ViewBuilder var background: () -> Background

    private var ink: Color {
        tint.ink(for: colorScheme)
    }

    /// How many periods there are to swipe through: back to the one the first session was in.
    private var periodCount: Int {
        let calendar = Calendar.current
        guard let first = sessions.first,
              let start = calendar.dateInterval(of: kind.component, for: first.startDate)?.start,
              let now = calendar.dateInterval(of: kind.component, for: .now)?.start else { return 1 }
        let between = calendar.dateComponents([kind.component], from: start, to: now).value(for: kind.component) ?? 0
        return max(1, between + 1)
    }

    var body: some View {
        let period = FocusPeriod(kind, offset: shown ?? 0, sessions: sessions)
        let entry = picked.flatMap { i in period.buckets.first { $0.id == i } }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Period", selection: $kind) {
                    ForEach(StatsPeriod.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 8) {
                    header(period, entry: entry)
                        .padding(.horizontal, 20)
                    charts
                }

                highlights(period)
                    .padding(.horizontal, 20)

                sessionList(period)
                    .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background {
            background()
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: kind) {
            shown = 0
            picked = nil
        }
        .onChange(of: shown) {
            picked = nil
        }
    }

    /// The period, or the bar tapped in it: when, and how long.
    private func header(_ period: FocusPeriod, entry: ChartEntry?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.map { kind.detailLabel(for: $0) } ?? period.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(formatFocusTime(minutes: entry?.minutes ?? period.total))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
                .contentTransition(.numericText())
            Text(entry == nil ? period.summary : " ")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: entry?.minutes ?? period.total)
    }

    /// A chart a period, the current one last: swipe back through the ones before, and up and down past
    /// it like the rest of the page.
    private var charts: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach((1 - periodCount)...0, id: \.self) { offset in
                    PeriodChart(period: FocusPeriod(kind, offset: offset, sessions: sessions), ink: ink,
                                picked: offset == (shown ?? 0) ? $picked : .constant(nil))
                        // Room for the labels above the top line and below the bars.
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $shown)
        .defaultScrollAnchor(.trailing)
        .scrollIndicators(.hidden)
        .frame(height: widthClass == .regular ? 300 : 240)
        // The next period waits out of sight, not under the bars down the side of the screen.
        .clipped()
        // Each kind of period starts over at the current one.
        .id(kind)
    }

    private func highlights(_ period: FocusPeriod) -> some View {
        let sessions = period.sessions
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatTile(title: "Sessions", value: sessions.isEmpty ? "—" : "\(sessions.count)")
                StatTile(title: "Longest", value: sessions.map(\.durationMinutes).max().map { formatFocusTime(minutes: $0) } ?? "—")
            }
            GridRow {
                StatTile(title: "Average", value: sessions.isEmpty ? "—" : formatFocusTime(minutes: sessions.reduce(0) { $0 + $1.durationMinutes } / sessions.count))
                StatTile(title: "Peak", value: period.buckets.filter { $0.minutes > 0 }.max { $0.minutes < $1.minutes }.map { kind.detailLabel(for: $0) } ?? "—")
            }
        }
    }

    /// The period's latest sessions, and the way to all of them.
    private func sessionList(_ period: FocusPeriod) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions")
                .font(.headline)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                if period.sessions.isEmpty {
                    Text("No sessions")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                ForEach(period.sessions.prefix(Self.listedSessions)) { session in
                    HStack {
                        Text(kind == .day ? session.startDate.formatted(date: .omitted, time: .shortened)
                             : session.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatFocusTime(minutes: session.durationMinutes))
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundStyle(ink)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    Divider()
                        .padding(.leading, 16)
                }
                NavigationLink {
                    HistoryList(tint: tint)
                        .navigationTitle("History")
                        .navigationBarTitleDisplayMode(.inline)
                        .background {
                            background()
                        }
                } label: {
                    HStack {
                        Text("All Sessions")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    /// How many of a period's sessions the page lists before the way to all of them.
    private static var listedSessions: Int {
        5
    }
}

/// One period's chart: a bar for each hour of the day, day of the week or month, or month of the year, the
/// current one darker, and the average across it. Tap a bar to see its time; tap it again to let go.
private struct PeriodChart: View {
    var period: FocusPeriod
    var ink: Color
    @Binding var picked: Int?

    var body: some View {
        let top = Self.axisMax(for: period.buckets.map(\.minutes).max() ?? 0)
        let highlighted = picked ?? period.buckets.first(where: \.isCurrent)?.id
        Chart {
            ForEach(period.buckets) { entry in
                if entry.minutes > 0 {
                    BarMark(x: .value("Time", entry.id),
                            y: .value("Minutes", entry.minutes),
                            width: .fixed(period.kind.barWidth))
                        .cornerRadius(period.kind.barWidth / 2)
                        .foregroundStyle(entry.id == highlighted ? ink : ink.opacity(0.5))
                }
            }
            if let average = period.average, average > 0 {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(ink.opacity(0.5))
            }
        }
        .chartXScale(domain: -0.5...(Double(period.buckets.count) - 0.5))
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: period.kind.labeledIndices(count: period.buckets.count)) { value in
                AxisValueLabel {
                    if let i = value.as(Int.self), period.buckets.indices.contains(i) {
                        Text(period.kind.axisLabel(for: period.buckets[i]))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(ink.opacity(0.25))
                AxisValueLabel {
                    if let minutes = value.as(Int.self), minutes > 0 {
                        Text(Self.axisText(minutes: minutes))
                    }
                }
            }
        }
        // A tap, not a drag, so the page still scrolls and the chart still swipes wherever a finger lands.
        .chartGesture { proxy in
            SpatialTapGesture()
                .onEnded { value in
                    let index = proxy.value(atX: value.location.x, as: Double.self).map { Int($0.rounded()) }
                    let bar = index.flatMap { i in period.buckets.first { $0.id == i && $0.minutes > 0 }?.id }
                    picked = bar == picked ? nil : bar
                }
        }
        .overlay {
            if period.total == 0 {
                Text("No focus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: picked)
    }

    /// The top of the chart: the next whole half hour, hour or more above `minutes`, an hour at least.
    private static func axisMax(for minutes: Int) -> Int {
        let step = max(1, Int((Double(max(minutes, 60)) / 2).rounded(.up)))
        let niceStep = step <= 30 ? 30 : step <= 60 ? 60 : ((step + 59) / 60) * 60
        return niceStep * 2
    }

    private static func axisText(minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)h" : formatFocusTime(minutes: minutes)
    }
}

/// How long you focused in one day, week, month or year: in all, bit by bit across it, against the one
/// before, and the sessions it was made of.
struct FocusPeriod {
    let kind: StatsPeriod
    /// 0 for the current period, -1 for the one before, and so on.
    let offset: Int
    let interval: DateInterval
    /// Each hour of the day, day of the week or month, or month of the year.
    let buckets: [ChartEntry]
    /// Minutes in all.
    let total: Int
    /// Minutes a day so far (a month, in a year); none for a day.
    let average: Double?
    /// How much more or less than in the period before, in percent, if there was any focus then.
    let change: Int?
    /// The sessions that started in it, the latest first.
    let sessions: [FocusSession]

    init(_ kind: StatsPeriod, offset: Int, sessions all: [FocusSession], calendar: Calendar = .current) {
        let now = Date()
        func interval(_ offset: Int) -> DateInterval {
            let reference = calendar.date(byAdding: kind.component, value: offset, to: now)!
            return calendar.dateInterval(of: kind.component, for: reference)!
        }
        func seconds(_ start: Date, _ end: Date) -> TimeInterval {
            all.reduce(0) { total, session in
                let overlap = min(session.startDate.addingTimeInterval(session.durationSeconds), end).timeIntervalSince(max(session.startDate, start))
                return total + max(0, overlap)
            }
        }
        /// The days (months, in a year) of `interval` that have begun.
        func begun(_ interval: DateInterval) -> Int {
            let unit: Calendar.Component = kind == .year ? .month : .day
            let end = min(now, interval.end)
            let count = calendar.dateComponents([unit], from: interval.start, to: end).value(for: unit) ?? 0
            return max(1, end < interval.end ? count + 1 : count)
        }

        let current = interval(offset)
        let count = kind == .month ? calendar.range(of: .day, in: .month, for: current.start)!.count
            : kind == .day ? 24 : kind == .week ? 7 : 12
        self.kind = kind
        self.offset = offset
        self.interval = current
        buckets = (0..<count).map { i in
            let start = calendar.date(byAdding: kind.bucket, value: i, to: current.start)!
            let end = calendar.date(byAdding: kind.bucket, value: i + 1, to: current.start)!
            return ChartEntry(id: i, start: start, minutes: Int(seconds(start, end)) / 60, isCurrent: start <= now && now < end)
        }
        total = Int(seconds(current.start, current.end)) / 60
        average = kind == .day ? nil : Double(total) / Double(begun(current))
        let previous = interval(offset - 1)
        let previousMinutes = Int(seconds(previous.start, previous.end)) / 60
        let before = average == nil ? Double(previousMinutes) : Double(previousMinutes) / Double(begun(previous))
        let after = average ?? Double(total)
        change = before > 0 ? Int(((after - before) / before * 100).rounded()) : nil
        sessions = Array(all.filter { current.start <= $0.startDate && $0.startDate < current.end }.reversed())
    }

    /// Which period it is, in words.
    var title: String {
        let start = interval.start
        let calendar = Calendar.current
        switch kind {
        case .day:
            if calendar.isDateInToday(start) { return String(localized: "Today") }
            if calendar.isDateInYesterday(start) { return String(localized: "Yesterday") }
            return start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .week:
            if offset == 0 { return String(localized: "This Week") }
            if offset == -1 { return String(localized: "Last Week") }
            let end = calendar.date(byAdding: .day, value: 6, to: start)!
            return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return offset == 0 ? String(localized: "This Month") : start.formatted(.dateTime.month(.wide).year())
        case .year:
            return offset == 0 ? String(localized: "This Year") : start.formatted(.dateTime.year())
        }
    }

    /// The average, and how it compares with the period before.
    var summary: String {
        var parts: [String] = []
        if let average {
            parts.append(kind == .year ? String(localized: "Monthly avg \(formatFocusTime(minutes: Int(average)))")
                         : String(localized: "Daily avg \(formatFocusTime(minutes: Int(average)))"))
        }
        if let change {
            let before: String = switch kind {
            case .day: offset == 0 ? String(localized: "yesterday") : String(localized: "the day before")
            case .week: offset == 0 ? String(localized: "last week") : String(localized: "the week before")
            case .month: offset == 0 ? String(localized: "last month") : String(localized: "the month before")
            case .year: offset == 0 ? String(localized: "last year") : String(localized: "the year before")
            }
            parts.append("\(change >= 0 ? "+" : "−")\(abs(change))% vs \(before)")
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

extension StatsPeriod {
    /// The label under `entry`'s bar.
    func axisLabel(for entry: ChartEntry) -> String {
        let calendar = Calendar.current
        return switch self {
        case .day: "\(calendar.component(.hour, from: entry.start))"
        case .week: calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: entry.start) - 1]
        case .month: "\(calendar.component(.day, from: entry.start))"
        case .year: calendar.veryShortMonthSymbols[calendar.component(.month, from: entry.start) - 1]
        }
    }

    /// When `entry`'s bar is, in words.
    func detailLabel(for entry: ChartEntry) -> String {
        switch self {
        case .day: entry.start.formatted(date: .omitted, time: .shortened)
        case .week, .month: entry.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .year: entry.start.formatted(.dateTime.month(.wide))
        }
    }

    /// Which of `count` bars are labeled.
    func labeledIndices(count: Int) -> [Int] {
        switch self {
        case .day: [0, 6, 12, 18]
        case .week, .year: Array(0..<count)
        case .month: [0, 7, 14, 21, 28].filter { $0 < count }
        }
    }

    var barWidth: CGFloat {
        switch self {
        case .day: 8
        case .week: 24
        case .month: 7
        case .year: 16
        }
    }
}
