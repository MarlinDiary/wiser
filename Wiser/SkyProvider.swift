//
//  SkyProvider.swift
//  Wiser
//
//  Created by Marlin on 27/03/2026.
//

import SwiftUI
import CoreLocation

@Observable
final class SkyProvider {
    private(set) var sunrise: Date?
    private(set) var sunset: Date?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let sunrise = "SkyProvider.sunrise"
        static let sunset = "SkyProvider.sunset"
    }

    private var fixedTime: DateComponents?

    init() {
        sunrise = defaults.object(forKey: Keys.sunrise) as? Date
        sunset = defaults.object(forKey: Keys.sunset) as? Date
    }

    /// Always shows the sky at the given time of day, for previews.
    init(time: DateComponents) {
        fixedTime = time
    }

    func sky(at date: Date) -> Color {
        return AmbientSky.tint(at: shown(date), sunrise: sunrise, sunset: sunset)
    }

    /// The light at `date`: where it comes from, and whether it's the sun's or the moon's.
    func daylight(at date: Date) -> Daylight {
        Daylight(path: AmbientSky.sunPath(at: shown(date), sunrise: sunrise, sunset: sunset),
                 isDay: AmbientSky.isDay(at: shown(date), sunrise: sunrise, sunset: sunset))
    }

    private func shown(_ date: Date) -> Date {
        guard let fixedTime else { return date }
        return Calendar.current.date(bySettingHour: fixedTime.hour ?? 0, minute: fixedTime.minute ?? 0, second: 0, of: date) ?? date
    }

    /// Works out today's sunrise and sunset where the phone is, on the phone, and keeps them for next time.
    func updateSunTimes(for location: CLLocation) {
        guard fixedTime == nil, let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now) else { return }
        let times = AmbientSky.sunTimes(around: noon, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        sunrise = times.sunrise
        sunset = times.sunset
        defaults.set(sunrise, forKey: Keys.sunrise)
        defaults.set(sunset, forKey: Keys.sunset)
    }
}
