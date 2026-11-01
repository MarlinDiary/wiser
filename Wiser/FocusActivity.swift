//
//  FocusActivity.swift
//  Wiser
//
//  Created by Marlin on 21/10/2026.
//

import ActivityKit
import SwiftUI

/// Keeps the focus session's Live Activity, on the Lock Screen and in the Dynamic Island, in step with
/// the timer: there while a session runs, holding still while it's paused, and gone once it's over.
enum FocusActivity {
    /// The last session given a Live Activity, so one swiped away stays away until the next session.
    private static let shownSessionKey = "FocusActivity.shownSession"

    /// Brings the Live Activity in line with the session that began at `session` (none if it's nil),
    /// `elapsed` seconds in and `paused` or not, under a sky of `sky`.
    static func sync(session: Date?, elapsed: TimeInterval, paused: Bool, sky: Color) {
        let activities = Activity<FocusActivityAttributes>.activities
        let ours = activities.first { $0.attributes.session == session }
        // Any left from sessions gone by, and any doubles: only one session runs at a time.
        for activity in activities where activity.id != ours?.id {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        guard let session else { return }
        let now = Date()
        // While paused, the time holds at the whole second the app shows, and a hair past it, so the
        // system shows that same second whichever way it rounds.
        let held = paused ? elapsed.rounded(.down) + 0.01 : elapsed
        let state = FocusActivityAttributes.ContentState(counting: now.addingTimeInterval(-held), paused: paused ? now : nil,
                                                         sky: components(of: sky))
        // The time counts up by itself, so nothing redraws it as it comes to need room for hours: going
        // stale then has the system draw it again.
        let roomForHours = state.counting.addingTimeInterval(FocusActivityAttributes.ContentState.roomForHours)
        let content = ActivityContent(state: state, staleDate: paused || roomForHours <= now ? nil : roomForHours)
        guard let activity = ours else {
            // A session's Live Activity comes once: if it's gone, swiped away or ended by the system,
            // it stays gone.
            let defaults = UserDefaults.standard
            guard (defaults.object(forKey: shownSessionKey) as? Date) != session,
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            if (try? Activity.request(attributes: FocusActivityAttributes(session: session), content: content)) != nil {
                defaults.set(session, forKey: shownSessionKey)
            }
            return
        }
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        let shown = activity.content.state
        // Unchanged as far as anyone could see: the same time to the second, the same sky.
        let shownElapsed = (shown.paused ?? now).timeIntervalSince(shown.counting)
        let same = shown.isPaused == paused && abs(shownElapsed - held) < 1
            && zip(shown.sky, state.sky).allSatisfy { abs($0 - $1) < 0.004 } && shown.sky.count == state.sky.count
        guard !same else { return }
        Task { await activity.update(content) }
    }

    private static func components(of color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)]
    }
}
