//
//  SkyProvider.swift
//  Wiser
//
//  Created by Marlin on 27/03/2026.
//

import SwiftUI
import WeatherKit
import CoreLocation

@Observable
final class SkyProvider {
    private(set) var sunrise: Date?
    private(set) var sunset: Date?
    private(set) var skyWeather: SkyWeather = .clear
    private let weatherService = WeatherService.shared

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let skyWeather = "SkyProvider.skyWeather"
        static let sunrise = "SkyProvider.sunrise"
        static let sunset = "SkyProvider.sunset"
    }

    private var fixedTime: DateComponents?

    init() {
        skyWeather = defaults.string(forKey: Keys.skyWeather).flatMap(SkyWeather.init(rawValue:)) ?? .clear
        sunrise = defaults.object(forKey: Keys.sunrise) as? Date
        sunset = defaults.object(forKey: Keys.sunset) as? Date
    }

    /// Always shows the sky at the given time of day, for previews.
    init(time: DateComponents, weather: SkyWeather = .clear) {
        fixedTime = time
        skyWeather = weather
    }

    func sky(at date: Date) -> Color {
        var date = date
        if let fixedTime {
            date = Calendar.current.date(bySettingHour: fixedTime.hour ?? 0, minute: fixedTime.minute ?? 0, second: 0, of: date) ?? date
        }
        return AmbientSky.tint(at: date, sunrise: sunrise, sunset: sunset, weather: skyWeather)
    }

    func fetchWeather(for location: CLLocation) async {
        guard fixedTime == nil else { return }
        do {
            let weather = try await weatherService.weather(for: location)
            if let today = weather.dailyForecast.first {
                sunrise = today.sun.sunrise
                sunset = today.sun.sunset
                defaults.set(sunrise, forKey: Keys.sunrise)
                defaults.set(sunset, forKey: Keys.sunset)
            }
            withAnimation(.easeInOut(duration: 2)) {
                skyWeather = SkyWeather(weather.currentWeather.condition)
            }
            defaults.set(skyWeather.rawValue, forKey: Keys.skyWeather)
        } catch {
            print("WeatherKit error: \(error.localizedDescription)")
        }
    }
}
