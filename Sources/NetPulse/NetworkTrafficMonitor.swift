import Foundation
import Network

@MainActor
final class NetworkTrafficMonitor: ObservableObject {
    @Published private(set) var downloadBytesPerSecond: Double = 0
    @Published private(set) var uploadBytesPerSecond: Double = 0
    @Published private(set) var connectionLabel = "检查中"
    @Published private(set) var interfaceSummary = "--"
    @Published private(set) var menuBarTitle = "离线"
    @Published private(set) var history: [TrafficPoint] = []
    @Published private(set) var availableInterfaces: [InterfaceOption] = []
    @Published private(set) var sampledInterfaces: [InterfaceOption] = []
    @Published var menuBarDisplayMode: MenuBarDisplayMode = .both {
        didSet {
            refreshMenuBarTitle()
        }
    }
    @Published var samplingInterval: TimeInterval = 0.5 {
        didSet {
            guard oldValue != samplingInterval else { return }
            restartTimer(resetHistory: true)
        }
    }
    @Published var selectedInterfaceName: String? {
        didSet {
            guard oldValue != selectedInterfaceName else { return }
            previousSnapshot = nil
            history.removeAll()
            sampleTraffic()
        }
    }

    private let pathQueue = DispatchQueue(label: "com.netpulse.path", qos: .utility)
    private let pathMonitor = NWPathMonitor()

    private var timer: Timer?
    private var previousSnapshot: InterfaceSnapshot?
    private var isNetworkAvailable = false
    private var isSleeping = false
    private var recentDownloadSamples: [Double] = []
    private var recentUploadSamples: [Double] = []

