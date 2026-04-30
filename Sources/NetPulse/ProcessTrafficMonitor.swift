import AppKit
import Darwin
import Foundation

struct ProcessTrafficEntry: Identifiable, Equatable {
    let name: String
    let pid: Int?
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let detailText: String?
    let identity: String?

    init(
        name: String,
        pid: Int?,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        detailText: String? = nil,
        identity: String? = nil
    ) {
        self.name = name
        self.pid = pid
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.detailText = detailText
        self.identity = identity
    }

    var id: String {
        if let identity {
            return identity
        }

        if let pid {
            return "\(name)-\(pid)"
        }

        return name
    }

    var totalBytesPerSecond: Double {
        downloadBytesPerSecond + uploadBytesPerSecond
    }

    var displayName: String {
        name.isEmpty ? "未知进程" : name
    }

    var pidLabel: String? {
        if let detailText, !detailText.isEmpty {
            return detailText
        }

        return pid.map { "PID \($0)" }
    }
}

struct ProcessTrafficApplicationIdentity: Equatable {
    let key: String
    let displayName: String
}

private struct ProcessTrafficAggregate {
    let key: String
    let displayName: String
    let firstSourceName: String
    let firstPID: Int?
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    private var sourceNames: [String]
    private var processIDs: Set<Int>
    private var entryCount: Int

    init(
        key: String,
        displayName: String,
        firstSourceName: String,
        firstPID: Int?,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double
    ) {
        self.key = key
        self.displayName = displayName
        self.firstSourceName = firstSourceName
        self.firstPID = firstPID
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        sourceNames = [firstSourceName]
        processIDs = Set(firstPID.map { [$0] } ?? [])
        entryCount = 1
    }

    mutating func add(_ entry: ProcessTrafficEntry) {
        downloadBytesPerSecond += entry.downloadBytesPerSecond
        uploadBytesPerSecond += entry.uploadBytesPerSecond
        entryCount += 1

        let sourceName = entry.displayName
        if !sourceNames.contains(sourceName) {
            sourceNames.append(sourceName)
        }

        if let pid = entry.pid {
            processIDs.insert(pid)
        }
    }

    var entry: ProcessTrafficEntry {
        let processCount = processIDs.isEmpty ? entryCount : processIDs.count
        let detailText = detailText(processCount: processCount)
        let representativePID = processCount == 1 ? (processIDs.first ?? firstPID) : nil

        return ProcessTrafficEntry(
            name: displayName,
            pid: representativePID,
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            detailText: detailText,
            identity: key
        )
    }

    private func detailText(processCount: Int) -> String? {
        guard processCount > 1 else {
            guard firstSourceName != displayName else { return nil }
            if let firstPID {
                return "\(firstSourceName) · PID \(firstPID)"
            }
            return firstSourceName
        }

        guard firstSourceName != displayName else {
            return "\(processCount) 个进程"
        }

        return "\(processCount) 个进程 · \(firstSourceName) 等"
    }
}

enum ProcessTrafficSamplingState: Equatable {
    case idle
    case warming
    case live
    case stale
    case failed
}

@MainActor
final class ProcessTrafficMonitor: ObservableObject {
    @Published private(set) var topEntries: [ProcessTrafficEntry] = []
    @Published private(set) var statusText = "进程流量监控未启动"
    @Published private(set) var freshnessText = "已暂停"
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var samplingState: ProcessTrafficSamplingState = .idle

    private let samplingInterval: Double = 1.0
    private let freshnessWindow: TimeInterval = 3.0
    private let staleDisplayWindow: TimeInterval = 15.0
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var freshnessTimer: Timer?
    private var restartWorkItem: DispatchWorkItem?
    private var activeSessionID = UUID()
    private var outputBuffer = ""
    private var currentSampleEntries: [ProcessTrafficEntry] = []
    private var hasOpenSample = false
    private var didSkipBaselineSample = false
    private var errorBuffer = ""
    private var wantsWarmSampling = false
    private var consecutiveFailures = 0
    private var currentSampleBucket: String?
    private var applicationIdentityCache: [Int: ProcessTrafficApplicationIdentity] = [:]
    private var unresolvedApplicationIdentityPIDs = Set<Int>()

    func start() {
        startWarmSampling()
    }

