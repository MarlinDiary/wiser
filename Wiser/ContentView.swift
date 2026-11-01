//
//  ContentView.swift
//  Wiser
//
//  Created by Marlin on 26/03/2026.
//

import SwiftUI
import SwiftData
import CoreLocation
import Combine

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationManager = LocationManager()
    @State var skyProvider = SkyProvider()
    @State private var scene = Rock3DScene()
    @State private var focusTimer = FocusTimer()
    @State private var isMusicOn = false
    /// Whether the noise has been wanted yet, since launch.
    @State private var noiseWanted = false
    @State private var isBrightScreen = false
    @State private var showStats = false
    @State private var showHistory = false
    @State private var showAI = false
    @State private var showSettings = false
    /// Whether a session keeps the screen on from the start, as set in Settings.
    @AppStorage(SettingsView.keepScreenOnKey) private var keepScreenOn = false
    /// Whether the session's start is being set back, for focus that began before Start was tapped.
    @State private var settingStart = false
    /// Whether Stop is waiting on whether to keep a session long enough to have been left running.
    @State private var confirmingLongStop = false
    /// Whether this iPhone folds, as iPhone Duo does, which has a home of its own: unknown until the
    /// system says whether there's a hinge, which only iOS 27.1 and later can, and no iPhone that folds
    /// runs anything earlier. Known at once from the last launch, after the first.
    @State private var folds: Bool? = HingeReader.canAsk ? HingeReader.remembered : false
    /// The page shown on iPhone Duo.
    @State private var page = DuoPage.focus
    /// Where the time stands across the window, so the stones can stand under it.
    @State private var timeAxis: CGFloat?
    /// The session controls' glass on iPhone Duo, which flows from one button into two and back.
    @Namespace private var controlsGlass
    /// How often the sky and the light move on: often enough that they change in steps too small to see.
    private static let skyInterval: TimeInterval = 10

    /// The session on the Lock Screen and in the Dynamic Island, as it is now.
    private func syncActivity() {
        FocusActivity.sync(session: focusTimer.sessionStartDate, elapsed: focusTimer.elapsedNow, paused: focusTimer.isPaused,
                           sky: skyProvider.sky(at: .now))
    }

    var body: some View {
        Group {
            switch folds {
            case true?:
                // Only iOS 27.1 and later tell of a hinge.
                if #available(iOS 27.1, *) {
                    foldingHome
                }
            case false?:
                NavigationStack {
                    home
                        // The system's bars, so the buttons go where the system's own apps keep theirs.
                        .toolbar { bars }
                        .navigationBarTitleDisplayMode(.inline)
                }
            case nil:
                // For the moment it takes to know which home it is, what the launch screen shows: the sky
                // is made once, in the home it belongs to, and starts out blank for a frame.
                Color("LaunchSky")
                    .ignoresSafeArea()
            }
        }
        .modifier(HingeReader(folds: $folds))
        .onAppear {
            locationManager.requestLocation()
            // A session carried over from before keeps the screen on as a new one would.
            if focusTimer.isRunning {
                isBrightScreen = keepScreenOn
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                focusTimer.refreshOnForeground()
            }
            // On the way out, the Lock Screen takes over showing the session, under the sky as it is now.
            syncActivity()
        }
        .onChange(of: focusTimer.isRunning, initial: true) {
            syncActivity()
            playNoise()
        }
        .onChange(of: focusTimer.isPaused) {
            syncActivity()
            playNoise()
        }
        .onChange(of: isMusicOn) {
            playNoise()
        }
        // Its start set back: the Lock Screen counts from there too.
        .onChange(of: focusTimer.startedAt) {
            syncActivity()
        }
        // The screen stays on while the session runs, if asked to: no dimming, no locking.
        .onChange(of: isBrightScreen) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onChange(of: locationManager.location, initial: true) { _, location in
            if let location {
                skyProvider.updateSunTimes(for: location)
            }
        }
        .onReceive(Timer.publish(every: 30 * 60, on: .main, in: .common).autoconnect()) { _ in
            if let location = locationManager.location {
                skyProvider.updateSunTimes(for: location)
            }
        }
        .sheet(isPresented: $showStats) {
            StatsView(tint: skyProvider.sky(at: .now))
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(tint: skyProvider.sky(at: .now))
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(tint: skyProvider.sky(at: .now))
        }
        .sheet(isPresented: $showAI) {
            NavigationStack {
                AIChatView(tint: skyProvider.sky(at: .now), titled: true, running: { [focusTimer] in focusTimer.running }) {
                    Color.clear
                }
                .containerBackground(.clear, for: .navigation)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground {
                AmbientBackground(tint: skyProvider.sky(at: .now))
            }
        }
        .alert("Save This Session?", isPresented: $confirmingLongStop) {
            Button("Save") { stop(saving: true) }
            Button("Don’t Save", role: .destructive) { stop(saving: false) }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("It ran for \(Duration.seconds(focusTimer.elapsedNow).formatted(.units(allowed: [.hours, .minutes], width: .wide))). If it was left running, you can leave it out.")
        }
    }

    /// The noise plays while a session runs with it on, and rests while it's paused. Its player is made the first
    /// time it's wanted, not at launch.
    private func playNoise() {
        let playing = isMusicOn && focusTimer.isRunning && !focusTimer.isPaused
        guard playing || noiseWanted else { return }
        noiseWanted = true
        WhiteNoise.shared.onStopped = { isMusicOn = false }
        WhiteNoise.shared.play(playing)
    }

    /// The sky, and the stones standing in it.
    private var home: some View {
        ZStack {
            // Every ten seconds, so the sky and the light change in steps too small to see.
            TimelineView(.periodic(from: .now, by: Self.skyInterval)) { context in
                SceneView(scene: scene, tint: skyProvider.sky(at: context.date))
            }
            .ignoresSafeArea()
            GeometryReader { proxy in
                let plan = HomePlan(in: proxy, under: timeAxis.map { $0 - proxy.frame(in: .global).minX })
                stones
                    .frame(width: plan.stage.width, height: plan.band)
                    .position(x: plan.stage.midX, y: plan.stage.midY)
            }
        }
    }

    /// The sky and the ground of the home, with no stones: behind the pages beside it on iPhone Duo, so
    /// the three are one scene.
    private var openScene: some View {
        TimelineView(.periodic(from: .now, by: Self.skyInterval)) { context in
            OpenSceneView(scene: scene, tint: skyProvider.sky(at: context.date), daylight: skyProvider.daylight(at: context.date))
        }
        .ignoresSafeArea()
    }

    private var timeCapsule: some View {
        TimeCapsule(timer: focusTimer, axis: $timeAxis)
    }

    /// iPhone Duo's home, with fewer buttons for its smaller cover screen: three pages, and below the
    /// stones, starting and stopping a session.
    @available(iOS 27.1, *)
    private var foldingHome: some View {
        TabView(selection: $page) {
            Tab("AI", systemImage: "sparkles", value: .ai) {
                NavigationStack {
                    AIChatView(tint: skyProvider.sky(at: .now), running: { [focusTimer] in focusTimer.running }) {
                        openScene
                    }
                }
            }
            Tab("Focus", systemImage: "timer", value: .focus) {
                NavigationStack {
                    VerticalBarAware { barsRunDown in
                        home
                            // Where the tabs run across the bottom, above them, the way Music keeps what's
                            // playing, and taking room from the stones as iPhone's bottom bar does.
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                if !barsRunDown {
                                    sessionControls
                                        .padding(.bottom, 12)
                                }
                            }
                            .toolbar {
                                ToolbarItem(placement: .principal) {
                                    timeCapsule
                                }
                                // Where they run down the side, in a bar across the bottom all the same, which
                                // keeps them level with the tabs and under the time, as Safari keeps its
                                // address.
                                if barsRunDown {
                                    ToolbarItem(placement: .bottomBar) {
                                        sessionControls
                                    }
                                    // Their own glass, which splits and flows back together.
                                    .sharedBackgroundVisibility(.hidden)
                                    .axisBehavior(.horizontalOnly)
                                }
                            }
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            Tab("Stats", systemImage: "chart.bar", value: .stats) {
                NavigationStack {
                    StatsPage(tint: skyProvider.sky(at: .now)) {
                        openScene
                    }
                }
            }
        }
    }

    /// Starting and stopping a session on iPhone Duo. One drop of glass, Start Focus, which splits in two as
    /// a session starts, Stop and pausing beside it, and flows back into one when it's over.
    private var sessionControls: some View {
        ZStack {
            // As wide as the wider of the two from the start: a bar lays out its items at once, without
            // the animation, so making room as the glass parts would jump it sideways.
            ZStack {
                sessionWords(running: false)
                HStack(spacing: Self.controlSpacing) {
                    ZStack {
                        sessionWords(running: true)
                        sessionWords(running: true, cancels: true)
                    }
                    Color.clear
                        .frame(width: Self.controlHeight)
                }
            }
            .frame(height: Self.controlHeight)
            .hidden()
            sessionGlass
        }
    }

    /// The glass of the session controls, as the session is now.
    private var sessionGlass: some View {
        GlassEffectContainer(spacing: Self.controlSpacing) {
            HStack(spacing: Self.controlSpacing) {
                Button(action: startOrStop) {
                    // One word blurs into the other as the glass around them changes shape.
                    ZStack {
                        if focusTimer.isRunning {
                            sessionWords(running: true, cancels: cancels)
                                .id(cancels)
                                .transition(.blurReplace)
                        } else {
                            sessionWords(running: false)
                                .transition(.blurReplace)
                        }
                    }
                    .frame(height: Self.controlHeight)
                    .contentShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID(ControlGlass.main, in: controlsGlass)
                }
                if focusTimer.isRunning {
                    Button {
                        if focusTimer.isPaused {
                            focusTimer.resume()
                        } else {
                            focusTimer.pause()
                        }
                    } label: {
                        Image(systemName: focusTimer.isPaused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                            .font(.headline)
                            .frame(width: Self.controlHeight, height: Self.controlHeight)
                            .contentShape(.circle)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .glassEffectID(ControlGlass.pause, in: controlsGlass)
                    }
                    .accessibilityLabel(focusTimer.isPaused ? "Resume" : "Pause")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        // Springy, so the glass stretches as it parts and settles with a little give.
        .animation(.bouncy(duration: 0.55, extraBounce: 0.08), value: focusTimer.isRunning)
        .animation(.smooth(duration: 0.4), value: cancels)
    }

    /// Whether ending the session now lets it go, as one too short to keep: Cancel, until it's run long enough, then
    /// Stop. Said on the button beforehand, so nothing needs saying after.
    private var cancels: Bool {
        focusTimer.isRunning && !focusTimer.isLongEnough
    }

    /// What the main session control says, with the room around it inside the glass. In words beside
    /// the symbol, not a label, which a bar shows as its symbol alone.
    private func sessionWords(running: Bool, cancels: Bool = false) -> some View {
        let title: LocalizedStringKey = running ? (cancels ? "Cancel" : "Stop") : "Start Focus"
        return HStack(spacing: 6) {
            Image(systemName: running ? (cancels ? "xmark" : "stop.fill") : "play.fill")
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.headline)
        .padding(.horizontal, 22)
    }

    /// How tall the session controls are on iPhone Duo, as thick as the tab bar where it runs down the
    /// side, and how far apart, as on iPhone's bottom bar.
    private static let controlHeight: CGFloat = 48
    private static let controlSpacing: CGFloat = 12

    /// The buttons in the bars, each titled for VoiceOver and for wherever the system shows titles. Up
    /// top, the time between keeping the screen on and the white noise while a session runs, the settings
    /// and the history otherwise; below, starting and stopping it between setting when it started and
    /// pausing, the stats and AI otherwise.
    @ToolbarContentBuilder
    private var bars: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if focusTimer.isRunning {
                    isBrightScreen.toggle()
                } else {
                    showSettings = true
                }
            } label: {
                symbol(focusTimer.isRunning ? "Keep Screen On" : "Settings",
                       focusTimer.isRunning ? (isBrightScreen ? "sun.max.fill" : "sun.min") : "gear")
            }
        }
        ToolbarItem(placement: .principal) {
            timeCapsule
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if focusTimer.isRunning {
                    isMusicOn.toggle()
                } else {
                    showHistory = true
                }
            } label: {
                symbol(focusTimer.isRunning ? "White Noise" : "History",
                       focusTimer.isRunning ? (isMusicOn ? "music.note" : "music.note.slash") : "text.page")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                if focusTimer.isRunning {
                    settingStart = true
                } else {
                    showStats = true
                }
            } label: {
                symbol(focusTimer.isRunning ? "Start Time" : "Stats", focusTimer.isRunning ? "backward.end.fill" : "chart.bar.fill")
            }
            .popover(isPresented: $settingStart) {
                StartTimePicker(timer: focusTimer)
                    .presentationCompactAdaptation(.popover)
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(action: startOrStop) {
                StartStopLabel(isRunning: focusTimer.isRunning, cancels: cancels)
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button {
                if focusTimer.isRunning {
                    if focusTimer.isPaused {
                        focusTimer.resume()
                    } else {
                        focusTimer.pause()
                    }
                } else {
                    showAI = true
                }
            } label: {
                symbol(focusTimer.isRunning ? (focusTimer.isPaused ? "Resume" : "Pause") : "Ask AI",
                       focusTimer.isRunning ? (focusTimer.isPaused ? "play.fill" : "pause.fill") : "sparkles")
            }
        }
    }

    /// A button's label: the symbol, which turns into the next as the button's meaning changes, and its
    /// title.
    private func symbol(_ title: LocalizedStringKey, _ name: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: name)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
        }
    }

    private func startOrStop() {
        if focusTimer.isRunning {
            // This long, it was more likely left running than focused through: ask before keeping it.
            if focusTimer.elapsedNow > Self.longSession {
                confirmingLongStop = true
            } else {
                stop(saving: true)
            }
        } else {
            focusTimer.start()
            isBrightScreen = keepScreenOn
        }
    }

    /// Ends the session, keeping it if `saving` and it ran long enough to count: one shorter was ended with Cancel.
    private func stop(saving: Bool) {
        if let result = focusTimer.stop(), saving, result.duration >= FocusTimer.shortest {
            for stretch in FocusSession.kept(session: result.startDate, stretches: result.stretches) {
                modelContext.insert(stretch)
            }
            // Now, not at the next autosave: the timer has already let go of the session.
            try? modelContext.save()
        }
        isMusicOn = false
        isBrightScreen = false
        if let location = locationManager.location {
            skyProvider.updateSunTimes(for: location)
        }
    }

    /// How long a session runs before Stop asks whether to keep it.
    private static let longSession: TimeInterval = 3 * 3600

    /// Where the stones stand; `SceneView` draws them here.
    private var stones: some View {
        TimelineView(.periodic(from: .now, by: Self.skyInterval)) { context in
            let tint = skyProvider.sky(at: context.date)
            Rock3DStackView(scene: scene, state: focusTimer.isRunning ? (focusTimer.isPaused ? .paused : .checked) : .idle,
                            tint: tint, daylight: skyProvider.daylight(at: context.date))
        }
    }
}

/// When the session's focus began, to set back for focus that began before Start was tapped: the time on show takes
/// it up as the wheel turns.
private struct StartTimePicker: View {
    var timer: FocusTimer
    @State private var start: Date
    /// How many times the wheel has been set back, after being turned to a time that hasn't come yet: each makes it
    /// anew, at the last start that was kept.
    @State private var resets = 0

    init(timer: FocusTimer) {
        self.timer = timer
        _start = State(initialValue: timer.startedAt ?? .now)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("Started At")
                .font(.headline)
                .padding(.top, 14)
            DatePicker("Started At", selection: Binding { start } set: { picked in
                guard let date = Self.start(at: picked) else {
                    resets += 1
                    return
                }
                start = date
                timer.began(at: date)
            }, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .id(resets)
        }
        .padding(.horizontal, 12)
    }

    /// When a session started, if its focus began at `picked`'s time of day: the last time the clock read it, so 23:50
    /// just after midnight is last night's. None if that was more than half a day ago, which makes it later today, a
    /// time that hasn't come yet.
    static func start(at picked: Date, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let time = calendar.dateComponents([.hour, .minute], from: picked)
        guard let date = calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime, direction: .backward),
              now.timeIntervalSince(date) <= 12 * 3600 else { return nil }
        return date
    }
}

