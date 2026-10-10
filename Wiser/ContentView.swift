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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationManager = LocationManager()
    @State var skyProvider = SkyProvider()
    @State private var focusTimer = FocusTimer()
    @State private var isMusicOn = false
    @State private var isBrightScreen = false
    @State private var showStats = false
    @State private var showHistory = false

    private var focusDisplay: String {
        let totalSeconds = Int(focusTimer.elapsedSeconds)
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
        ZStack {
            TimelineView(.everyMinute) { context in
                AmbientBackground(tint: skyProvider.sky(at: context.date))
            }
            VStack {
                HStack {
                    Button(action: {
                        if focusTimer.isRunning {
                            isBrightScreen.toggle()
                        }
                    }) {
                        Image(systemName: focusTimer.isRunning ? (isBrightScreen ? "sun.max.fill" : "sun.min") : "gear")
                            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                            .font(.headline)
                            .frame(width: 20, height: 20)
                            .padding(8)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(.leading, 16)
                    Spacer()
                    Button(action: {
                        if focusTimer.isRunning {
                            isMusicOn.toggle()
                        } else {
                            showHistory = true
                        }
                    }) {
                        Image(systemName: focusTimer.isRunning ? (isMusicOn ? "music.note" : "music.note.slash") : "text.page")
                            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                            .font(.headline)
                            .frame(width: 20, height: 20)
                            .padding(8)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, 16)
                }
                Spacer()
                TimelineView(.everyMinute) { context in
                    let tint = skyProvider.sky(at: context.date)
                    // The stones keep their shading but take on the hue of the sky.
                    RockStackView(state: focusTimer.isRunning ? (focusTimer.isPaused ? .paused : .checked) : .idle,
                                  shadowColor: colorScheme == .dark ? .black : tint.mix(with: .black, by: 0.6))
                        .colorEffect(ShaderLibrary.tintKeepingLuminance(
                            .color(tint),
                            .float(0.15)
                        ))
                }
                .scaleEffect(0.66)
                .frame(height: 364 * 0.66)
                .padding(.bottom, 16)
                TimelineView(.everyMinute) { context in
                    Text(focusDisplay)
                        .font(.system(size: 48, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(skyProvider.sky(at: context.date).ink(for: colorScheme))
                        .contentTransition(.numericText())
                        .animation(.linear(duration: 0.3), value: focusDisplay)
                }
                Spacer()
                ZStack {
                    Button(action: {
                        if focusTimer.isRunning {
                            if let result = focusTimer.stop(), result.duration >= 300 {
                                for session in FocusSession.splitByDay(startDate: result.startDate, durationSeconds: result.duration) {
                                    modelContext.insert(session)
                                }
                            }
                            isMusicOn = false
                            isBrightScreen = false
                            if let location = locationManager.location {
                                Task { await skyProvider.fetchWeather(for: location) }
                            }
                        } else {
                            focusTimer.start()
                        }
                    }) {
                        Label(focusTimer.isRunning ? "Stop" : "Start Focus",
                              systemImage: focusTimer.isRunning ? "stop.fill" : "play.fill")

                            .font(.headline)
                            .padding(8)
                    }
                    .buttonStyle(.glass)

                    HStack {
                        Button(action: {
                            if !focusTimer.isRunning {
                                showStats = true
                            }
                        }) {
                            Image(systemName: focusTimer.isRunning ? "backward.end.fill" : "chart.bar.fill")
                                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                                .font(.headline)
                                .frame(width: 20, height: 20)
                                .padding(8)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .padding(.leading, 16)
                        Spacer()
                        Button(action: {
                            if focusTimer.isRunning {
                                if focusTimer.isPaused {
                                    focusTimer.resume()
                                } else {
                                    focusTimer.pause()
                                }
                            }
                        }) {
                            Image(systemName: focusTimer.isRunning ? (focusTimer.isPaused ? "play.fill" : "pause.fill") : "sparkles")
                                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                                .font(.headline)
                                .frame(width: 20, height: 20)
                                .padding(8)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .padding(.trailing, 16)
                    }
                }
            }
        }
        .onAppear {
            locationManager.requestLocation()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                focusTimer.refreshOnForeground()
            }
        }
        .task(id: locationManager.location?.coordinate.latitude) {
            guard let location = locationManager.location else { return }
            await skyProvider.fetchWeather(for: location)
        }
        .onReceive(Timer.publish(every: 30 * 60, on: .main, in: .common).autoconnect()) { _ in
            if let location = locationManager.location {
                Task { await skyProvider.fetchWeather(for: location) }
            }
        }
        .sheet(isPresented: $showStats) {
            StatsView(tint: skyProvider.sky(at: .now))
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(tint: skyProvider.sky(at: .now))
        }
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
