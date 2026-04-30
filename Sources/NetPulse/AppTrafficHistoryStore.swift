import Foundation

struct AppTrafficHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var downloadBytes: UInt64
    var uploadBytes: UInt64
    var lastUpdatedAt: Date

    var totalBytes: UInt64 {
        AppTrafficHistoryStore.addingClamped(downloadBytes, uploadBytes)
    }
}

struct AppTrafficHistoryDay: Codable, Equatable, Identifiable {
    let id: String
    var entries: [AppTrafficHistoryEntry]

    var totalDownloadBytes: UInt64 {
        entries.reduce(0) { AppTrafficHistoryStore.addingClamped($0, $1.downloadBytes) }
    }

    var totalUploadBytes: UInt64 {
        entries.reduce(0) { AppTrafficHistoryStore.addingClamped($0, $1.uploadBytes) }
    }

    var totalBytes: UInt64 {
        AppTrafficHistoryStore.addingClamped(totalDownloadBytes, totalUploadBytes)
    }

    var sortedEntries: [AppTrafficHistoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.totalBytes == rhs.totalBytes {
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }

            return lhs.totalBytes > rhs.totalBytes
        }
    }
}

@MainActor
final class AppTrafficHistoryStore: ObservableObject {
    @Published private(set) var days: [AppTrafficHistoryDay] = []
    @Published var selectedDayID: String?

    private let fileURL: URL
    private let calendar: Calendar
    private let retentionDays: Int
    private let writeDelay: TimeInterval
    private var saveTimer: Timer?

    init(
        fileURL: URL? = nil,
        calendar: Calendar = .current,
        retentionDays: Int = 30,
        writeDelay: TimeInterval = 1.5
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.calendar = calendar
        self.retentionDays = max(1, retentionDays)
        self.writeDelay = writeDelay
        load()
    }

    var selectedDay: AppTrafficHistoryDay? {
        if let selectedDayID, let day = days.first(where: { $0.id == selectedDayID }) {
            return day
        }

        return days.first
    }

    func record(entries: [ProcessTrafficEntry], at date: Date = Date(), sampleInterval: TimeInterval) {
        guard sampleInterval > 0 else { return }

        let dayID = Self.dayID(for: date, calendar: calendar)
        var day = days.first(where: { $0.id == dayID }) ?? AppTrafficHistoryDay(id: dayID, entries: [])

        for entry in entries {
            let downloadBytes = Self.bytes(from: entry.downloadBytesPerSecond, sampleInterval: sampleInterval)
            let uploadBytes = Self.bytes(from: entry.uploadBytesPerSecond, sampleInterval: sampleInterval)
            guard downloadBytes > 0 || uploadBytes > 0 else { continue }

            let entryID = entry.identity ?? entry.id
            if let index = day.entries.firstIndex(where: { $0.id == entryID }) {
                day.entries[index].displayName = entry.displayName
                day.entries[index].downloadBytes = Self.addingClamped(day.entries[index].downloadBytes, downloadBytes)
                day.entries[index].uploadBytes = Self.addingClamped(day.entries[index].uploadBytes, uploadBytes)
                day.entries[index].lastUpdatedAt = date
            } else {
                day.entries.append(
                    AppTrafficHistoryEntry(
                        id: entryID,
                        displayName: entry.displayName,
                        downloadBytes: downloadBytes,
                        uploadBytes: uploadBytes,
                        lastUpdatedAt: date
                    )
                )
            }
        }

        guard !day.entries.isEmpty else { return }

        days.removeAll { $0.id == dayID }
        day.entries = day.sortedEntries
        days.append(day)
        days.sort { $0.id > $1.id }

        if selectedDayID == nil || !days.contains(where: { $0.id == selectedDayID }) {
            selectedDayID = dayID
        }

        pruneHistory(now: date)
        scheduleSave()
    }

    func pruneHistory(now: Date = Date()) {
        let startOfToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: startOfToday) ?? startOfToday
        let originalCount = days.count

        days = days.filter { day in
            guard let date = Self.date(fromDayID: day.id, calendar: calendar) else { return false }
            return date >= cutoff
        }
        days.sort { $0.id > $1.id }

        if let selectedDayID, !days.contains(where: { $0.id == selectedDayID }) {
            self.selectedDayID = days.first?.id
        } else if selectedDayID == nil {
            selectedDayID = days.first?.id
        }

        if days.count != originalCount {
            scheduleSave()
        }
    }

    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        writeToDisk()
    }

    nonisolated static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    nonisolated static func dayID(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    nonisolated static func date(fromDayID dayID: String, calendar: Calendar = .current) -> Date? {
        let parts = dayID.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(calendar: calendar, year: parts[0], month: parts[1], day: parts[2]).date
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            days = []
            selectedDayID = nil
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(HistoryFile.self, from: data)
            days = file.days.map { day in
                AppTrafficHistoryDay(id: day.id, entries: day.sortedEntries)
            }
            days.sort { $0.id > $1.id }
            selectedDayID = days.first?.id
            pruneHistory()
        } catch {
            days = []
            selectedDayID = nil
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: writeDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.writeToDisk()
            }
        }
    }

    private func writeToDisk() {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(HistoryFile(days: days))
            try data.write(to: fileURL, options: .atomic)
        } catch {
        }
    }

    private static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("NetPulse", isDirectory: true)
            .appendingPathComponent("app-traffic-history.json")
    }

    private static func bytes(from bytesPerSecond: Double, sampleInterval: TimeInterval) -> UInt64 {
        guard bytesPerSecond.isFinite, sampleInterval.isFinite else { return 0 }
        let value = max(0, bytesPerSecond) * max(0, sampleInterval)
        guard value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value.rounded())
    }
}

private struct HistoryFile: Codable {
    var days: [AppTrafficHistoryDay]
}
