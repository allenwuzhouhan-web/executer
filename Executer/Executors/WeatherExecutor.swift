import Foundation

struct GetWeatherTool: ToolDefinition {
    let name = "get_weather"
    let description = "Get the current weather and forecast for a location. Defaults to the user's current location (auto-detected via IP)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "location": JSONSchema.string(description: "City name, zip code, or 'auto' for auto-detect (default: auto)"),
            "include_forecast": JSONSchema.boolean(description: "Include today's forecast with high/low temps (default false)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let location = optionalString("location", from: args) ?? "auto:ip"
        let includeForecast = optionalBool("include_forecast", from: args) ?? false

        guard let apiKey = WeatherKeyStore.getKey() else {
            return "No weather API key configured. Set one in Settings or via the set_weather_key tool."
        }

        let query = location == "auto" ? "auto:ip" : location
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let endpoint: String
        if includeForecast {
            endpoint = "https://api.weatherapi.com/v1/forecast.json?key=\(apiKey)&q=\(encoded)&days=1&aqi=no"
        } else {
            endpoint = "https://api.weatherapi.com/v1/current.json?key=\(apiKey)&q=\(encoded)&aqi=no"
        }

        guard let url = URL(string: endpoint) else {
            return "Invalid location query."
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await PinnedURLSession.shared.session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return "Invalid weather API key." }
            if status == 400 { return "Location not found: \(location)" }
            return "Weather API error (HTTP \(status))."
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Failed to parse weather data."
        }

        return formatWeather(json, includeForecast: includeForecast)
    }

    private func formatWeather(_ json: [String: Any], includeForecast: Bool) -> String {
        guard let location = json["location"] as? [String: Any],
              let current = json["current"] as? [String: Any] else {
            return "Could not parse weather response."
        }

        let city = location["name"] as? String ?? "Unknown"
        let region = location["region"] as? String ?? ""
        let condition = (current["condition"] as? [String: Any])?["text"] as? String ?? "Unknown"
        let tempF = current["temp_f"] as? Double ?? 0
        let tempC = current["temp_c"] as? Double ?? 0
        let feelsLikeF = current["feelslike_f"] as? Double ?? 0
        let humidity = current["humidity"] as? Int ?? 0
        let windMph = current["wind_mph"] as? Double ?? 0
        let windDir = current["wind_dir"] as? String ?? ""
        let uv = current["uv"] as? Double ?? 0

        var locationStr = city
        if !region.isEmpty && region != city { locationStr += ", \(region)" }

        var lines: [String] = [
            "Weather for \(locationStr):",
            "- \(condition), \(Int(tempF))°F (\(Int(tempC))°C)",
            "- Feels like \(Int(feelsLikeF))°F",
            "- Humidity: \(humidity)%",
            "- Wind: \(Int(windMph)) mph \(windDir)",
        ]

        if uv > 0 {
            lines.append("- UV index: \(Int(uv))")
        }

        if includeForecast,
           let forecast = json["forecast"] as? [String: Any],
           let forecastDays = forecast["forecastday"] as? [[String: Any]],
           let today = forecastDays.first,
           let day = today["day"] as? [String: Any] {

            let maxF = day["maxtemp_f"] as? Double ?? 0
            let minF = day["mintemp_f"] as? Double ?? 0
            let dailyCondition = (day["condition"] as? [String: Any])?["text"] as? String ?? ""
            let chanceOfRain = day["daily_chance_of_rain"] as? Int ?? 0

            lines.append("Today's forecast:")
            lines.append("- High \(Int(maxF))°F / Low \(Int(minF))°F — \(dailyCondition)")
            if chanceOfRain > 0 {
                lines.append("- \(chanceOfRain)% chance of rain")
            }
        }

        return lines.joined(separator: "\n")
    }
}

struct SetWeatherKeyTool: ToolDefinition {
    let name = "set_weather_key"
    let description = "Set the WeatherAPI.com API key for weather lookups."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "key": JSONSchema.string(description: "The WeatherAPI.com API key")
        ], required: ["key"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let key = try requiredString("key", from: args)
        WeatherKeyStore.setKey(key)
        return "Weather API key saved."
    }
}

// Simple keychain-backed storage for the weather API key
enum WeatherKeyStore {
    private static let keychainKey = "weather_api_key"

    static func getKey() -> String? {
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        _ = KeychainHelper.save(key: keychainKey, data: data)
    }

    static func delete() {
        KeychainHelper.delete(key: keychainKey)
    }

    static func hasKey() -> Bool {
        getKey() != nil
    }
}