/// The focus time, in a capsule of the same glass as the buttons, so the scene below is left to the stones; dimmed
/// while paused, as on the Lock Screen. A view of its own, so the time ticking over redraws it alone.
private struct TimeCapsule: View {
    var timer: FocusTimer
    /// Where the capsule's middle is across the window.
    @Binding var axis: CGFloat?

    private var display: String {
        let totalSeconds = Int(timer.elapsedSeconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    var body: some View {
        Text(display)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.linear(duration: 0.3), value: display)
            .foregroundStyle(timer.isPaused ? .secondary : .primary)
            .animation(.easeInOut(duration: 0.25), value: timer.isPaused)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { axis = $0 }
    }
}

/// Starting or stopping a session: in words beside the symbol where the bar runs across the screen, and
/// the symbol alone where it runs down the side, as on iPhone Duo's cover screen.
private struct StartStopLabel: View {
    var isRunning: Bool
    /// Whether ending the session now lets it go, as one too short to keep.
    var cancels = false

    var body: some View {
        if #available(iOS 27.1, *) {
            VerticalBarAware { isVertical in
                if isVertical {
                    Label(title, systemImage: symbol)
                } else {
                    words
                }
            }
        } else {
            words
        }
    }

    private var title: LocalizedStringKey {
        isRunning ? (cancels ? "Cancel" : "Stop") : "Start Focus"
    }

