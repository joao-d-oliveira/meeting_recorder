import Foundation

public final class SettingsStore {
    private static let key = "settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ settings: RecordingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data)
        else { return RecordingSettings() }
        return settings
    }
}
