//
//  WeatherManager.swift
//  boringNotch
//

import CoreLocation
import Defaults
import Foundation
import SwiftUI

// MARK: - Data Model

struct DayWeather: Identifiable {
    let id = UUID()
    let date: Date
    let weatherCode: Int
    let maxTemp: Double
    let minTemp: Double

    var sfSymbolName: String {
        switch weatherCode {
        case 0, 1:       return "sun.max.fill"
        case 2:          return "cloud.sun.fill"
        case 3:          return "cloud.fill"
        case 45, 48:     return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 71, 73, 75,
             77:         return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86:     return "cloud.snow.fill"
        case 95:         return "cloud.bolt.fill"
        case 96, 99:     return "cloud.bolt.rain.fill"
        default:         return "cloud.fill"
        }
    }

    var symbolColor: Color {
        switch weatherCode {
        case 0, 1:              return .yellow
        case 2:                 return Color(nsColor: .systemGray)
        case 3:                 return Color(nsColor: .systemGray).opacity(0.6)
        case 45, 48:            return Color(nsColor: .systemGray).opacity(0.6)
        case 51...65, 80...82: return .blue
        case 71...77, 85, 86:  return Color(red: 0.7, green: 0.85, blue: 1.0)
        case 95, 96, 99:        return .yellow
        default:                return Color(nsColor: .systemGray)
        }
    }

    var shortDescription: String {
        switch weatherCode {
        case 0:          return "Clear"
        case 1:          return "Mainly Clear"
        case 2:          return "Partly Cloudy"
        case 3:          return "Overcast"
        case 45, 48:     return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 61, 63, 65: return "Rain"
        case 71, 73, 75: return "Snow"
        case 77:         return "Snow Grains"
        case 80, 81, 82: return "Rain Showers"
        case 85, 86:     return "Snow Showers"
        case 95:         return "Thunderstorm"
        case 96, 99:     return "Thunderstorm"
        default:         return "Cloudy"
        }
    }
}

// MARK: - Manager

@MainActor
class WeatherManager: NSObject, ObservableObject {
    static let shared = WeatherManager()

    @Published var dailyWeather: [DayWeather] = []
    @Published var isLoading: Bool = false
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var locationName: String = ""
    @Published var fetchError: String?

    private let locationManager = CLLocationManager()
    private var lastFetchDate: Date?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = locationManager.authorizationStatus

        // Restore last known weather from cache if available
        restoreFromCache()
    }

    // MARK: - Public API

    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func refresh() {
        guard Defaults[.showWeatherInCalendar] else { return }

        if Defaults[.weatherUseManualLocation] {
            let city = Defaults[.weatherManualCity].trimmingCharacters(in: .whitespaces)
            guard !city.isEmpty else { return }
            Task { await fetchWeatherForCity(city) }
        } else {
            switch authorizationStatus {
            case .authorizedAlways:
                locationManager.requestLocation()
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            default:
                // Use cached coordinates if available
                if let lat = Defaults[.weatherCachedLatitude],
                   let lon = Defaults[.weatherCachedLongitude] {
                    Task { await fetchWeather(latitude: lat, longitude: lon) }
                }
            }
        }
    }

    func fetchWeatherForCity(_ city: String) async {
        isLoading = true
        fetchError = nil
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(city)
            guard let location = placemarks.first?.location else {
                fetchError = "Location not found"
                isLoading = false
                return
            }
            locationName = placemarks.first?.locality ?? city
            await fetchWeather(latitude: location.coordinate.latitude,
                               longitude: location.coordinate.longitude)
        } catch {
            fetchError = "Could not find \"\(city)\""
            isLoading = false
        }
    }

    // MARK: - Queries

    func weather(for date: Date) -> DayWeather? {
        dailyWeather.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    func isInForecastRange(_ date: Date) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: target).day ?? -1
        return days >= 0 && days < 7
    }

    func formattedTemp(_ celsius: Double) -> String {
        if Defaults[.weatherUseFahrenheit] {
            return "\(Int((celsius * 9 / 5) + 32))°F"
        }
        return "\(Int(celsius))°C"
    }

    // MARK: - Private

    private func fetchWeather(latitude: Double, longitude: Double) async {
        isLoading = true
        fetchError = nil
        defer { isLoading = false }

        let urlString = "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(latitude)&longitude=\(longitude)"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
            + "&timezone=auto&forecast_days=7"

        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current

            dailyWeather = zip(response.daily.time, zip(response.daily.weatherCode,
                zip(response.daily.temperature2mMax, response.daily.temperature2mMin)))
            .compactMap { time, rest in
                guard let date = formatter.date(from: time) else { return nil }
                let (code, (maxT, minT)) = rest
                return DayWeather(date: date, weatherCode: code, maxTemp: maxT, minTemp: minT)
            }

            Defaults[.weatherCachedLatitude] = latitude
            Defaults[.weatherCachedLongitude] = longitude
            lastFetchDate = Date()
        } catch {
            fetchError = "Unable to fetch weather"
        }
    }

    private func restoreFromCache() {
        guard let lat = Defaults[.weatherCachedLatitude],
              let lon = Defaults[.weatherCachedLongitude] else { return }
        Task { await fetchWeather(latitude: lat, longitude: lon) }
    }
}

// MARK: - CLLocationManagerDelegate

extension WeatherManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        Task { @MainActor in
            // Reverse-geocode to get a display name
            let geocoder = CLGeocoder()
            if let placemark = try? await geocoder.reverseGeocodeLocation(loc).first {
                self.locationName = placemark.locality ?? placemark.name ?? ""
            }
            await self.fetchWeather(latitude: lat, longitude: lon)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            // Fall back to cached coordinates silently
            if let lat = Defaults[.weatherCachedLatitude],
               let lon = Defaults[.weatherCachedLongitude] {
                await self.fetchWeather(latitude: lat, longitude: lon)
            } else {
                self.fetchError = "Location unavailable"
                self.isLoading = false
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}

// MARK: - Open-Meteo Response Model

private struct OpenMeteoResponse: Decodable {
    let daily: Daily

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double]
        let temperature2mMin: [Double]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode        = "weather_code"
            case temperature2mMax   = "temperature_2m_max"
            case temperature2mMin   = "temperature_2m_min"
        }
    }
}