    private var symbol: String {
        isRunning ? (cancels ? "xmark" : "stop.fill") : "play.fill"
    }

    /// The bar shows a label's symbol alone wherever it runs, so the words come in a view of their own.
    private var words: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .accessibilityHidden(true)
            Text(title)
                .contentTransition(.opacity)
        }
        .fontWeight(.semibold)
        // Cancel turns into Stop at five minutes.
        .animation(.smooth(duration: 0.4), value: cancels)
    }
}

/// Hands `content` whether the bars run down the side of the screen, as on iPhone Duo's cover screen: never before
/// iOS 27.1, which has no such bars.
struct VerticalBarAware<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            VerticalEdgeReader(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalEdgeReader<Content: View>: View {
    var content: (Bool) -> Content
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View {
        content(edge != nil)
    }
}

/// Notes whether the device has a hinge, as iPhone Duo does.
private struct HingeReader: ViewModifier {
    @Binding var folds: Bool?

    /// Whether the system can say whether there's a hinge.
    static var canAsk: Bool {
        if #available(iOS 27.1, *) {
            return true
        }
        return false
    }

    /// Whether this iPhone was found to fold at the last launch, if it was this same model, so it opens on its
    /// own home at once rather than waiting to be told again. (A backup brought to another model doesn't count.)
    static var remembered: Bool? {
        guard canAsk, UserDefaults.standard.string(forKey: Keys.model) == model else { return nil }
        return UserDefaults.standard.object(forKey: Keys.folds) as? Bool
    }

    private static func remember(_ folds: Bool) {
        UserDefaults.standard.set(model, forKey: Keys.model)
        UserDefaults.standard.set(folds, forKey: Keys.folds)
    }

    private enum Keys {
        static let model = "HingeReader.model"
        static let folds = "HingeReader.folds"
    }

    /// Which model this is, "iPhone19,4" and the like, as the simulator stands in for it too.
    private static let model: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .onHingeChange { _, context in
                    // A hinge doesn't come and go: once there's been one, there always is.
                    if context.hinge != nil {
                        folds = true
                        Self.remember(true)
                    } else if folds == nil {
                        folds = false
                        Self.remember(false)
                    }
                }
                .task {
                    // iPhone Duo tells of its hinge at once; where nothing has been told by now, there's
                    // none to tell of.
                    try? await Task.sleep(for: .seconds(1))
                    if folds == nil {
                        folds = false
                        Self.remember(false)
                    }
                }
        } else {
            content
        }
    }
}

