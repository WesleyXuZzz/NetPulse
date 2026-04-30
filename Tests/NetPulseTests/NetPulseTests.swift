import AppKit
import Foundation
import Testing
@testable import NetPulse

private func makeTestCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func makeTestDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    calendar: Calendar
) -> Date {
    DateComponents(calendar: calendar, year: year, month: month, day: day, hour: hour).date!
}

private func makeTemporaryHistoryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("NetPulseTests-\(UUID().uuidString)-history.json")
}

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
    #expect(SpeedFormatter.menuBar(999.4 * 1024 * 1024) == "999M/s")
    #expect(SpeedFormatter.menuBar(999.5 * 1024 * 1024) == "1G/s")
    #expect(SpeedFormatter.menuBar(Double.greatestFiniteMagnitude) == "999P/s")
    #expect(SpeedFormatter.menuBar(Double.greatestFiniteMagnitude).count <= 6)
}

@Test
func speedFormatterFormatsTotalBytesWithoutRateSuffix() async throws {
    #expect(SpeedFormatter.totalBytes(0) == "0 B")
    #expect(SpeedFormatter.totalBytes(512) == "512 B")
    #expect(SpeedFormatter.totalBytes(1536) == "1.5 KB")
    #expect(SpeedFormatter.totalBytes(1_048_576) == "1.0 MB")
    #expect(!SpeedFormatter.totalBytes(1_048_576).contains("/s"))
}

@Test
func menuBarStatusContentBuildsTwoLineTrafficForBothDirections() async throws {
    let content = MenuBarStatusContent.make(
        isSleeping: false,
        isNetworkAvailable: true,
        displayMode: .both,
        downloadBytesPerSecond: 1_048_576,
        uploadBytesPerSecond: 1_536
    )

    #expect(content == .traffic(download: "1M/s", upload: "1.5K/s"))
    #expect(content.displayTitle == "↓1M/s ↑1.5K/s")
}

@Test
func menuBarStatusContentCollapsesOfflineAndSleepStates() async throws {
    let offline = MenuBarStatusContent.make(
        isSleeping: false,
        isNetworkAvailable: false,
        displayMode: .both,
        downloadBytesPerSecond: 1_048_576,
        uploadBytesPerSecond: 1_536
    )
    let sleeping = MenuBarStatusContent.make(
        isSleeping: true,
        isNetworkAvailable: true,
        displayMode: .both,
        downloadBytesPerSecond: 1_048_576,
        uploadBytesPerSecond: 1_536
    )

    #expect(offline == .status("离线"))
    #expect(sleeping == .status("睡眠"))
}

@Test
func menuBarStatusContentRespectsSingleDirectionDisplayModes() async throws {
    let download = MenuBarStatusContent.make(
        isSleeping: false,
        isNetworkAvailable: true,
        displayMode: .downloadOnly,
        downloadBytesPerSecond: 1_048_576,
        uploadBytesPerSecond: 1_536
    )
    let upload = MenuBarStatusContent.make(
        isSleeping: false,
        isNetworkAvailable: true,
        displayMode: .uploadOnly,
        downloadBytesPerSecond: 1_048_576,
        uploadBytesPerSecond: 1_536
    )

    #expect(download == .singleTraffic(direction: .download, speed: "1M/s"))
    #expect(download.displayTitle == "↓1M/s")
    #expect(upload == .singleTraffic(direction: .upload, speed: "1.5K/s"))
    #expect(upload.displayTitle == "↑1.5K/s")
}

@Test
func menuBarStatusContentRestoresCachedTitles() async throws {
    #expect(
        MenuBarStatusContent.restored(title: "↓1M/s ↑1.5K/s", displayMode: .both) ==
            .traffic(download: "1M/s", upload: "1.5K/s")
    )
    #expect(
        MenuBarStatusContent.restored(title: "1M/s", displayMode: .downloadOnly) ==
            .singleTraffic(direction: .download, speed: "1M/s")
    )
    #expect(MenuBarStatusContent.restored(title: "离线", displayMode: .both) == .status("离线"))
}

