//
//  FocusActivityAttributes.swift
//  Wiser
//
//  Created by Marlin on 21/10/2026.
//

import ActivityKit
import Foundation

/// A focus session as the Lock Screen and the Dynamic Island show it while it runs. The time on show
/// counts up by itself from `counting`, so nothing needs updating as it goes, only when the session is
/// paused or resumed.
nonisolated struct FocusActivityAttributes: ActivityAttributes {
    /// When the session began: each session has a Live Activity of its own.
    var session: Date

    struct ContentState: Codable, Hashable {
        /// When the session would have begun had it never been paused: the time shown counts up from here.
        var counting: Date
        /// When it was paused, if it is: the time shown holds where it was then.
        var paused: Date?
        /// The sky's tint as the home screen shows it, in sRGB, so the session looks the same out here.
        var sky: [Double]

        var isPaused: Bool {
            paused != nil
        }

        /// How far in the time shown needs room for hours: a little before the hour, so the room is
        /// there before the hours are.
        static let roomForHours: TimeInterval = 59 * 60 + 50

        /// Whether the time shown needs room for hours now.
        var needsRoomForHours: Bool {
            (paused ?? .now).timeIntervalSince(counting) >= Self.roomForHours
        }
    }
}
