//
//  HistoryView.swift
//  Wiser
//
//  Created by Marlin on 29/03/2026.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \FocusSession.startDate, order: .reverse) private var sessions: [FocusSession]
    var tint: Color

    private var groupedSessions: [(date: String, sessions: [FocusSession])] {
        let grouped = Dictionary(grouping: sessions) { session in
            Calendar.current.startOfDay(for: session.startDate)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (date: formatSectionDate($0.key), sessions: $0.value) }
    }

    private func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedSessions, id: \.date) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            HStack {
                                Text(session.startDate, style: .time)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formatFocusTime(minutes: session.durationMinutes))
                                    .font(.system(.body, design: .rounded))
                                    .fontWeight(.medium)
                                    .foregroundStyle(tint.ink(for: colorScheme))
                            }
                            .listRowBackground(Rectangle().fill(.background.opacity(0.5)))
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                modelContext.delete(group.sessions[index])
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.date)
                            Spacer()
                            Text(formatFocusTime(minutes: group.sessions.reduce(0) { $0 + $1.durationMinutes }))
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

#Preview {
    let container = try! ModelContainer(for: FocusSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    SampleData.insert(into: container.mainContext)
    return HistoryView(tint: SkyProvider().sky(at: .now))
        .modelContainer(container)
}
