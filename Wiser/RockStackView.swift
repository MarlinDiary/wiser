//
//  RockStackView.swift
//  Wiser
//
//  Created by Marlin on 26/03/2026.
//

import SwiftUI

struct RockStackView: View {
    var state: RockState
    var shadowColor: Color = .black
    @State private var visualState: RockState? = nil
    @State private var isBouncing = false
    @State private var animationDuration: Double = 0.75

    private var displayState: RockState {
        visualState ?? state
    }

    private var bottomPadding: CGFloat {
        0
    }

    private var middlePadding: CGFloat {
        switch displayState {
        case .checked: 111
        case .idle: 40
        case .paused: 79
        }
    }

    private var topPadding: CGFloat {
        switch displayState {
        case .checked: 280
        case .idle: 150
        case .paused: 214
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            groundShadow

            RockBottomView(state: displayState)
                .padding(.bottom, bottomPadding)

            RockMiddleView(state: displayState)
                .padding(.bottom, middlePadding)

            RockTopView(state: displayState)
                .padding(.bottom, topPadding)
        }
        .frame(height: 364, alignment: .bottom)
        .animation(.easeInOut(duration: animationDuration), value: displayState)
        .onTapGesture {
            guard state == .idle, !isBouncing else { return }
            isBouncing = true

            let goDown = Double.random(in: 0.55...0.95)
            let hold = Double.random(in: 0.3...0.7)
            let goBack = Double.random(in: 0.55...0.95)
            let target: RockState = Bool.random() ? .paused : .checked

            animationDuration = goDown
            visualState = target
            DispatchQueue.main.asyncAfter(deadline: .now() + goDown + hold) {
                animationDuration = goBack
                visualState = .idle
                DispatchQueue.main.asyncAfter(deadline: .now() + goBack) {
                    visualState = nil
                    isBouncing = false
                }
            }
        }
    }

    /// Soft light from above: a faint shadow right under the bottom stone,
    /// a little denser in the middle where the stone is closest to the ground.
    private var groundShadow: some View {
        ZStack {
            Ellipse()
                .fill(shadowColor)
                .frame(width: 240, height: 32)
                .blur(radius: 14)
                .opacity(0.07)
                .offset(y: 3)
            Ellipse()
                .fill(shadowColor)
                .frame(width: 170, height: 14)
                .blur(radius: 6)
                .opacity(0.09)
                .offset(y: 2)
        }
        .frame(height: 0)
    }
}

#Preview("Checked") {
    RockStackView(state: .checked)
}

#Preview("Idle") {
    RockStackView(state: .idle)
}

#Preview("Paused") {
    RockStackView(state: .paused)
}