/// The pieces of glass in iPhone Duo's session controls.
nonisolated private enum ControlGlass: Hashable, Sendable {
    case main, pause
}

/// The pages of iPhone Duo's home.
private enum DuoPage: Hashable {
    case ai, focus, stats
}

/// Where the stones go, in the room the bars leave: under the time, which is usually the middle of it.
/// Where the bars run down the side, as on iPhone Duo's cover screen, the time stands a little off the
/// middle of what's left, and the stones stay with it. On iPhone Duo partly folded, off the fold: held
/// like a book, on the leading page; propped up like a laptop, on the upright half, where they're seen
/// from across the desk, while the bottom bar stays on the flat half, where it's easy to reach.
private struct HomePlan {
    /// Where the stones go.
    var stage: CGRect
    /// How tall they're drawn: as on iPhone, and larger on larger screens.
    var band: CGFloat

    /// `axis` is where the time stands across `proxy`, if it's known.
    init(in proxy: GeometryProxy, under axis: CGFloat?) {
        let bounds = CGRect(origin: .zero, size: proxy.size)
        let fold = Self.fold(in: proxy)
        if let fold, fold.height > fold.width {
            stage = CGRect(x: 0, y: 0, width: max(0, fold.minX), height: bounds.height)
        } else {
            stage = CGRect(x: 0, y: 0, width: bounds.width, height: fold.map { max(0, $0.minY) } ?? bounds.height)
            if let axis, axis > stage.minX, axis < stage.maxX {
                let reach = min(axis - stage.minX, stage.maxX - axis)
                stage = CGRect(x: axis - reach, y: stage.minY, width: reach * 2, height: stage.height)
            }
        }
        band = max(0, min(max(min(stage.width, stage.height) * 0.5, 240), 340, stage.height - 16))
    }

