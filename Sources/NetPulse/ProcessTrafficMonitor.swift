import Foundation

struct ProcessTrafficEntry: Identifiable, Equatable {
    let name: String
    let pid: Int?
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double

    var id: String {
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
        pid.map { "PID \($0)" }
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

        if !Self.isFresh(lastUpdatedAt: lastUpdatedAt, now: Date(), window: freshnessWindow) {
            topEntries = []
            samplingState = .warming
            statusText = "正在预热高流量进程..."
            freshnessText = "正在预热"
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
        process.arguments = ["-P", "-n", "-x", "-d", "-s", String(Int(samplingInterval)), "-L", "0"]
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

            markSamplesStale(statusText: "正在重新获取进程流量...", freshnessText: "正在更新")
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
        guard columns.count > 5 else { return nil }

        let sampleTime = columns[0]
        let processLabel = columns[1]
        let bytesIn = Double(columns[4]) ?? 0
        let bytesOut = Double(columns[5]) ?? 0

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

    nonisolated static func topEntries(from entries: [ProcessTrafficEntry]) -> [ProcessTrafficEntry] {
        entries
            .filter { $0.totalBytesPerSecond > 0 }
            .filter { $0.name != "nettop" && $0.name != "NetPulse" }
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

        for rawLine in csv.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if isCSVHeader(line) {
                finishSample()
                continue
            }

            guard let row = parseCSVRow(line) else { continue }
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
            return
        }

        guard let row = Self.parseCSVRow(line) else { return }
        hasOpenSample = true
        currentSampleEntries.append(row.entry)
    }

    private func finishOpenSample() {
        guard hasOpenSample else { return }
        finishCurrentSample()
        hasOpenSample = false
    }

    private func finishCurrentSample() {
        let filteredEntries = Self.topEntries(from: currentSampleEntries)
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
        topEntries = []
        lastUpdatedAt = nil
        samplingState = .stale
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
