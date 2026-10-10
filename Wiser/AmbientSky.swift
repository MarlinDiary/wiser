//
//  AmbientSky.swift
//  Wiser
//
//  Created by Marlin on 10/10/2026.
//

import SwiftUI
import WeatherKit

enum SkyWeather: String {
    case clear, partlyCloudy, cloudy, rain, snow, fog

    init(_ condition: WeatherCondition) {
        switch condition {
        case .partlyCloudy: self = .partlyCloudy
        case .mostlyCloudy, .cloudy: self = .cloudy
        case .drizzle, .rain, .heavyRain, .thunderstorms: self = .rain
        case .flurries, .snow, .heavySnow, .sleet: self = .snow
        case .foggy, .haze, .smoky: self = .fog
        default: self = .clear
        }
    }
}

// 日本の伝統色（低彩度）
private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    static let konNezumi = Color(hex: 0x44617B)  // 紺鼠
    static let aiNezumi = Color(hex: 0x6C848D)   // 藍鼠
    static let fujiNezumi = Color(hex: 0xA6A5C4) // 藤鼠
    static let ginNezumi = Color(hex: 0xAFAFB0)  // 銀鼠
    static let haiZakura = Color(hex: 0xE8D3D1)  // 灰桜
    static let hisoku = Color(hex: 0xABCED8)     // 秘色色
    static let sunaIro = Color(hex: 0xDCD3B2)    // 砂色
    static let kareIro = Color(hex: 0xE0C38C)    // 枯色
    static let araiGaki = Color(hex: 0xF2C9AC)   // 洗柿
    static let hatoba = Color(hex: 0x95859C)     // 鳩羽色
    static let shironeri = Color(hex: 0xF3F3F2)  // 白練
}

extension Color {
    /// A deep shade of the sky tint, for text and chart marks drawn on the ambient background.
    func ink(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? mix(with: .white, by: 0.6) : mix(with: .black, by: 0.55)
    }
}

enum AmbientSky {
    static func tint(at date: Date, sunrise: Date?, sunset: Date?, weather: SkyWeather) -> Color {
        let rise = sameTime(as: sunrise, on: date, fallbackHour: 6, minute: 30)
        let set = sameTime(as: sunset, on: date, fallbackHour: 18, minute: 30)
        let noon = rise.addingTimeInterval(set.timeIntervalSince(rise) / 2)

        let keyframes: [(time: Date, color: Color)] = [
            (rise.addingTimeInterval(-120 * 60), .konNezumi), // 夜
            (rise.addingTimeInterval(-45 * 60), .fujiNezumi), // 黎明
            (rise, .haiZakura),                               // 日出
            (rise.addingTimeInterval(90 * 60), .hisoku),      // 上午
            (noon, .hisoku),                                  // 正午
            (set.addingTimeInterval(-120 * 60), .sunaIro),    // 下午
            (set.addingTimeInterval(-40 * 60), .kareIro),     // 黄金时刻
            (set, .araiGaki),                                 // 日落
            (set.addingTimeInterval(40 * 60), .hatoba),       // 薄暮
            (set.addingTimeInterval(120 * 60), .konNezumi),   // 夜
        ]

        var tint = Color.konNezumi
        if let next = keyframes.firstIndex(where: { $0.time > date }), next > 0 {
            let from = keyframes[next - 1]
            let to = keyframes[next]
            let fraction = date.timeIntervalSince(from.time) / to.time.timeIntervalSince(from.time)
            tint = from.color.mix(with: to.color, by: fraction)
        }

        switch weather {
        case .clear: return tint
        case .partlyCloudy: return tint.mix(with: .ginNezumi, by: 0.25)
        case .cloudy: return tint.mix(with: .ginNezumi, by: 0.6)
        case .rain: return tint.mix(with: .aiNezumi, by: 0.55)
        case .snow: return tint.mix(with: .shironeri, by: 0.5)
        case .fog: return tint.mix(with: .shironeri, by: 0.6)
        }
    }

    // Sunrise and sunset can be from another day (cached), so only their time of day is used.
    private static func sameTime(as time: Date?, on day: Date, fallbackHour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        var hour = fallbackHour, minute = minute
        if let time {
            hour = calendar.component(.hour, from: time)
            minute = calendar.component(.minute, from: time)
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

/// Paper background washed with the sky tint, strongest at the top.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color

    var body: some View {
        let opacity: (top: Double, middle: Double, bottom: Double) = colorScheme == .dark
            ? (0.45, 0.26, 0.14)
            : (0.4, 0.23, 0.13)
        ZStack {
            Color(.secondarySystemBackground)
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(opacity.top), location: 0),
                    .init(color: tint.opacity(opacity.middle), location: 0.45),
                    .init(color: tint.opacity(opacity.bottom), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Soft light keeps the paper grain from washing out the tint.
            Image("NoiseTexture")
                .resizable(resizingMode: .tile)
                .blendMode(.softLight)
                .opacity(colorScheme == .dark ? 0.3 : 1)
        }
        .ignoresSafeArea()
    }
}
