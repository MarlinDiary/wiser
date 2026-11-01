//
//  FocusTimer.swift
//  Wiser
//
//  Created by Marlin on 27/03/2026.
//

import Foundation

@Observable
final class FocusTimer {
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var elapsedSeconds: TimeInterval = 0 {
        didSet { updateLongEnough() }
    }
    /// Whether the session has run long enough to be kept. It changes once a session, not with each second, so what
    /// shows it isn't redrawn with the time.
    private(set) var isLongEnough = false

    /// The shortest session kept.
    static let shortest: TimeInterval = 5 * 60

    private func updateLongEnough() {
        let longEnough = elapsedSeconds >= Self.shortest
        if longEnough != isLongEnough {
            isLongEnough = longEnough
        }
    }

    private(set) var sessionStartDate: Date?
    private var startDate: Date?
    /// The stretches focused before the last pause, so the session can be kept as it was spent.
    private var stretches: [FocusStretch] = []
    /// When the focus really began, if it's been set: earlier than Start was tapped, or later. The stretches stay as
    /// they were spent, and are counted from it.
    private var focusBegan: Date?
    private var timer: Timer?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let isRunning = "FocusTimer.isRunning"
        static let isPaused = "FocusTimer.isPaused"
        static let sessionStartDate = "FocusTimer.sessionStartDate"
        static let startDate = "FocusTimer.startDate"
        /// What was focused before the last pause, as sessions were saved before their stretches were.
        static let accumulated = "FocusTimer.accumulated"
        static let stretchStarts = "FocusTimer.stretchStarts"
        static let stretchSeconds = "FocusTimer.stretchSeconds"
        static let focusBegan = "FocusTimer.focusBegan"
    }

    var totalMinutes: Int {
        Int(elapsedSeconds) / 60
    }

    /// A session under way: when it began, how long it's been focused so far, and whether it's paused.
    struct Running {
        let start: Date
        let focused: TimeInterval
        let isPaused: Bool
    }

    /// The session under way, if there is one, as it stands this moment.
    var running: Running? {
        guard isRunning, let startedAt else { return nil }
        return Running(start: startedAt, focused: elapsedNow, isPaused: isPaused)
    }

    /// When the session's focus began: when Start was tapped, or when it's been set to, if the focus really began
    /// earlier, or later.
    var startedAt: Date? {
        focusBegan ?? stretches.first?.start ?? startDate ?? sessionStartDate
    }

    /// Sets when the session's focus began to `date`, for focus that began before Start was tapped (or, set too
    /// early, after). The session stays the same one, on the Lock Screen too, and its stretches as they were spent,
    /// so it can be set again, either way, without losing any of them.
    func began(at date: Date) {
        guard isRunning else { return }
        focusBegan = date
        elapsedSeconds = elapsedNow
        save()
    }

    /// How long the session has run, not counting pauses, to this very moment.
    var elapsedNow: TimeInterval {
        focused.reduce(0) { $0 + $1.seconds }
    }

    /// The session's stretches, the one under way to this very moment too, counted from when the focus began.
    private var focused: [FocusStretch] {
        let current = startDate.map { FocusStretch(start: $0, seconds: Self.since($0)) }
        return Self.counted(stretches + (current.map { [$0] } ?? []), from: focusBegan)
    }

    /// `stretches` counted from `began`, if the focus began at another time than they did: the first reaching back to
    /// it, or those before it left out and the one it falls in cut short.
    nonisolated static func counted(_ stretches: [FocusStretch], from began: Date?) -> [FocusStretch] {
        guard let began, let first = stretches.first else { return stretches }
        if began <= first.start {
            var counted = stretches
            counted[0] = FocusStretch(start: began, seconds: first.seconds + first.start.timeIntervalSince(began))
            return counted
        }
        return stretches.compactMap { stretch in
            let end = stretch.start.addingTimeInterval(stretch.seconds)
            guard end > began else { return nil }
            let start = max(stretch.start, began)
            return FocusStretch(start: start, seconds: end.timeIntervalSince(start))
        }
    }

    /// How long ago `date` was; never less than nothing, even with the clock set back past it.
    nonisolated private static func since(_ date: Date) -> TimeInterval {
        max(0, Date().timeIntervalSince(date))
    }

    var displaySeconds: Int {
        Int(elapsedSeconds) % 60
    }

    init() {
        restore()
    }

    func start() {
        isRunning = true
        isPaused = false
        elapsedSeconds = 0
        stretches = []
        focusBegan = nil
        sessionStartDate = Date()
        startDate = sessionStartDate
        startTimer()
        save()
    }

    /// Ends the session: when it began, the stretches it was focused for, and how long that came to.
    func stop() -> (startDate: Date, stretches: [FocusStretch], duration: TimeInterval)? {
        let sessionStart = sessionStartDate
        let focused = self.focused
        isRunning = false
        isPaused = false
        timer?.invalidate()
        timer = nil
        startDate = nil
        sessionStartDate = nil
        stretches = []
        focusBegan = nil
        elapsedSeconds = 0
        clearSaved()
        guard let sessionStart else { return nil }
        return (sessionStart, focused, focused.reduce(0) { $0 + $1.seconds })
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        timer?.invalidate()
        timer = nil
        if let startDate {
            stretches.append(FocusStretch(start: startDate, seconds: Self.since(startDate)))
        }
        startDate = nil
        // Hold at the moment of pausing, not at the last tick before it.
        elapsedSeconds = elapsedNow
        save()
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        startDate = Date()
        startTimer()
        save()
    }

    func refreshOnForeground() {
        guard isRunning, !isPaused, startDate != nil else { return }
        elapsedSeconds = elapsedNow
        if timer == nil {
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick()
        }
    }

    private func tick() {
        guard startDate != nil else { return }
        elapsedSeconds = elapsedNow
    }

    private func save() {
        defaults.set(isRunning, forKey: Keys.isRunning)
        defaults.set(isPaused, forKey: Keys.isPaused)
        defaults.set(sessionStartDate, forKey: Keys.sessionStartDate)
        defaults.set(startDate, forKey: Keys.startDate)
        defaults.set(stretches.map(\.start), forKey: Keys.stretchStarts)
        defaults.set(stretches.map(\.seconds), forKey: Keys.stretchSeconds)
        defaults.set(focusBegan, forKey: Keys.focusBegan)
        // Kept in the stretches now.
        defaults.removeObject(forKey: Keys.accumulated)
    }

    private func clearSaved() {
        defaults.removeObject(forKey: Keys.isRunning)
        defaults.removeObject(forKey: Keys.isPaused)
        defaults.removeObject(forKey: Keys.sessionStartDate)
        defaults.removeObject(forKey: Keys.startDate)
        defaults.removeObject(forKey: Keys.accumulated)
        defaults.removeObject(forKey: Keys.stretchStarts)
        defaults.removeObject(forKey: Keys.stretchSeconds)
        defaults.removeObject(forKey: Keys.focusBegan)
    }

    private func restore() {
        guard defaults.bool(forKey: Keys.isRunning) else { return }
        // A session saved without its start date can't be resumed or stopped; drop it.
        guard let savedSessionStart = defaults.object(forKey: Keys.sessionStartDate) as? Date else {
            clearSaved()
            return
        }

        isRunning = true
        isPaused = defaults.bool(forKey: Keys.isPaused)
        sessionStartDate = savedSessionStart
        startDate = defaults.object(forKey: Keys.startDate) as? Date
        focusBegan = defaults.object(forKey: Keys.focusBegan) as? Date
        let starts = defaults.array(forKey: Keys.stretchStarts) as? [Date] ?? []
        let seconds = defaults.array(forKey: Keys.stretchSeconds) as? [TimeInterval] ?? []
        stretches = zip(starts, seconds).map { FocusStretch(start: $0, seconds: $1) }
        // A session saved before its stretches were: what was focused before the last pause, from its start.
        let accumulated = defaults.double(forKey: Keys.accumulated)
        if stretches.isEmpty, accumulated > 0 {
            stretches = [FocusStretch(start: savedSessionStart, seconds: accumulated)]
            save()
        }

        elapsedSeconds = elapsedNow
        if !isPaused, startDate != nil {
            startTimer()
        }
    }
}