    /// The fold, while iPhone Duo is partly folded, with the room the system keeps clear around it.
    private static func fold(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *), let region = proxy.reservedRegions(kind: .division).first(where: \.isActive) else {
            return nil
        }
        let frame = region.frame, margins = region.margins
        return CGRect(x: frame.minX - margins.leading, y: frame.minY - margins.top,
                      width: frame.width + margins.leading + margins.trailing, height: frame.height + margins.top + margins.bottom)
    }
}

#if DEBUG
#Preview("Morning") {
    let container = try! ModelContainer(for: FocusSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    SampleData.insert(into: container.mainContext)
    return ContentView(skyProvider: SkyProvider(time: DateComponents(hour: 8)))
        .modelContainer(container)
}
#endif

#Preview("Afternoon") {
    let container = try! ModelContainer(for: FocusSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return ContentView(skyProvider: SkyProvider(time: DateComponents(hour: 17, minute: 50)))
        .modelContainer(container)
}

#Preview("Evening") {
    let container = try! ModelContainer(for: FocusSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return ContentView(skyProvider: SkyProvider(time: DateComponents(hour: 19, minute: 10)))
        .modelContainer(container)
}

#Preview("Night") {
    let container = try! ModelContainer(for: FocusSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return ContentView(skyProvider: SkyProvider(time: DateComponents(hour: 22)))
        .modelContainer(container)
}
