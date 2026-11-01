//
//  AmbientSky.swift
//  Wiser
//
//  Created by Marlin on 10/10/2026.
//

import SwiftUI

/// The light at a moment: where along its path it comes from, and whether it's the sun's or the moon's.
struct Daylight: Equatable {
    /// See `AmbientSky.sunPath`.
    var path: Float
    /// Whether the sun is up; at night the path is the moon's.
    var isDay = true
}

// Traditional Japanese colors, all low in saturation.
private enum TraditionalColor: UInt32 {
    case konNezumi = 0x44617B  // navy gray
    case fujiNezumi = 0xA6A5C4 // wisteria gray
    case haiZakura = 0xE8D3D1  // ashen cherry blossom
    case hisoku = 0xABCED8     // celadon blue
    case sunaIro = 0xDCD3B2    // sand
    case kareIro = 0xE0C38C    // withered grass
    case araiGaki = 0xF2C9AC   // washed persimmon
    case hatoba = 0x95859C     // dove-wing purple
    case shironeri = 0xF3F3F2  // raw-silk white

    var color: Color {
        Color(red: Double((rawValue >> 16) & 0xFF) / 255,
              green: Double((rawValue >> 8) & 0xFF) / 255,
              blue: Double(rawValue & 0xFF) / 255)
    }
}

extension Color {
    /// A deep shade of the sky tint, for text and chart marks drawn on the ambient background.
    func ink(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? mix(with: .white, by: 0.6) : mix(with: .black, by: 0.55)
    }
}

enum AmbientSky {
    /// The sky's tint at `date`: the colors of the day's moments flowing into one another without ever
    /// holding still or turning a corner.
    static func tint(at date: Date, sunrise: Date?, sunset: Date?) -> Color {
        let sky = skyColor(at: date, sunrise: sunrise, sunset: sunset)
        return Color(.sRGB, red: sky.x, green: sky.y, blue: sky.z)
    }