    func startWarmSampling() {
        wantsWarmSampling = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        startFreshnessTimer()
        refreshFreshnessState()

        guard process == nil else { return }

        let now = Date()
        if !Self.isFresh(lastUpdatedAt: lastUpdatedAt, now: now, window: freshnessWindow),
           !Self.canRetainStaleDisplay(lastUpdatedAt: lastUpdatedAt, now: now, window: staleDisplayWindow) {
            clearSamplesForUnavailable(
                statusText: "正在预热高流量进程...",
                freshnessText: "正在预热",
                samplingState: .warming
            )
        }

        outputBuffer = ""
        currentSampleEntries.removeAll()
        hasOpenSample = false
        didSkipBaselineSample = false
        errorBuffer = ""
        let sessionID = UUID()
        activeSessionID = sessionID

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-P",
            "-n",
            "-x",
            "-d",
            "-s", String(Int(samplingInterval)),
            "-L", "0",
            "-J", "time,bytes_in,bytes_out",
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeSessionID == sessionID else { return }

                guard !data.isEmpty else {
                    self.finishOpenSample()
                    return
                }

                self.consume(data: data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeSessionID == sessionID else { return }
                self.consumeError(data: data)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeSessionID == sessionID else { return }
                self.finishOpenSample()
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.errorPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.outputPipe = nil
                self.errorPipe = nil

                guard self.wantsWarmSampling else { return }

                let didFail = terminatedProcess.terminationReason != .exit || terminatedProcess.terminationStatus != 0
                if didFail {
                    let reason = self.errorBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.handleSamplingFailure(reason: reason)
                } else {
                    self.samplingState = .stale
                    self.statusText = "进程流量监控已停止，正在重新启动..."
                    self.freshnessText = "正在重启"
                    self.scheduleRestart()
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            handleSamplingFailure(reason: "")
        }
    }

    func stop(clearEntries: Bool = true) {
        wantsWarmSampling = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        stopRunningProcess()

        if clearEntries {
            topEntries = []
            statusText = "进程流量监控未启动"
            freshnessText = "已暂停"
            lastUpdatedAt = nil
            samplingState = .idle
        } else {
            markSamplesStale(statusText: "进程流量监控已暂停", freshnessText: "已暂停")
        }
    }

    func pauseForSleep() {
        stop(clearEntries: false)
        statusText = "睡眠中，已暂停进程流量"
    }

    func resumeAfterWake() {
        startWarmSampling()
    }

    func refreshFreshnessState(now: Date = Date()) {
        if let lastUpdatedAt {
            if Self.isFresh(lastUpdatedAt: lastUpdatedAt, now: now, window: freshnessWindow) {
                samplingState = .live
                statusText = topEntries.isEmpty ? "当前没有明显的进程流量" : "实时统计系统进程流量"
                freshnessText = Self.freshnessText(lastUpdatedAt: lastUpdatedAt, now: now)
                return
            }

            if Self.canRetainStaleDisplay(lastUpdatedAt: lastUpdatedAt, now: now, window: staleDisplayWindow) {
                if topEntries.isEmpty {
                    markSamplesStale(statusText: "正在重新获取进程流量...", freshnessText: "正在更新")
                } else {
                    markSamplesStale(
                        statusText: "正在获取新的进程流量",
                        freshnessText: Self.freshnessText(lastUpdatedAt: lastUpdatedAt, now: now)
                    )
                }
                return
            }

            clearSamplesForUnavailable(statusText: "正在重新获取进程流量...", freshnessText: "正在更新")
            return
        }

        if samplingState == .failed {
            return
        }

        if process == nil && !wantsWarmSampling {
            samplingState = .idle
            statusText = "进程流量监控未启动"
            freshnessText = "已暂停"
        } else {
            samplingState = .warming
            statusText = "正在预热高流量进程..."
            freshnessText = "正在预热"
        }
    }

    func recordDisplaySampleForTesting(_ entries: [ProcessTrafficEntry], at date: Date) {
        recordDisplaySample(entries, at: date)
    }

    nonisolated static func isFresh(lastUpdatedAt: Date?, now: Date, window: TimeInterval = 3.0) -> Bool {
        guard let lastUpdatedAt else { return false }
        return now.timeIntervalSince(lastUpdatedAt) <= window
    }

    nonisolated static func canRetainStaleDisplay(lastUpdatedAt: Date?, now: Date, window: TimeInterval = 15.0) -> Bool {
        guard let lastUpdatedAt else { return false }
        return now.timeIntervalSince(lastUpdatedAt) <= window
    }

    nonisolated static func freshnessText(lastUpdatedAt: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(lastUpdatedAt))
        guard age >= 1 else { return "实时更新" }
        return "更新于 \(Int(age)) 秒前"
    }

