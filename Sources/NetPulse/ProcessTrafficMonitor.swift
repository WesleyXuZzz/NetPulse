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

@MainActor
final class ProcessTrafficMonitor: ObservableObject {
    @Published private(set) var topEntries: [ProcessTrafficEntry] = []
    @Published private(set) var statusText = "打开面板后开始分析进程流量"
    @Published private(set) var lastUpdatedAt: Date?

    private let samplingInterval: Double = 1.0
    private var process: Process?
    private var outputPipe: Pipe?
    private var activeSessionID = UUID()
    private var outputBuffer = ""
    private var currentSampleTime: String?
    private var currentSampleEntries: [ProcessTrafficEntry] = []

    func start() {
        guard process == nil else { return }

        topEntries = []
        statusText = "正在分析高流量进程..."
        lastUpdatedAt = nil
        outputBuffer = ""
        currentSampleTime = nil
        currentSampleEntries.removeAll()
        let sessionID = UUID()
        activeSessionID = sessionID

        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-x", "-d", "-s", String(Int(samplingInterval)), "-L", "0"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeSessionID == sessionID else { return }

                guard !data.isEmpty else {
                    self.finishCurrentSample()
                    return
                }

                self.consume(data: data)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeSessionID == sessionID else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.outputPipe = nil

                if terminatedProcess.terminationReason != .exit || terminatedProcess.terminationStatus != 0 {
                    if self.topEntries.isEmpty {
                        self.statusText = "无法读取进程流量"
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            statusText = "无法启动进程监控"
        }
    }

    func stop() {
        activeSessionID = UUID()
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }

        self.process = nil
        outputPipe = nil
        outputBuffer = ""
        currentSampleTime = nil
        currentSampleEntries.removeAll()
        topEntries = []
        statusText = "打开面板后开始分析进程流量"
        lastUpdatedAt = nil
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
        guard !line.isEmpty, !line.hasPrefix("time,") else { return nil }

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

    private func consume(data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        outputBuffer += text

        while let newlineIndex = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newlineIndex]).trimmingCharacters(in: .newlines)
            outputBuffer.removeSubrange(...newlineIndex)
            parse(line: line)
        }
    }

    private func parse(line: String) {
        guard let row = Self.parseCSVRow(line) else { return }

        if let currentSampleTime, row.sampleTime != currentSampleTime {
            finishCurrentSample()
            currentSampleEntries.removeAll()
        }

        currentSampleTime = row.sampleTime
        currentSampleEntries.append(row.entry)
    }

    private func finishCurrentSample() {
        let filteredEntries = currentSampleEntries
            .filter { $0.totalBytesPerSecond > 0 }
            .filter { $0.name != "nettop" && $0.name != "NetPulse" }
            .sorted { lhs, rhs in
                if lhs.totalBytesPerSecond == rhs.totalBytesPerSecond {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }

                return lhs.totalBytesPerSecond > rhs.totalBytesPerSecond
            }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.topEntries = Array(filteredEntries.prefix(3))
            self.lastUpdatedAt = Date()
            self.statusText = self.topEntries.isEmpty ? "当前没有明显的进程流量" : "仅统计当前面板打开时的系统进程流量"
        }
    }
}