    /// The sky's color at `date`, in sRGB: low-saturation traditional colors at the moments of the day,
    /// and between them a smooth curve through them all, worked in a perceptual color space so no muddy or
    /// overly bright colors appear along the way.
    private static func skyColor(at date: Date, sunrise: Date?, sunset: Date?) -> SIMD3<Double> {
        // The moments of the days around `date`, so there are always two on each side of it.
        var moments: [(time: Double, color: SIMD3<Double>)] = []
        for day in -1...1 {
            let shifted = Calendar.current.date(byAdding: .day, value: day, to: date) ?? date
            let rise = sameTime(as: sunrise, on: shifted, fallbackHour: 6, minute: 30).timeIntervalSinceReferenceDate
            let set = sameTime(as: sunset, on: shifted, fallbackHour: 18, minute: 30).timeIntervalSinceReferenceDate
            let night = 24 * 3600 - (set - rise)
            moments += [
                (rise - 120 * 60, lab(.konNezumi)),                          // night
                (rise - 45 * 60, lab(.fujiNezumi)),                          // dawn
                (rise, lab(.haiZakura)),                                     // sunrise
                (rise + 90 * 60, lab(.hisoku)),                              // morning
                ((rise + set) / 2, mix(lab(.hisoku), lab(.shironeri), 0.2)), // noon, a little paler
                (set - 120 * 60, lab(.sunaIro)),                             // afternoon
                (set - 40 * 60, lab(.kareIro)),                              // golden hour
                (set, lab(.araiGaki)),                                       // sunset
                (set + 40 * 60, lab(.hatoba)),                               // dusk
                (set + 120 * 60, lab(.konNezumi)),                           // night
                (set + night / 2, lab(.konNezumi) * SIMD3(0.92, 1, 1)),      // midnight, a little deeper
            ]
        }
        moments.sort { $0.time < $1.time }
        let t = date.timeIntervalSinceReferenceDate
        guard let next = moments.firstIndex(where: { $0.time > t }), next > 1, next + 1 < moments.count else {
            return srgb(fromLab: moments[0].color)
        }
        // A monotone cubic through each channel: smooth, and never overshooting the moments' colors.
        let k = next - 1
        let times = moments.map(\.time)
        func slope(at i: Int, _ channel: Int) -> Double {
            let before = (moments[i].color[channel] - moments[i - 1].color[channel]) / (times[i] - times[i - 1])
            let after = (moments[i + 1].color[channel] - moments[i].color[channel]) / (times[i + 1] - times[i])
            guard before * after > 0 else { return 0 }
            let h0 = times[i] - times[i - 1], h1 = times[i + 1] - times[i]
            let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
            return (w0 + w1) / (w0 / before + w1 / after)
        }
        let h = times[k + 1] - times[k]
        let s = (t - times[k]) / h
        var color = SIMD3<Double>()
        for channel in 0..<3 {
            let y0 = moments[k].color[channel], y1 = moments[k + 1].color[channel]
            let m0 = slope(at: k, channel) * h, m1 = slope(at: k + 1, channel) * h
            color[channel] = (2 * s * s * s - 3 * s * s + 1) * y0 + (s * s * s - 2 * s * s + s) * m0
                + (-2 * s * s * s + 3 * s * s) * y1 + (s * s * s - s * s) * m1
        }
        return srgb(fromLab: color)
    }

    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }

    /// A color in Oklab.
    private static func lab(_ color: TraditionalColor) -> SIMD3<Double> {
        let hex = color.rawValue
        let c = SIMD3(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)) / 255
        let linear = SIMD3(c.indices.map { i in c[i] <= 0.04045 ? c[i] / 12.92 : pow((c[i] + 0.055) / 1.055, 2.4) })
        let l = cbrt(0.4122214708 * linear.x + 0.5363325363 * linear.y + 0.0514459929 * linear.z)
        let m = cbrt(0.2119034982 * linear.x + 0.6806995451 * linear.y + 0.1073969566 * linear.z)
        let s = cbrt(0.0883024619 * linear.x + 0.2817188376 * linear.y + 0.6299787005 * linear.z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func srgb(fromLab lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        let linear = SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                           -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                           -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        return SIMD3(linear.indices.map { i in
            let c = min(1, max(0, linear[i]))
            return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        })
    }

    /// Where the light comes from at `date`, along the sun's path: -1 low on the left at sunrise, 0 high
    /// at midday, 1 low on the right at sunset. Through the night it drifts back to the left, so it's
    /// there again by morning without ever jumping.
    static func sunPath(at date: Date, sunrise: Date?, sunset: Date?) -> Float {
        let rise = sameTime(as: sunrise, on: date, fallbackHour: 6, minute: 30)
        let set = sameTime(as: sunset, on: date, fallbackHour: 18, minute: 30)
        let day = set.timeIntervalSince(rise)
        if date >= rise, date <= set {
            return Float(date.timeIntervalSince(rise) / day) * 2 - 1
        }
        let sinceSunset = date > set ? date.timeIntervalSince(set) : date.timeIntervalSince(set) + 24 * 3600
        return 1 - Float(sinceSunset / (24 * 3600 - day)) * 2
    }

    /// Whether `date` falls between sunrise and sunset.
    static func isDay(at date: Date, sunrise: Date?, sunset: Date?) -> Bool {
        let rise = sameTime(as: sunrise, on: date, fallbackHour: 6, minute: 30)
        let set = sameTime(as: sunset, on: date, fallbackHour: 18, minute: 30)
        return date >= rise && date <= set
    }

    /// When the sun rises and sets at `latitude` and `longitude` (degrees, north and east positive) on the
    /// day around `noon`: when the top of the sun meets a level horizon, its middle 0.833° below it, as
    /// the air bends its light up over the horizon by the usual amount. Worked out from where the Earth is
    /// on its orbit (NOAA's solar calculations, after Meeus), to within about a minute away from the polar
    /// circles. Nil where the sun doesn't rise or set that day.
    nonisolated static func sunTimes(around noon: Date, latitude: Double, longitude: Double) -> (sunrise: Date?, sunset: Date?) {
        let degree = Double.pi / 180
        let latitude = latitude * degree
        // The sun's hour angle at the moment wanted, `side` of noon, worked out again at that moment until
        // it settles, since the sun moves along its orbit meanwhile.
        func event(_ side: Double) -> Date? {
            var time = noon
            for _ in 0..<4 {
                let sun = sunPosition(at: time)
                let x = (cos(90.833 * degree) - sin(latitude) * sin(sun.declination)) / (cos(latitude) * cos(sun.declination))
                guard abs(x) <= 1 else { return nil }
                let target = side * acos(x) / degree
                let hourAngle = (time.timeIntervalSince1970 / 60 + sun.equationOfTime + 4 * longitude) / 4 - 180
                // A degree of hour angle is four minutes.
                time += (target - hourAngle).remainder(dividingBy: 360) * 240
            }
            return time
        }
        return (event(-1), event(1))
    }

    /// How far the sun is north of the equator (radians), and how far a sundial runs ahead of the clock
    /// (minutes), at `date`.
    nonisolated private static func sunPosition(at date: Date) -> (declination: Double, equationOfTime: Double) {
        let degree = Double.pi / 180
        let t = (date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545) / 36525 // Julian centuries since 2000
        let meanLongitude = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360) * degree
        let meanAnomaly = (357.52911 + t * (35999.05029 - 0.0001537 * t)) * degree
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let center = sin(meanAnomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * meanAnomaly) * (0.019993 - 0.000101 * t) + sin(3 * meanAnomaly) * 0.000289
        let node = (125.04 - 1934.136 * t) * degree
        let longitude = meanLongitude / degree + center - 0.00569 - 0.00478 * sin(node)
        let obliquity = (23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60 + 0.00256 * cos(node)) * degree
        let declination = asin(sin(obliquity) * sin(longitude * degree))
        let y = pow(tan(obliquity / 2), 2)
        let equationOfTime = 4 / degree * (y * sin(2 * meanLongitude) - 2 * eccentricity * sin(meanAnomaly)
            + 4 * eccentricity * y * sin(meanAnomaly) * cos(2 * meanLongitude) - 0.5 * y * y * sin(4 * meanLongitude)
            - 1.25 * eccentricity * eccentricity * sin(2 * meanAnomaly))
        return (declination, equationOfTime)
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

    /// How strongly the tint washes over the paper at the top, middle and bottom of the screen.
    static func wash(for colorScheme: ColorScheme) -> (top: Double, middle: Double, bottom: Double) {
        colorScheme == .dark ? (0.45, 0.26, 0.14) : (0.4, 0.23, 0.13)
    }

    var body: some View {
        let opacity = Self.wash(for: colorScheme)
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
