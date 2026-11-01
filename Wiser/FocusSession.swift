//
//  FocusSession.swift
//  Wiser
//
//  Created by Marlin on 27/03/2026.
//

import Foundation
import SwiftData

/// A stretch of focus: a whole session, or the part of one between a start or resume and the next pause, or
/// midnight.
@Model
final class FocusSession {
    var startDate: Date
    var durationSeconds: TimeInterval
    /// When the session this stretch is part of began. Sessions kept before they were kept in stretches have
    /// none: each of those is a session of its own.
    var sessionStart: Date?

    var durationMinutes: Int {
        Int(durationSeconds) / 60
    }

    /// The session this stretch is part of.
    var session: Date {
        sessionStart ?? startDate
    }

    init(startDate: Date, durationSeconds: TimeInterval, sessionStart: Date? = nil) {
        self.startDate = startDate
        self.durationSeconds = durationSeconds
        self.sessionStart = sessionStart
    }

    /// The session begun at `start`, focused for `stretches`, as it's kept: a stretch for each day each one
    /// falls in, so the time lands on the hours and days it was spent in. A bit under a minute, cut off at
    /// midnight or between pauses, goes into the stretch beside it rather than standing as a "0m" of its own.
    static func kept(session start: Date, stretches: [FocusStretch]) -> [FocusSession] {
        let calendar = Calendar.current
        var pieces: [FocusStretch] = []
        for stretch in stretches {
            var current = stretch.start
            let end = stretch.start.addingTimeInterval(stretch.seconds)
            while current < end {
                let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: current)!)
                let pieceEnd = min(midnight, end)
                pieces.append(FocusStretch(start: current, seconds: pieceEnd.timeIntervalSince(current)))
                current = pieceEnd
            }
        }
        var kept: [FocusStretch] = []
        for piece in pieces {
            if piece.seconds < 60, !kept.isEmpty {
                kept[kept.count - 1].seconds += piece.seconds
            } else {
                kept.append(piece)
            }
        }
        if kept.count > 1, kept[0].seconds < 60 {
            kept[1].seconds += kept[0].seconds
            kept.removeFirst()
        }
        return kept.map { FocusSession(startDate: $0.start, durationSeconds: $0.seconds, sessionStart: start) }
    }
}

/// A stretch of focus with no pause in it.
struct FocusStretch: Equatable {
    var start: Date
    var seconds: TimeInterval
}

/// A session as far as it falls in one day or period: its stretches of focus there, as one.
struct SessionPart: Identifiable {
    /// When the session began.
    let id: Date
    /// When its first stretch here began.
    let start: Date
    let seconds: TimeInterval
    let stretches: [FocusSession]

    var minutes: Int {
        Int(seconds) / 60
    }
}

extension Sequence<FocusSession> {
    /// The sessions these stretches are part of, each with the ones among them, the earliest first.
    var parts: [SessionPart] {
        Dictionary(grouping: self, by: \.session)
            .map { session, stretches in
                let stretches = stretches.sorted { $0.startDate < $1.startDate }
                return SessionPart(id: session, start: stretches[0].startDate,
                                   seconds: stretches.reduce(0) { $0 + $1.durationSeconds }, stretches: stretches)
            }
            .sorted { $0.start < $1.start }
    }
}

/// "45m", "2h", "1h 15m"
func formatFocusTime(minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest)m" }
    if rest == 0 { return "\(hours)h" }
    return "\(hours)h \(rest)m"
}
