//
//  StatsView.swift
//  Wiser
//
//  Created by Marlin on 28/03/2026.
//

import SwiftUI
import SwiftData
import Charts

enum StatsPeriod: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// The unit of one bar in the chart.
    var bucket: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        }
    }
}

struct ChartEntry: Identifiable {
    let id: Int
    let start: Date
    let minutes: Int
    let isCurrent: Bool
}

struct StatsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query private var allSessions: [FocusSession]
    @State private var selectedPeriod: StatsPeriod = .day
    @State private var offset: Int = 0
    @State private var rawSelection: Double?
    var tint: Color

    private let calendar = Calendar.current

    private var ink: Color {
        tint.ink(for: colorScheme)
    }

    private func interval(offset: Int) -> DateInterval {
        let reference = calendar.date(byAdding: selectedPeriod.component, value: offset, to: .now)!
        return calendar.dateInterval(of: selectedPeriod.component, for: reference)!
    }

    private func focusSeconds(from start: Date, to end: Date) -> Int {
        Int(allSessions.reduce(0.0) { total, session in
            let sessionEnd = session.startDate.addingTimeInterval(session.durationSeconds)
            let overlap = min(sessionEnd, end).timeIntervalSince(max(session.startDate, start))
            return total + max(0, overlap)
        })
    }

    private func chartData(in interval: DateInterval) -> [ChartEntry] {
        let now = Date()
        let count = selectedPeriod == .month
            ? calendar.range(of: .day, in: .month, for: interval.start)!.count
            : selectedPeriod == .day ? 24 : selectedPeriod == .week ? 7 : 12
        return (0..<count).map { i in
            let start = calendar.date(byAdding: selectedPeriod.bucket, value: i, to: interval.start)!
            let end = calendar.date(byAdding: selectedPeriod.bucket, value: i + 1, to: interval.start)!
            return ChartEntry(id: i,
                              start: start,
                              minutes: focusSeconds(from: start, to: end) / 60,
                              isCurrent: start <= now && now < end)
        }
    }

    /// Days (or months, for the year view) of the period that have already started.
    private func elapsedBuckets(in interval: DateInterval) -> Int {
        let unit: Calendar.Component = selectedPeriod == .year ? .month : .day
        let end = min(Date(), interval.end)
        let count = calendar.dateComponents([unit], from: interval.start, to: end).value(for: unit) ?? 0
        return max(1, end < interval.end ? count + 1 : count)
    }

    // MARK: Labels

    private var periodTitle: String {
        let start = interval(offset: offset).start
        switch selectedPeriod {
        case .day:
            if calendar.isDateInToday(start) { return "Today" }
            if calendar.isDateInYesterday(start) { return "Yesterday" }
            return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            if offset == 0 { return "This Week" }
            if offset == -1 { return "Last Week" }
            let end = calendar.date(byAdding: .day, value: 6, to: start)!
            return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return offset == 0 ? "This Month" : start.formatted(.dateTime.month(.wide).year())
        case .year:
            return offset == 0 ? "This Year" : start.formatted(.dateTime.year())
        }
    }

    private func axisLabel(for entry: ChartEntry) -> String {
        switch selectedPeriod {
        case .day: "\(calendar.component(.hour, from: entry.start))"
        case .week: calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: entry.start) - 1]
        case .month: "\(calendar.component(.day, from: entry.start))"
        case .year: calendar.veryShortMonthSymbols[calendar.component(.month, from: entry.start) - 1]
        }
    }

    private func detailLabel(for entry: ChartEntry) -> String {
        switch selectedPeriod {
        case .day: entry.start.formatted(date: .omitted, time: .shortened)
        case .week, .month: entry.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .year: entry.start.formatted(.dateTime.month(.wide))
        }
    }

    private func selectedEntry(in data: [ChartEntry]) -> ChartEntry? {
        rawSelection.map { Int($0.rounded()) }.flatMap { i in data.first { $0.id == i && $0.minutes > 0 } }
    }

    private func labeledIndices(count: Int) -> [Int] {
        switch selectedPeriod {
        case .day: [0, 6, 12, 18]
        case .week, .year: Array(0..<count)
        case .month: [0, 7, 14, 21, 28].filter { $0 < count }
        }
    }

    private var barWidth: CGFloat {
        switch selectedPeriod {
        case .day: 8
        case .week: 24
        case .month: 7
        case .year: 16
        }
    }

    private func axisMax(for minutes: Int) -> Int {
        let step = max(1, Int((Double(max(minutes, 60)) / 2).rounded(.up)))
        let niceStep = step <= 30 ? 30 : step <= 60 ? 60 : ((step + 59) / 60) * 60
        return niceStep * 2
    }

    private func axisText(minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)h" : formatFocusTime(minutes: minutes)
    }

    // MARK: Body

    var body: some View {
        let current = interval(offset: offset)
        let previous = interval(offset: offset - 1)
        let data = chartData(in: current)
        let totalMinutes = focusSeconds(from: current.start, to: current.end) / 60
        let sessions = allSessions.filter { $0.startDate >= current.start && $0.startDate < current.end }
        let average = selectedPeriod == .day ? nil : Double(totalMinutes) / Double(elapsedBuckets(in: current))
        let selected = selectedEntry(in: data)

        VStack(spacing: 20) {
            Picker("Period", selection: $selectedPeriod) {
                ForEach(StatsPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button {
                    offset -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Text(periodTitle)
                    .font(.system(.headline, design: .rounded))
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    offset += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .disabled(offset >= 0)
                .opacity(offset >= 0 ? 0.25 : 1)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.top, -8)

            VStack(spacing: 6) {
                Text(formatFocusTime(minutes: selected?.minutes ?? totalMinutes))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                    .contentTransition(.numericText())
                Text(selected.map { detailLabel(for: $0) } ?? summary(totalMinutes: totalMinutes, average: average, previous: previous))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            chart(data, average: average, selected: selected)
                .frame(height: 280)
                .overlay {
                    if totalMinutes == 0 {
                        Text("No focus yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatTile(title: "Sessions", value: sessions.isEmpty ? "—" : "\(sessions.count)")
                    StatTile(title: "Longest", value: sessions.map(\.durationMinutes).max().map { formatFocusTime(minutes: $0) } ?? "—")
                }
                GridRow {
                    StatTile(title: "Average", value: sessions.isEmpty ? "—" : formatFocusTime(minutes: sessions.reduce(0) { $0 + $1.durationMinutes } / sessions.count))
                    StatTile(title: "Peak", value: data.filter { $0.minutes > 0 }.max { $0.minutes < $1.minutes }.map { detailLabel(for: $0) } ?? "—")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .animation(.easeInOut(duration: 0.3), value: offset)
        .animation(.easeInOut(duration: 0.3), value: selectedPeriod)
        .onChange(of: selectedPeriod) {
            offset = 0
            rawSelection = nil
        }
        .onChange(of: offset) {
            rawSelection = nil
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground {
            AmbientBackground(tint: tint)
        }
    }

    private func summary(totalMinutes: Int, average: Double?, previous: DateInterval) -> String {
        var parts: [String] = []
        if let average {
            parts.append("\(selectedPeriod == .year ? "Monthly" : "Daily") avg \(formatFocusTime(minutes: Int(average)))")
        }
        let previousMinutes = focusSeconds(from: previous.start, to: previous.end) / 60
        let previousValue = average == nil ? Double(previousMinutes) : Double(previousMinutes) / Double(elapsedBuckets(in: previous))
        let currentValue = average ?? Double(totalMinutes)
        if previousValue > 0 {
            let change = Int(((currentValue - previousValue) / previousValue * 100).rounded())
            let name = selectedPeriod == .day ? "the day before" : "last \(selectedPeriod.rawValue.lowercased())"
            parts.append("\(change >= 0 ? "+" : "−")\(abs(change))% vs \(name)")
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func chart(_ data: [ChartEntry], average: Double?, selected: ChartEntry?) -> some View {
        let top = axisMax(for: data.map(\.minutes).max() ?? 0)
        let highlighted = selected?.id ?? data.first(where: \.isCurrent)?.id
        return Chart {
            ForEach(data) { entry in
                if entry.minutes > 0 {
                    BarMark(x: .value("Time", entry.id),
                            y: .value("Minutes", entry.minutes),
                            width: .fixed(barWidth))
                        .cornerRadius(barWidth / 2)
                        .foregroundStyle(entry.id == highlighted ? ink : ink.opacity(0.5))
                }
            }
            if let average, average > 0 {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(ink.opacity(0.5))
            }
        }
        .chartXScale(domain: -0.5...(Double(data.count) - 0.5))
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: labeledIndices(count: data.count)) { value in
                AxisValueLabel {
                    if let i = value.as(Int.self), data.indices.contains(i) {
                        Text(axisLabel(for: data[i]))
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
                        Text(axisText(minutes: minutes))
                    }
                }
            }
        }
        .chartGesture { proxy in
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    rawSelection = proxy.value(atX: value.location.x, as: Double.self)
                }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

#if DEBUG
#Preview {
    let container = try! ModelContainer(for: FocusSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    SampleData.insert(into: container.mainContext)
    return StatsView(tint: SkyProvider().sky(at: .now))
        .modelContainer(container)
}
#endif