    private func stopRunningProcess() {
        activeSessionID = UUID()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }

        self.process = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer = ""
        currentSampleEntries.removeAll()
        hasOpenSample = false
        didSkipBaselineSample = false
        currentSampleBucket = nil
        errorBuffer = ""
    }

    nonisolated static func parseProcessLabel(_ rawValue: String) -> (name: String, pid: Int?) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorIndex = trimmed.lastIndex(of: ".") else {
            return (trimmed, nil)
        }

        let pidPart = trimmed[trimmed.index(after: separatorIndex)...]
        guard let pid = Int(pidPart) else {
            return (trimmed, nil)
        }

        let name = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? trimmed : name, pid)
    }

    nonisolated static func parseCSVRow(_ line: String) -> (sampleTime: String, entry: ProcessTrafficEntry)? {
        guard !line.isEmpty, !isCSVHeader(line) else { return nil }

        let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard columns.count > 3 else { return nil }

        let sampleTime = columns[0]
        let processLabel = columns[1]
        let bytesIn: Double
        let bytesOut: Double

        if columns.count > 5 {
            bytesIn = Double(columns[4]) ?? 0
            bytesOut = Double(columns[5]) ?? 0
        } else {
            bytesIn = Double(columns[2]) ?? 0
            bytesOut = Double(columns[3]) ?? 0
        }

        let parsedLabel = parseProcessLabel(processLabel)
        let normalizedName = parsedLabel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }

        return (
            sampleTime,
            ProcessTrafficEntry(
                name: normalizedName,
                pid: parsedLabel.pid,
                downloadBytesPerSecond: bytesIn,
                uploadBytesPerSecond: bytesOut
            )
        )
    }

    nonisolated static func isCSVHeader(_ line: String) -> Bool {
        line.hasPrefix("time,")
    }

    nonisolated static func sampleBucket(for sampleTime: String) -> String {
        guard let separatorIndex = sampleTime.firstIndex(of: ".") else {
            return sampleTime
        }

        return String(sampleTime[..<separatorIndex])
    }

    nonisolated static func topEntries(
        from entries: [ProcessTrafficEntry],
        applicationIdentityFor: (ProcessTrafficEntry) -> ProcessTrafficApplicationIdentity? = { _ in nil }
    ) -> [ProcessTrafficEntry] {
        var aggregates: [String: ProcessTrafficAggregate] = [:]

        for entry in entries {
            guard entry.totalBytesPerSecond > 0 else { continue }
            guard !shouldIgnoreProcessName(entry.name) else { continue }

            let applicationIdentity = applicationIdentityFor(entry)
            if let applicationIdentity, shouldIgnoreProcessName(applicationIdentity.displayName) {
                continue
            }

            let key = applicationIdentity?.key ?? fallbackAggregationKey(for: entry)
            let displayName = applicationIdentity?.displayName ?? entry.displayName

            if var aggregate = aggregates[key] {
                aggregate.add(entry)
                aggregates[key] = aggregate
            } else {
                aggregates[key] = ProcessTrafficAggregate(
                    key: key,
                    displayName: displayName,
                    firstSourceName: entry.displayName,
                    firstPID: entry.pid,
                    downloadBytesPerSecond: entry.downloadBytesPerSecond,
                    uploadBytesPerSecond: entry.uploadBytesPerSecond
                )
            }
        }

        return aggregates.values
            .map(\.entry)
            .sorted { lhs, rhs in
                if lhs.totalBytesPerSecond == rhs.totalBytesPerSecond {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }

                return lhs.totalBytesPerSecond > rhs.totalBytesPerSecond
            }
            .prefix(3)
            .map { $0 }
    }

    nonisolated static func parseDisplaySamples(from csv: String, skipsBaselineSample: Bool = true) -> [[ProcessTrafficEntry]] {
        var currentSampleEntries: [ProcessTrafficEntry] = []
        var samples: [[ProcessTrafficEntry]] = []
        var didSkipBaselineSample = false

        func finishSample() {
            guard !currentSampleEntries.isEmpty else { return }
            let entries = topEntries(from: currentSampleEntries)
            currentSampleEntries.removeAll()

            if skipsBaselineSample && !didSkipBaselineSample {
                didSkipBaselineSample = true
                return
            }

            samples.append(entries)
        }

        var currentSampleBucket: String?

        for rawLine in csv.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if isCSVHeader(line) {
                finishSample()
                currentSampleBucket = nil
                continue
            }

            guard let row = parseCSVRow(line) else { continue }
            let sampleBucket = sampleBucket(for: row.sampleTime)
            if let currentSampleBucket, currentSampleBucket != sampleBucket {
                finishSample()
            }

            currentSampleBucket = sampleBucket
            currentSampleEntries.append(row.entry)
        }

        finishSample()
        return samples
    }

    private func consume(data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        outputBuffer += text

        while let newlineIndex = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newlineIndex]).trimmingCharacters(in: .newlines)
            outputBuffer.removeSubrange(...newlineIndex)
            parse(line: line)
        }
    }

    private func consumeError(data: Data) {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        errorBuffer += text
        if errorBuffer.count > 160 {
            errorBuffer = String(errorBuffer.suffix(160))
        }
    }

    private func parse(line: String) {
        if Self.isCSVHeader(line) {
            if hasOpenSample {
                finishCurrentSample()
            } else {
                hasOpenSample = true
            }
            currentSampleBucket = nil
            return
        }

        guard let row = Self.parseCSVRow(line) else { return }
        let sampleBucket = Self.sampleBucket(for: row.sampleTime)
        if let currentSampleBucket, currentSampleBucket != sampleBucket {
            finishCurrentSample()
        }

        currentSampleBucket = sampleBucket
        hasOpenSample = true
        currentSampleEntries.append(row.entry)
    }

    private func finishOpenSample() {
        guard hasOpenSample else { return }
        finishCurrentSample()
        hasOpenSample = false
    }

    private func finishCurrentSample() {
        let filteredEntries = Self.topEntries(from: currentSampleEntries) { [self] entry in
            applicationIdentity(for: entry)
        }
        currentSampleEntries.removeAll()

        if !didSkipBaselineSample {
            didSkipBaselineSample = true
            return
        }

        recordDisplaySample(filteredEntries, at: Date())
    }

    private func recordDisplaySample(_ entries: [ProcessTrafficEntry], at date: Date) {
        consecutiveFailures = 0
        topEntries = entries
        lastUpdatedAt = date
        samplingState = .live
        statusText = topEntries.isEmpty ? "当前没有明显的进程流量" : "实时统计系统进程流量"
        freshnessText = "实时更新"
    }

    private func startFreshnessTimer() {
        guard freshnessTimer == nil else { return }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFreshnessState()
            }
        }
    }

    private func markSamplesStale(statusText: String, freshnessText: String) {
        samplingState = .stale
        self.statusText = statusText
        self.freshnessText = freshnessText
    }

    private func clearSamplesForUnavailable(
        statusText: String,
        freshnessText: String,
        samplingState: ProcessTrafficSamplingState = .stale
    ) {
        topEntries = []
        lastUpdatedAt = nil
        self.samplingState = samplingState
        self.statusText = statusText
        self.freshnessText = freshnessText
    }

    private func handleSamplingFailure(reason: String) {
        consecutiveFailures += 1
        topEntries = []
        lastUpdatedAt = nil
        samplingState = .failed
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        statusText = trimmedReason.isEmpty ? "无法读取进程流量" : "无法读取进程流量：\(trimmedReason)"
        freshnessText = "暂不可用"
        scheduleRestart()
    }

    private func applicationIdentity(for entry: ProcessTrafficEntry) -> ProcessTrafficApplicationIdentity? {
        guard let pid = entry.pid else { return nil }

        if let cachedIdentity = applicationIdentityCache[pid] {
            return cachedIdentity
        }

        if unresolvedApplicationIdentityPIDs.contains(pid) {
            return nil
        }

        if applicationIdentityCache.count + unresolvedApplicationIdentityPIDs.count > 512 {
            applicationIdentityCache.removeAll()
            unresolvedApplicationIdentityPIDs.removeAll()
        }

        guard let identity = Self.resolveApplicationIdentity(pid: pid, processName: entry.name) else {
            unresolvedApplicationIdentityPIDs.insert(pid)
            return nil
        }

        applicationIdentityCache[pid] = identity
        return identity
    }

    nonisolated static func resolveApplicationIdentity(pid: Int, processName: String) -> ProcessTrafficApplicationIdentity? {
        if let executablePath = executablePath(for: pid),
           let appBundleURL = outermostAppBundleURL(containing: executablePath),
           let identity = applicationIdentity(fromBundleAt: appBundleURL) {
            return identity
        }

        let processIdentifier = pid_t(pid)
        guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }

        let displayName = normalizedDisplayName(
            runningApplication.localizedName
                ?? runningApplication.bundleURL.flatMap { applicationDisplayName(fromBundleAt: $0) }
                ?? processName
        )
        guard let displayName else { return nil }

        let key: String
        if let bundleIdentifier = runningApplication.bundleIdentifier, !bundleIdentifier.isEmpty {
            key = "bundle:\(bundleIdentifier)"
        } else if let bundleURL = runningApplication.bundleURL {
            key = "app:\(bundleURL.standardizedFileURL.path)"
        } else {
            key = "process:\(displayName)"
        }

        return ProcessTrafficApplicationIdentity(key: key, displayName: displayName)
    }

    nonisolated private static func shouldIgnoreProcessName(_ name: String) -> Bool {
        name == "nettop" || name == "NetPulse"
    }

    nonisolated private static func fallbackAggregationKey(for entry: ProcessTrafficEntry) -> String {
        if let pid = entry.pid {
            return "process:\(entry.name)-\(pid)"
        }

        return "process:\(entry.name)"
    }

    nonisolated private static func executablePath(for pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int32 in
            guard let baseAddress = bufferPointer.baseAddress else { return 0 }
            return proc_pidpath(pid_t(pid), UnsafeMutableRawPointer(baseAddress), UInt32(bufferPointer.count))
        }

        guard result > 0 else { return nil }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    nonisolated private static func outermostAppBundleURL(containing executablePath: String) -> URL? {
        var currentPath = (executablePath as NSString).deletingLastPathComponent
        var appPath: String?

        while !currentPath.isEmpty && currentPath != "/" {
            if (currentPath as NSString).pathExtension == "app" {
                appPath = currentPath
            }

            let parentPath = (currentPath as NSString).deletingLastPathComponent
            if parentPath == currentPath {
                break
            }
            currentPath = parentPath
        }

        guard let appPath else { return nil }
        return URL(fileURLWithPath: appPath)
    }

    nonisolated private static func applicationIdentity(fromBundleAt bundleURL: URL) -> ProcessTrafficApplicationIdentity? {
        guard let displayName = applicationDisplayName(fromBundleAt: bundleURL) else { return nil }
        let bundle = Bundle(url: bundleURL)
        let key: String

        if let bundleIdentifier = bundle?.bundleIdentifier, !bundleIdentifier.isEmpty {
            key = "bundle:\(bundleIdentifier)"
        } else {
            key = "app:\(bundleURL.standardizedFileURL.path)"
        }

        return ProcessTrafficApplicationIdentity(key: key, displayName: displayName)
    }

    nonisolated private static func applicationDisplayName(fromBundleAt bundleURL: URL) -> String? {
        let bundle = Bundle(url: bundleURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
        return normalizedDisplayName(displayName ?? bundleName ?? fallbackName)
    }

    nonisolated private static func normalizedDisplayName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scheduleRestart() {
        guard wantsWarmSampling else { return }

        restartWorkItem?.cancel()
        let delay = min(30.0, pow(2.0, Double(min(consecutiveFailures, 4))))
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.wantsWarmSampling else { return }
                self.samplingState = .warming
                self.statusText = "正在重新获取进程流量..."
                self.freshnessText = "正在重试"
                self.startWarmSampling()
            }
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