@MainActor
@Test
func menuBarStatusLayoutKeepsTrafficWidthFixedAcrossSpeedLengths() async throws {
    let contents: [MenuBarStatusContent] = [
        .traffic(download: "3.3K/s", upload: "6.8K/s"),
        .traffic(download: "6K/s", upload: "185K/s"),
        .traffic(download: "18.7K/s", upload: "440K/s"),
        .traffic(download: "99.9K/s", upload: "99.9P/s"),
    ]
    let widths = contents.map(MenuBarStatusLayout.itemLength(for:))

    #expect(Set(widths).count == 1)
}

@MainActor
@Test
func menuBarStatusLayoutKeepsSingleDirectionWidthFixedAcrossSpeedLengths() async throws {
    let contents: [MenuBarStatusContent] = [
        .singleTraffic(direction: .download, speed: "3.3K/s"),
        .singleTraffic(direction: .download, speed: "18.7K/s"),
        .singleTraffic(direction: .download, speed: "440K/s"),
        .singleTraffic(direction: .download, speed: "99.9P/s"),
    ]
    let widths = contents.map(MenuBarStatusLayout.itemLength(for:))

    #expect(Set(widths).count == 1)
}

@MainActor
@Test
func menuBarStatusLayoutCollapsesOfflineAndSleepWidth() async throws {
    let trafficWidth = MenuBarStatusLayout.itemLength(
        for: .traffic(download: "3.3K/s", upload: "6.8K/s")
    )
    let offlineWidth = MenuBarStatusLayout.itemLength(for: .status("离线"))
    let sleepWidth = MenuBarStatusLayout.itemLength(for: .status("睡眠"))

    #expect(trafficWidth > offlineWidth)
    #expect(trafficWidth > sleepWidth)
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

@MainActor
@Test
func appTrafficHistoryPreferenceDefaultsToDisabled() async throws {
    let suiteName = "NetPulseTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let preferences = AppPreferences(defaults: defaults)
    #expect(preferences.appTrafficHistoryEnabled == false)

    defaults.removePersistentDomain(forName: suiteName)
}

@MainActor
@Test
func appTrafficHistoryStoreAccumulatesSamplesByDayAndApp() async throws {
    let calendar = makeTestCalendar()
    let store = AppTrafficHistoryStore(
        fileURL: makeTemporaryHistoryURL(),
        calendar: calendar,
        writeDelay: 60
    )
    let date = makeTestDate(year: 2026, month: 4, day: 30, hour: 12, calendar: calendar)

    store.record(
        entries: [
            ProcessTrafficEntry(
                name: "Safari Networking",
                pid: 100,
                downloadBytesPerSecond: 100,
                uploadBytesPerSecond: 20,
                identity: "bundle:com.apple.Safari"
            ),
        ],
        at: date,
        sampleInterval: 2
    )
    store.record(
        entries: [
            ProcessTrafficEntry(
                name: "Safari",
                pid: 101,
                downloadBytesPerSecond: 50,
                uploadBytesPerSecond: 10,
                identity: "bundle:com.apple.Safari"
            ),
        ],
        at: date.addingTimeInterval(1),
        sampleInterval: 1
    )

    #expect(store.days.count == 1)
    #expect(store.days.first?.id == "2026-04-30")
    #expect(store.days.first?.entries.count == 1)
    #expect(store.days.first?.entries.first?.displayName == "Safari")
    #expect(store.days.first?.entries.first?.downloadBytes == 250)
    #expect(store.days.first?.entries.first?.uploadBytes == 50)
    #expect(store.selectedDayID == "2026-04-30")
}

@MainActor
@Test
func appTrafficHistoryStoreSeparatesDaysAndPrunesAfterRetention() async throws {
    let calendar = makeTestCalendar()
    let store = AppTrafficHistoryStore(
        fileURL: makeTemporaryHistoryURL(),
        calendar: calendar,
        retentionDays: 30,
        writeDelay: 60
    )
    let recentDate = makeTestDate(year: 2026, month: 4, day: 30, hour: 12, calendar: calendar)
    let previousDate = makeTestDate(year: 2026, month: 4, day: 29, hour: 12, calendar: calendar)
    let expiredDate = makeTestDate(year: 2026, month: 3, day: 1, hour: 12, calendar: calendar)
    let entry = ProcessTrafficEntry(
        name: "Safari",
        pid: nil,
        downloadBytesPerSecond: 1,
        uploadBytesPerSecond: 1,
        identity: "bundle:com.apple.Safari"
    )

    store.record(entries: [entry], at: previousDate, sampleInterval: 1)
    store.record(entries: [entry], at: recentDate, sampleInterval: 1)
    store.record(entries: [entry], at: expiredDate, sampleInterval: 1)
    store.pruneHistory(now: recentDate)

    #expect(store.days.map(\.id) == ["2026-04-30", "2026-04-29"])
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

@Test
func processTrafficParserBuildsEntryFromCompactCSVRow() async throws {
    let row = "14:27:35.295869,codex.35911,221648,11012845,"
    let parsed = ProcessTrafficMonitor.parseCSVRow(row)

    #expect(parsed?.sampleTime == "14:27:35.295869")
    #expect(parsed?.entry.name == "codex")
    #expect(parsed?.entry.pid == 35911)
    #expect(parsed?.entry.downloadBytesPerSecond == 221648)
    #expect(parsed?.entry.uploadBytesPerSecond == 11012845)
}

@Test
func processTrafficParserGroupsRowsByHeadersAndSkipsBaselineSample() async throws {
    let csv = """
    time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
    14:27:35.295869,baseline.1,,,900000,100000,0,0,0,,,,,,,,,,,,
    14:27:35.295870,ignored.2,,,500000,100000,0,0,0,,,,,,,,,,,,
    time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
    14:27:36.295869,small.3,,,100,0,0,0,0,,,,,,,,,,,,
    14:27:36.295870,large.4,,,400,600,0,0,0,,,,,,,,,,,,
    14:27:36.295871,zero.5,,,0,0,0,0,0,,,,,,,,,,,,
    14:27:36.295872,medium.6,,,200,100,0,0,0,,,,,,,,,,,,
    14:27:36.295873,nettop.7,,,8000,8000,0,0,0,,,,,,,,,,,,
    14:27:36.295874,NetPulse.8,,,7000,7000,0,0,0,,,,,,,,,,,,
    """

    let samples = ProcessTrafficMonitor.parseDisplaySamples(from: csv)

    #expect(samples.count == 1)
    #expect(samples.first?.map(\.name) == ["large", "medium", "small"])
    #expect(samples.first?.map(\.pid) == [4, 6, 3])
}

@Test
func processTrafficParserGroupsCompactRowsBySampleTimeWhenHeaderIsNotRepeated() async throws {
    let csv = """
    time,,bytes_in,bytes_out,
    14:27:35.295869,baseline.1,900000,100000,
    14:27:35.295870,ignored.2,500000,100000,
    14:27:36.295869,small.3,100,0,
    14:27:36.295870,large.4,400,600,
    14:27:36.295871,zero.5,0,0,
    14:27:36.295872,medium.6,200,100,
    """

    let samples = ProcessTrafficMonitor.parseDisplaySamples(from: csv)

    #expect(samples.count == 1)
    #expect(samples.first?.map(\.name) == ["large", "medium", "small"])
    #expect(samples.first?.map(\.pid) == [4, 6, 3])
}

@Test
func processTrafficTopEntriesAggregatesProcessesByApplicationIdentity() async throws {
    let entries = [
        ProcessTrafficEntry(
            name: "Code Helper",
            pid: 10,
            downloadBytesPerSecond: 100,
            uploadBytesPerSecond: 50
        ),
        ProcessTrafficEntry(
            name: "Code Helper",
            pid: 11,
            downloadBytesPerSecond: 300,
            uploadBytesPerSecond: 20
        ),
        ProcessTrafficEntry(
            name: "Safari",
            pid: 20,
            downloadBytesPerSecond: 200,
            uploadBytesPerSecond: 10
        ),
    ]

    let topEntries = ProcessTrafficMonitor.topEntries(from: entries) { entry in
        switch entry.pid {
        case 10, 11:
            ProcessTrafficApplicationIdentity(
                key: "bundle:com.microsoft.VSCode",
                displayName: "Visual Studio Code"
            )
        case 20:
            ProcessTrafficApplicationIdentity(
                key: "bundle:com.apple.Safari",
                displayName: "Safari"
            )
        default:
            nil
        }
    }

    #expect(topEntries.count == 2)
    #expect(topEntries[0].name == "Visual Studio Code")
    #expect(topEntries[0].pid == nil)
    #expect(topEntries[0].downloadBytesPerSecond == 400)
    #expect(topEntries[0].uploadBytesPerSecond == 70)
    #expect(topEntries[0].pidLabel == "2 个进程 · Code Helper 等")
    #expect(topEntries[1].name == "Safari")
    #expect(topEntries[1].downloadBytesPerSecond == 200)
    #expect(topEntries[1].uploadBytesPerSecond == 10)
}

@Test
func processTrafficTopEntriesFallsBackToOriginalProcessWhenApplicationIsUnknown() async throws {
    let entries = [
        ProcessTrafficEntry(
            name: "python",
            pid: 10,
            downloadBytesPerSecond: 100,
            uploadBytesPerSecond: 50
        ),
        ProcessTrafficEntry(
            name: "python",
            pid: 11,
            downloadBytesPerSecond: 300,
            uploadBytesPerSecond: 20
        ),
    ]

    let topEntries = ProcessTrafficMonitor.topEntries(from: entries)

    #expect(topEntries.count == 2)
    #expect(topEntries.map(\.name) == ["python", "python"])
    #expect(topEntries.map(\.pid) == [11, 10])
    #expect(topEntries.map(\.pidLabel) == ["PID 11", "PID 10"])
}

@Test
func processTrafficAggregatedEntriesKeepsFullAppHistoryInput() async throws {
    let entries = [
        ProcessTrafficEntry(name: "A", pid: 1, downloadBytesPerSecond: 500, uploadBytesPerSecond: 0),
        ProcessTrafficEntry(name: "B", pid: 2, downloadBytesPerSecond: 400, uploadBytesPerSecond: 0),
        ProcessTrafficEntry(name: "C", pid: 3, downloadBytesPerSecond: 300, uploadBytesPerSecond: 0),
        ProcessTrafficEntry(name: "D", pid: 4, downloadBytesPerSecond: 200, uploadBytesPerSecond: 0),
    ]

    let aggregatedEntries = ProcessTrafficMonitor.aggregatedEntries(from: entries)
    let topEntries = ProcessTrafficMonitor.topEntries(from: entries)

    #expect(aggregatedEntries.map(\.name) == ["A", "B", "C", "D"])
    #expect(topEntries.map(\.name) == ["A", "B", "C"])
}

@MainActor
@Test
func processTrafficMonitorSkipsBaselineBeforeHistoryCallback() async throws {
    let monitor = ProcessTrafficMonitor()
    let now = Date()
    var recordedSamples: [[ProcessTrafficEntry]] = []
    let entries = [
        ProcessTrafficEntry(name: "A", pid: 1, downloadBytesPerSecond: 500, uploadBytesPerSecond: 0),
        ProcessTrafficEntry(name: "B", pid: 2, downloadBytesPerSecond: 400, uploadBytesPerSecond: 0),
        ProcessTrafficEntry(name: "C", pid: 3, downloadBytesPerSecond: 300, uploadBytesPerSecond: 0),
        ProcessTrafficEntry(name: "D", pid: 4, downloadBytesPerSecond: 200, uploadBytesPerSecond: 0),
    ]

    monitor.appTrafficSampleHandler = { entries, _, sampleInterval in
        #expect(sampleInterval == 1.0)
        recordedSamples.append(entries)
    }

    monitor.recordProcessSampleForTesting(entries, at: now)
    monitor.recordProcessSampleForTesting(entries, at: now.addingTimeInterval(1))

    #expect(recordedSamples.count == 1)
    #expect(recordedSamples.first?.map(\.name) == ["A", "B", "C", "D"])
    #expect(monitor.topEntries.map(\.name) == ["A", "B", "C"])
}

@Test
func processTrafficTopEntriesKeepsFilteringNetPulseAndNettopAfterApplicationLookup() async throws {
    let entries = [
        ProcessTrafficEntry(
            name: "nettop",
            pid: 10,
            downloadBytesPerSecond: 1_000_000,
            uploadBytesPerSecond: 1_000_000
        ),
        ProcessTrafficEntry(
            name: "NetPulse",
            pid: 11,
            downloadBytesPerSecond: 1_000_000,
            uploadBytesPerSecond: 1_000_000
        ),
        ProcessTrafficEntry(
            name: "NetPulse Helper",
            pid: 12,
            downloadBytesPerSecond: 1_000_000,
            uploadBytesPerSecond: 1_000_000
        ),
        ProcessTrafficEntry(
            name: "Safari Networking",
            pid: 20,
            downloadBytesPerSecond: 200,
            uploadBytesPerSecond: 10
        ),
    ]

    let topEntries = ProcessTrafficMonitor.topEntries(from: entries) { entry in
        switch entry.pid {
        case 12:
            ProcessTrafficApplicationIdentity(key: "bundle:com.netpulse.app", displayName: "NetPulse")
        case 20:
            ProcessTrafficApplicationIdentity(key: "bundle:com.apple.Safari", displayName: "Safari")
        default:
            nil
        }
    }

    #expect(topEntries.count == 1)
    #expect(topEntries.first?.name == "Safari")
    #expect(topEntries.first?.pidLabel == "Safari Networking · PID 20")
}

@Test
@MainActor
func processTrafficMonitorKeepsFreshSamplesVisible() async throws {
    let monitor = ProcessTrafficMonitor()
    let now = Date()
    let entry = ProcessTrafficEntry(
        name: "Safari",
        pid: 42,
        downloadBytesPerSecond: 2048,
        uploadBytesPerSecond: 1024
    )

    monitor.recordDisplaySampleForTesting([entry], at: now)
    monitor.refreshFreshnessState(now: now.addingTimeInterval(2))

    #expect(monitor.topEntries == [entry])
    #expect(monitor.samplingState == .live)
    #expect(monitor.statusText == "实时统计系统进程流量")
    #expect(monitor.freshnessText == "更新于 2 秒前")
}

@Test
@MainActor
func processTrafficMonitorKeepsRecentlyStaleSamplesVisible() async throws {
    let monitor = ProcessTrafficMonitor()
    let now = Date()
    let entry = ProcessTrafficEntry(
        name: "Safari",
        pid: 42,
        downloadBytesPerSecond: 2048,
        uploadBytesPerSecond: 1024
    )

    monitor.recordDisplaySampleForTesting([entry], at: now.addingTimeInterval(-4))
    monitor.refreshFreshnessState(now: now)

    #expect(monitor.topEntries == [entry])
    #expect(monitor.samplingState == .stale)
    #expect(monitor.statusText == "正在获取新的进程流量")
    #expect(monitor.freshnessText == "更新于 4 秒前")
}

@Test
@MainActor
func processTrafficMonitorHidesExpiredStaleSamples() async throws {
    let monitor = ProcessTrafficMonitor()
    let now = Date()
    let entry = ProcessTrafficEntry(
        name: "Safari",
        pid: 42,
        downloadBytesPerSecond: 2048,
        uploadBytesPerSecond: 1024
    )

    monitor.recordDisplaySampleForTesting([entry], at: now.addingTimeInterval(-16))
    monitor.refreshFreshnessState(now: now)

    #expect(monitor.topEntries.isEmpty)
    #expect(monitor.samplingState == .stale)
    #expect(monitor.statusText == "正在重新获取进程流量...")
    #expect(monitor.freshnessText == "正在更新")
}

@Test
@MainActor
func processTrafficMonitorPreservesRecentSamplesWhenPausedWithoutClearing() async throws {
    let monitor = ProcessTrafficMonitor()
    let now = Date()
    let entry = ProcessTrafficEntry(
        name: "Safari",
        pid: 42,
        downloadBytesPerSecond: 2048,
        uploadBytesPerSecond: 1024
    )

    monitor.recordDisplaySampleForTesting([entry], at: now.addingTimeInterval(-4))
    monitor.stop(clearEntries: false)
    monitor.refreshFreshnessState(now: now)

    #expect(monitor.topEntries == [entry])
    #expect(monitor.samplingState == .stale)
    #expect(monitor.freshnessText == "更新于 4 秒前")
}

@Test
func processTrafficFreshnessHelpersDescribeRecentSamples() async throws {
    let now = Date()

    #expect(ProcessTrafficMonitor.isFresh(lastUpdatedAt: now.addingTimeInterval(-3), now: now))
    #expect(!ProcessTrafficMonitor.isFresh(lastUpdatedAt: now.addingTimeInterval(-3.1), now: now))
    #expect(ProcessTrafficMonitor.canRetainStaleDisplay(lastUpdatedAt: now.addingTimeInterval(-15), now: now))
    #expect(!ProcessTrafficMonitor.canRetainStaleDisplay(lastUpdatedAt: now.addingTimeInterval(-15.1), now: now))
    #expect(ProcessTrafficMonitor.freshnessText(lastUpdatedAt: now.addingTimeInterval(-0.5), now: now) == "实时更新")
    #expect(ProcessTrafficMonitor.freshnessText(lastUpdatedAt: now.addingTimeInterval(-2), now: now) == "更新于 2 秒前")
}

@Test
func settingsPanelLayoutShrinksToVisibleFrameWhenPreferredHeightDoesNotFit() async throws {
    let visibleFrame = NSRect(x: 0, y: 80, width: 1440, height: 720)
    let statusItemFrame = NSRect(x: 980, y: 812, width: 120, height: 22)
    let frame = SettingsPanelLayout.panelFrame(
        relativeTo: statusItemFrame,
        visibleFrame: visibleFrame
    )

    #expect(frame.height == visibleFrame.height - (SettingsPanelLayout.edgePadding * 2))
    #expect(frame.minY >= visibleFrame.minY + SettingsPanelLayout.edgePadding)
    #expect(frame.maxY <= visibleFrame.maxY - SettingsPanelLayout.edgePadding)
}

@Test
func settingsPanelLayoutKeepsPreferredHeightWhenVisibleFrameHasRoom() async throws {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 1000)
    let statusItemFrame = NSRect(x: 980, y: 1010, width: 120, height: 22)
    let frame = SettingsPanelLayout.panelFrame(
        relativeTo: statusItemFrame,
        visibleFrame: visibleFrame
    )

    #expect(frame.height == SettingsPanelLayout.preferredSize.height)
    #expect(frame.maxY <= visibleFrame.maxY - SettingsPanelLayout.edgePadding)
}
