//
//  HistoryView.swift
//  Wiser
//
//  Created by Marlin on 29/03/2026.
//

import SwiftUI
import SwiftData

/// Every session, as a sheet on iPhone.
struct HistoryView: View {
    var tint: Color

    var body: some View {
        NavigationStack {
            HistoryList(tint: tint)
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .containerBackground(.clear, for: .navigation)
        }
        .presentationDetents([.fraction(0.95)])
        .presentationDragIndicator(.visible)
        .presentationBackground {
            AmbientBackground(tint: tint)
        }
    }
}

/// Every session, a day at a time, the latest first; swipe one away to delete it.
struct HistoryList: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \FocusSession.startDate, order: .reverse) private var sessions: [FocusSession]
    var tint: Color

    /// Each day's sessions, as far as they fall in it, the latest first.
    private var groupedSessions: [(date: String, sessions: [SessionPart])] {
        Self.days(sessions)
    }

    /// Each day of `sessions`, and its sessions as far as they fall in it, the latest first.
    static func days(_ sessions: [FocusSession]) -> [(date: String, sessions: [SessionPart])] {
        let grouped = Dictionary(grouping: sessions) { session in
            Calendar.current.startOfDay(for: session.startDate)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (date: formatSectionDate($0.key), sessions: $0.value.parts.reversed()) }
    }

    private static func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    var body: some View {
        List {
            ForEach(groupedSessions, id: \.date) { group in
                Section {
                    ForEach(group.sessions) { session in
                        HStack {
                            Text(session.start, style: .time)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatFocusTime(minutes: session.minutes))
                                .font(.system(.body, design: .rounded))
                                .fontWeight(.medium)
                                .foregroundStyle(tint.ink(for: colorScheme))
                        }
                        .listRowBackground(Rectangle().fill(.background.opacity(0.5)))
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            for stretch in group.sessions[index].stretches {
                                modelContext.delete(stretch)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.date)
                        Spacer()
                        Text(formatFocusTime(minutes: group.sessions.reduce(0) { $0 + $1.minutes }))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView("No Sessions Yet",
                                       systemImage: "leaf",
                                       description: Text("Focus for at least 5 minutes and it will show up here."))
            }
        }
    }
}

/// Every session on iPhone Duo, a day to a card of the same glass as the Stats page it's reached from, the latest
/// first; touch and hold one to delete it.
struct HistoryCards: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \FocusSession.startDate, order: .reverse) private var sessions: [FocusSession]
    var tint: Color

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(HistoryList.days(sessions), id: \.date) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        // As the list's headers are: in line with the times below.
                        HStack {
                            Text(day.date)
                            Spacer()
                            Text(formatFocusTime(minutes: day.sessions.reduce(0) { $0 + $1.minutes }))
                        }
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        VStack(spacing: 0) {
                            ForEach(day.sessions) { session in
                                if session.id != day.sessions.first?.id {
                                    Divider()
                                        .padding(.leading, 16)
                                }
                                row(session)
                            }
                        }
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView("No Sessions Yet",
                                       systemImage: "leaf",
                                       description: Text("Focus for at least 5 minutes and it will show up here."))
            }
        }
    }

    /// A session: when it started, and how long it ran.
    private func row(_ session: SessionPart) -> some View {
        HStack {
            Text(session.start, style: .time)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatFocusTime(minutes: session.minutes))
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
                .foregroundStyle(tint.ink(for: colorScheme))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(.rect)
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 18))
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation {
                    for stretch in session.stretches {
                        modelContext.delete(stretch)
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    let container = try! ModelContainer(for: FocusSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    SampleData.insert(into: container.mainContext)
    return HistoryView(tint: SkyProvider().sky(at: .now))
        .modelContainer(container)
}
#endif