    func start() {
        guard timer == nil else { return }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.apply(path: path)
            }
        }
        pathMonitor.start(queue: pathQueue)

        sampleTraffic()
        scheduleTimer()
    }

    func restoreCachedDisplayState(menuBarTitle: String, connectionLabel: String, interfaceSummary: String) {
        self.menuBarTitle = menuBarTitle
        self.connectionLabel = connectionLabel
        self.interfaceSummary = interfaceSummary
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
    }

    func refreshNow(resetHistory: Bool = false) {
        if resetHistory {
            previousSnapshot = nil
            history.removeAll()
        }

        sampleTraffic()
    }

    func handleSystemWillSleep() {
        isSleeping = true
        previousSnapshot = nil
        resetSmoothing()
        downloadBytesPerSecond = 0
        uploadBytesPerSecond = 0
        connectionLabel = "睡眠中"
        interfaceSummary = "已暂停采样"
        refreshMenuBarTitle()
    }

    func handleSystemDidWake() {
        isSleeping = false
        previousSnapshot = nil
        resetSmoothing()
        connectionLabel = "唤醒中"
        interfaceSummary = selectedInterfaceName == nil ? "正在重新检查网卡" : "\(selectedInterfaceName ?? "") · 重新连接中"
        refreshMenuBarTitle()

        apply(path: pathMonitor.currentPath)
        sampleTraffic()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshNow(resetHistory: true)
        }
    }

    private func sampleTraffic() {
        guard !isSleeping else { return }

        let snapshot = InterfaceSnapshotReader.read(selectedInterfaceName: selectedInterfaceName)
        if let selectedInterfaceName, !snapshot.availableInterfaces.contains(where: { $0.id == selectedInterfaceName }) {
            self.selectedInterfaceName = nil
            return
        }

        let now = Date()

        let rawDownloadSpeed: Double
        let rawUploadSpeed: Double

        if let previousSnapshot, snapshot.rxBytes >= previousSnapshot.rxBytes, snapshot.txBytes >= previousSnapshot.txBytes {
            rawDownloadSpeed = Double(snapshot.rxBytes - previousSnapshot.rxBytes) / samplingInterval
            rawUploadSpeed = Double(snapshot.txBytes - previousSnapshot.txBytes) / samplingInterval
        } else {
            rawDownloadSpeed = 0
            rawUploadSpeed = 0
        }

        previousSnapshot = snapshot
        let smoothedDownloadSpeed = smoothedSpeed(for: rawDownloadSpeed, buffer: &recentDownloadSamples)
        let smoothedUploadSpeed = smoothedSpeed(for: rawUploadSpeed, buffer: &recentUploadSamples)

        self.downloadBytesPerSecond = smoothedDownloadSpeed
        self.uploadBytesPerSecond = smoothedUploadSpeed
        self.availableInterfaces = snapshot.availableInterfaces
        self.sampledInterfaces = snapshot.sampledInterfaces
        self.interfaceSummary = makeInterfaceSummary(from: snapshot)
        refreshMenuBarTitle()

        history.append(
            TrafficPoint(
                timestamp: now,
                downloadBytesPerSecond: smoothedDownloadSpeed,
                uploadBytesPerSecond: smoothedUploadSpeed
            )
        )

        let historyLimit = maxHistoryPoints
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private func refreshMenuBarTitle() {
        if isSleeping {
            menuBarTitle = "睡眠"
            return
        }

        if !isNetworkAvailable {
            menuBarTitle = "离线"
            return
        }

        switch menuBarDisplayMode {
        case .both:
            menuBarTitle = "↓\(SpeedFormatter.menuBar(downloadBytesPerSecond)) ↑\(SpeedFormatter.menuBar(uploadBytesPerSecond))"
        case .downloadOnly:
            menuBarTitle = SpeedFormatter.menuBar(downloadBytesPerSecond)
        case .uploadOnly:
            menuBarTitle = SpeedFormatter.menuBar(uploadBytesPerSecond)
        }
    }

    private func makeInterfaceSummary(from snapshot: InterfaceSnapshot) -> String {
        if isSleeping {
            return "已暂停采样"
        }

        if !isNetworkAvailable {
            return selectedInterfaceName == nil ? "没有可用网络路径" : "\(selectedInterfaceName ?? "") · 已离线"
        }

        if let selectedInterfaceName {
            let selectedOption = snapshot.availableInterfaces.first(where: { $0.id == selectedInterfaceName })
            let name = selectedOption?.summaryName ?? selectedInterfaceName
            let suffix = snapshot.sampledInterfaces.isEmpty ? "未激活" : "已锁定"
            return "\(name) · \(suffix)"
        }

        if snapshot.sampledInterfaces.isEmpty {
            return "自动 · 空闲"
        }

        return "自动 · \(compactInterfaceSummary(from: snapshot.sampledInterfaces))"
    }

    private func apply(path: NWPath) {
        isNetworkAvailable = path.status == .satisfied

        if !isSleeping {
            connectionLabel = Self.describe(path: path)
        }

        interfaceSummary = makeInterfaceSummary(
            from: InterfaceSnapshot(
                rxBytes: previousSnapshot?.rxBytes ?? 0,
                txBytes: previousSnapshot?.txBytes ?? 0,
                sampledInterfaces: availableInterfaces,
                availableInterfaces: availableInterfaces
            )
        )
        refreshMenuBarTitle()
    }

    private func scheduleTimer() {
        timer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: samplingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleTraffic()
            }
        }
        timer.tolerance = min(0.1, samplingInterval * 0.2)
        self.timer = timer
    }

    private func restartTimer(resetHistory: Bool) {
        guard timer != nil else { return }

        if resetHistory {
            previousSnapshot = nil
            history.removeAll()
            resetSmoothing()
        }

        scheduleTimer()
        sampleTraffic()
    }

    private func resetSmoothing() {
        recentDownloadSamples.removeAll()
        recentUploadSamples.removeAll()
    }

    private func smoothedSpeed(for sample: Double, buffer: inout [Double]) -> Double {
        buffer.append(sample)
        if buffer.count > 3 {
            buffer.removeFirst(buffer.count - 3)
        }

        guard !buffer.isEmpty else { return sample }
        return buffer.reduce(0, +) / Double(buffer.count)
    }

    private var maxHistoryPoints: Int {
        max(30, Int(60 / samplingInterval))
    }

    private func compactInterfaceSummary(from interfaces: [InterfaceOption]) -> String {
        let names = interfaces.map(\.summaryName)
        switch names.count {
        case 0:
            return "空闲"
        case 1:
            return names[0]
        case 2:
            return names.joined(separator: "、")
        default:
            return "\(names[0])、\(names[1]) 等 \(names.count) 个"
        }
    }

    nonisolated private static func describe(path: NWPath) -> String {
        guard path.status == .satisfied else {
            return "已离线"
        }

        if path.usesInterfaceType(.wifi) {
            return "Wi-Fi"
        }

        if path.usesInterfaceType(.wiredEthernet) {
            return "有线网络"
        }

        if path.usesInterfaceType(.loopback) {
            return "回环"
        }

        if path.usesInterfaceType(.other) {
            return "其他网络"
        }

        return "在线"
    }
}

extension NetworkTrafficMonitor: @unchecked Sendable {}

struct TrafficPoint: Identifiable {
    let id: UUID
    let timestamp: Date
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double

    init(id: UUID = UUID(), timestamp: Date, downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.id = id
        self.timestamp = timestamp
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}
