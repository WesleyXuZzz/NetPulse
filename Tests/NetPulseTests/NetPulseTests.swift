import Foundation
import Testing
@testable import NetPulse

@Test
func speedFormatterProducesCompactUnits() async throws {
    #expect(SpeedFormatter.short(1536) == "1.5K")
    #expect(SpeedFormatter.detailed(1_048_576) == "1.0 M/s")
}

@Test
func speedFormatterCompactsMenuBarOutput() async throws {
    #expect(SpeedFormatter.menuBar(1_048_576) == "1M/s")
    #expect(SpeedFormatter.menuBar(1_536) == "1.5K/s")
    #expect(SpeedFormatter.menuBar(0) == "0K/s")
    #expect(SpeedFormatter.detailed(0) == "0 K/s")
    #expect(SpeedFormatter.menuBar(1_073_741_824) == "1G/s")
}

@Test
func refreshIntervalOptionsExposeExpectedSeconds() async throws {
    #expect(RefreshIntervalOption.halfSecond.interval == 0.5)
    #expect(RefreshIntervalOption.oneSecond.interval == 1.0)
    #expect(RefreshIntervalOption.twoSeconds.interval == 2.0)
}

@MainActor
@Test
func downloadAlertPreferencesDefaultToOneMegabyteOneMinuteAndTwentySeconds() async throws {
    let suiteName = "NetPulseTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let preferences = AppPreferences(defaults: defaults)
    #expect(preferences.downloadAlertEnabled == false)
    #expect(preferences.downloadAlertThreshold == DownloadAlertThresholdOption.oneMB)
    #expect(preferences.downloadAlertCooldown == DownloadAlertCooldownOption.oneMinute)
    #expect(preferences.downloadAlertDuration == DownloadAlertDurationOption.twentySeconds)

    defaults.removePersistentDomain(forName: suiteName)
}

@Test
func processTrafficParserExtractsNameAndPID() async throws {
    let parsed = ProcessTrafficMonitor.parseProcessLabel("Google Chrome H.1123")
    #expect(parsed.name == "Google Chrome H")
    #expect(parsed.pid == 1123)
}

@Test
func processTrafficParserBuildsEntryFromCSVRow() async throws {
    let row = "14:27:35.295869,codex.35911,,,221648,11012845,0,0,0"
    let parsed = ProcessTrafficMonitor.parseCSVRow(row)

    #expect(parsed?.sampleTime == "14:27:35.295869")
    #expect(parsed?.entry.name == "codex")
    #expect(parsed?.entry.pid == 35911)
    #expect(parsed?.entry.downloadBytesPerSecond == 221648)
    #expect(parsed?.entry.uploadBytesPerSecond == 11012845)
}
