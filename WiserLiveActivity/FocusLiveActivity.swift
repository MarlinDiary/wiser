//
//  FocusLiveActivity.swift
//  WiserLiveActivity
//
//  Created by Marlin on 21/10/2026.
//

import ActivityKit
import SwiftUI
import WidgetKit

/// A focus session on the Lock Screen and in the Dynamic Island: the stones, standing as they do on the
/// home screen while it runs, and the time so far. Everywhere the stones lead and the time follows, so
/// the island opens into the same picture it shows closed, and the Lock Screen shows it again.
struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            LockScreenFocus(state: context.state)
                // Glass tinted with the sky: the wallpaper shows through, and it's still the home screen's
                // sky. The system draws this glass itself; glass drawn here would hide what's on it.
                .activityBackgroundTint(context.state.tint.opacity(0.35))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(context.state.isPaused ? "StonesPaused" : "StonesFocus")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 60)
                        .padding(.leading, 4)
                        .accessibilityLabel(context.state.label)
                }
                // Beside the camera, as the stones are, so nothing leaves a gap around it, and level with
                // the stones' middle.
                DynamicIslandExpandedRegion(.trailing) {
                    FocusTime(state: context.state, alignment: .trailing)
                        // Hours only fit beside the camera a size down.
                        .font(.system(size: context.needsRoomForHours ? 27 : 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(context.state.isPaused ? .secondary : .primary)
                        // Against the far edge however wide the island opens, as it does on iPhone Duo,
                        // with no camera between.
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .trailing)
                        .padding(.trailing, 4)
                }
            } compactLeading: {
                CompactStones(label: context.state.label)
            } compactTrailing: {
                CompactTime(context: context)
            } minimal: {
                Image("StonesSmall")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
                    .accessibilityLabel(context.state.label)
            }
            .keylineTint(context.state.tint)
        }
    }
}

/// The session on the Lock Screen, laid out as the island shows it opened: the stones on one side, the
/// time on the other.
private struct LockScreenFocus: View {
    var state: FocusActivityAttributes.ContentState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Out here the stones stay pale and the time white in the dark, so both read at a glance.
        let ink = colorScheme == .dark ? Color.white : state.tint.ink(for: colorScheme)
        HStack(spacing: 12) {
            Image(state.isPaused ? "StonesPaused" : "StonesFocus")
                .resizable()
                .scaledToFit()
                .frame(height: 80)
                .accessibilityLabel(state.label)
            FocusTime(state: state, alignment: .trailing)
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(state.isPaused ? 0.6 : 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// The stones in the closed island, smaller where it's narrow (on its side, as on iPhone Duo's cover
/// screen) so they fit.
private struct CompactStones: View {
    var label: LocalizedStringKey

    var body: some View {
        if #available(iOS 27.0, *) {
            NarrowAware { isNarrow in
                stones(height: isNarrow ? 21 : 24)
            }
        } else {
            stones(height: 24)
        }
    }

    private func stones(height: CGFloat) -> some View {
        Image("StonesSmall")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel(label)
    }
}

/// The time in the closed island: just the room it needs, so it sits snug against the camera. Where the
/// island is narrow it's small enough to fit, and once it runs to hours it no longer can, so the stones
/// are left alone there.
private struct CompactTime: View {
    var context: ActivityViewContext<FocusActivityAttributes>

    var body: some View {
        if #available(iOS 27.0, *) {
            NarrowAware { isNarrow in
                if !isNarrow {
                    wide
                } else if !context.needsRoomForHours {
                    // The rounded face comes in one width only; compressed digits fit "59:59" in 23 pt.
                    time(.system(size: 12, weight: .semibold).width(.compressed), width: 26)
                }
            }
        } else {
            wide
        }
    }

    private var wide: some View {
        time(.system(size: 15, weight: .semibold, design: .rounded), width: context.needsRoomForHours ? 60 : 46)
    }

    private func time(_ font: Font, width: CGFloat) -> some View {
        FocusTime(state: context.state, alignment: .trailing)
            .font(font)
            .lineLimit(1)
            .foregroundStyle(context.state.isPaused ? .secondary : .primary)
            .frame(width: width)
    }
}

/// Hands `content` whether the island it's in is narrow: on its side, where the HIG asks for what fits a
/// 28 pt circle.
@available(iOS 27.0, *)
private struct NarrowAware<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @Environment(\.isDynamicIslandLimitedInWidth) private var isNarrow

    var body: some View {
        content(isNarrow)
    }
}

/// The time so far, counting up by itself, or held while paused. It takes all the width it's offered,
/// so `alignment` says which side of it the digits keep to.
private struct FocusTime: View {
    var state: FocusActivityAttributes.ContentState
    var alignment: TextAlignment

    var body: some View {
        Text(timerInterval: state.counting...Date.distantFuture, pauseTime: state.paused, countsDown: false, showsHours: true)
            .monospacedDigit()
            .multilineTextAlignment(alignment)
    }
}

private extension ActivityViewContext<FocusActivityAttributes> {
    /// Whether the time needs room for hours: once it's that far in, or once the Live Activity goes
    /// stale, which it's set to do right then so the system draws it again (see `FocusActivity`).
    var needsRoomForHours: Bool {
        isStale || state.needsRoomForHours
    }
}

private extension FocusActivityAttributes.ContentState {
    /// What the stones say to VoiceOver; on screen their pose and the time say it.
    var label: LocalizedStringKey {
        isPaused ? "Paused" : "Focusing"
    }

    var tint: Color {
        Color(.sRGB, red: sky[safe: 0] ?? 0.7, green: sky[safe: 1] ?? 0.75, blue: sky[safe: 2] ?? 0.8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
