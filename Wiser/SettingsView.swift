//
//  SettingsView.swift
//  Wiser
//
//  Created by Marlin on 02/11/2026.
//

import SwiftUI

/// Settings, as a sheet on iPhone: the white noise, the screen while a session runs, the key AI answers with, and
/// where Wiser keeps what it knows.
struct SettingsView: View {
    var tint: Color
    @Bindable private var noise = WhiteNoise.shared
    @AppStorage(SettingsView.keepScreenOnKey) private var keepScreenOn = false
    @State private var hasKey = OpenAIKey.value != nil
    @State private var managingKey = false

    /// Whether a session keeps the screen on from the start.
    static let keepScreenOnKey = "Focus.keepScreenOn"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sound", selection: $noise.sound) {
                        ForEach(WhiteNoise.Sound.allCases) { sound in
                            Text(sound.name).tag(sound)
                        }
                    }
                    .row()
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(value: $noise.volume, in: 0.2...1) {
                            Text("Volume")
                        }
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .row()
                    // Back to Listen by itself too, if the noise stops with the headphones taken off.
                    Button(noise.isListening ? "Stop Listening" : "Listen") {
                        noise.listen(!noise.isListening)
                    }
                    .row()
                } header: {
                    Text("White Noise")
                } footer: {
                    Text("Plays while you focus, once you turn it on with the music button.")
                }

                Section {
                    Toggle("Keep Screen On", isOn: $keepScreenOn)
                        .row()
                } header: {
                    Text("Focus")
                } footer: {
                    Text("The screen stays on, without dimming or locking, while you focus. You can still turn it off during a session.")
                }

                Section {
                    Button {
                        managingKey = true
                    } label: {
                        LabeledContent("OpenAI API Key", value: hasKey ? String(localized: "Added") : String(localized: "Not Added"))
                    }
                    .row()
                } header: {
                    Text("AI")
                } footer: {
                    Text("Your questions and your focus records go to OpenAI with your key, and OpenAI bills your account for them. The key stays on this iPhone.")
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                        .row()
                } header: {
                    Text("About")
                } footer: {
                    Text("Your focus history stays on this iPhone. Your location is used only on this iPhone, to follow sunrise and sunset.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .containerBackground(.clear, for: .navigation)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground {
            AmbientBackground(tint: tint)
        }
        .sheet(isPresented: $managingKey) {
            KeySheet(hasKey: $hasKey)
        }
        .onDisappear {
            noise.listen(false)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private extension View {
    /// A row on the sky, as History's are.
    func row() -> some View {
        listRowBackground(Rectangle().fill(.background.opacity(0.5)))
    }
}
