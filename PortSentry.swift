import SwiftUI
import Foundation

// MARK: - Models

struct ListeningPort: Identifiable, Hashable {
    let id: String  // "pid:port" for uniqueness
    let port: UInt16
    let pid: Int32
    let processName: String
    let user: String
    let address: String  // e.g. "127.0.0.1" or "*"

    var category: PortCategory {
        PortCategory.categorize(port)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ListeningPort, rhs: ListeningPort) -> Bool { lhs.id == rhs.id }
}

enum PortCategory: String, CaseIterable {
    case webDev = "Web Dev"
    case backend = "Backend"
    case database = "Database"
    case system = "System"
    case other = "Other"

    var icon: String {
        switch self {
        case .webDev: return "globe"
        case .backend: return "server.rack"
        case .database: return "cylinder"
        case .system: return "gearshape"
        case .other: return "network"
        }
    }

    var color: Color {
        switch self {
        case .webDev: return .blue
        case .backend: return .orange
        case .database: return .green
        case .system: return .gray
        case .other: return .purple
        }
    }

    static func categorize(_ port: UInt16) -> PortCategory {
        switch port {
        case 80, 443, 3000...3999, 4200, 5173, 5174, 5500, 8080...8089: return .webDev
        case 4000...4999, 5000...5100, 8000...8079, 8090...8999, 9000...9999: return .backend
        case 3306, 5432, 5433, 6379, 6380, 27017, 27018, 9200, 9300, 11211, 2379: return .database
        case 0...1023: return .system
        default: return .other
        }
    }
}

enum KillResult {
    case success
    case failed(String)
    case alreadyDead
}

// MARK: - Port Scanner

@Observable
class PortScanner {
    var ports: [ListeningPort] = []
    var lastScanTime: Date?
    var isScanning = false
    var killConfirmation: ListeningPort?
    var killResult: (port: ListeningPort, result: KillResult)?
    var searchText = ""
    var selectedCategory: PortCategory?

    private var refreshTimer: Timer?

    init() {
        // Scan immediately so menu bar label has data
        let result = Self.scanListeningPorts()
        self.ports = result
        self.lastScanTime = Date()
    }

    var filteredPorts: [ListeningPort] {
        var result = ports
        if let cat = selectedCategory {
            result = result.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.processName.lowercased().contains(q) ||
                String($0.port).contains(q) ||
                String($0.pid).contains(q)
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    var categoryCounts: [(PortCategory, Int)] {
        let counts = Dictionary(grouping: ports, by: \.category).mapValues(\.count)
        return PortCategory.allCases.compactMap { cat in
            guard let count = counts[cat], count > 0 else { return nil }
            return (cat, count)
        }
    }

    func startRefreshing() {
        scan()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func scan() {
        isScanning = true
        let result = Self.scanListeningPorts()
        self.ports = result
        self.lastScanTime = Date()
        self.isScanning = false
    }

    func killProcess(_ port: ListeningPort) {
        let pid = port.pid

        // Try SIGTERM first (graceful)
        let termResult = kill(pid, SIGTERM)
        if termResult != 0 {
            let err = String(cString: strerror(errno))
            if errno == ESRCH {
                killResult = (port, .alreadyDead)
            } else {
                killResult = (port, .failed("SIGTERM failed: \(err)"))
            }
            scan()
            return
        }

        // Wait briefly for graceful shutdown
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            usleep(500_000) // 500ms grace period

            // Check if still running
            if kill(pid, 0) == 0 {
                // Still alive, SIGKILL
                let killRes = kill(pid, SIGKILL)
                DispatchQueue.main.async {
                    if killRes == 0 {
                        self?.killResult = (port, .success)
                    } else {
                        let err = String(cString: strerror(errno))
                        self?.killResult = (port, .failed("SIGKILL failed: \(err)"))
                    }
                    self?.scan()
                }
            } else {
                DispatchQueue.main.async {
                    self?.killResult = (port, .success)
                    self?.scan()
                }
            }
        }
    }

    // MARK: - lsof-based port scanning

    static func scanListeningPorts() -> [ListeningPort] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Read data before waitUntilExit to avoid pipe deadlock
        var outputData = Data()
        let readHandle = pipe.fileHandleForReading
        do {
            try process.run()
        } catch {
            return []
        }
        outputData = readHandle.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else { return [] }

        var results: [String: ListeningPort] = [:]

        for line in output.components(separatedBy: "\n").dropFirst() {
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let processName = parts[0]
            guard let pid = Int32(parts[1]) else { continue }
            let user = parts[2]

            // Parse the NAME column (second-to-last field): "127.0.0.1:3000" or "*:8080" or "[::1]:5432"
            // Last field is "(LISTEN)"
            guard parts.count >= 10 else { continue }
            let nameField = parts[parts.count - 2]
            guard let (address, port) = parseAddress(nameField) else { continue }

            let key = "\(pid):\(port)"
            if results[key] == nil {
                results[key] = ListeningPort(
                    id: key, port: port, pid: pid,
                    processName: processName, user: user, address: address
                )
            }
        }

        return Array(results.values)
    }

    private static func parseAddress(_ name: String) -> (String, UInt16)? {
        // Handle IPv6: [::1]:port or [::]:port
        if name.hasPrefix("[") {
            guard let closeBracket = name.firstIndex(of: "]") else { return nil }
            let addr = String(name[name.index(after: name.startIndex)...name.index(before: closeBracket)])
            let afterBracket = name[name.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(":"),
                  let port = UInt16(afterBracket.dropFirst()) else { return nil }
            return (addr, port)
        }

        // Handle IPv4: addr:port or *:port
        guard let lastColon = name.lastIndex(of: ":") else { return nil }
        let addr = String(name[..<lastColon])
        guard let port = UInt16(name[name.index(after: lastColon)...]) else { return nil }
        return (addr, port)
    }
}

// MARK: - Theme

enum SentryTheme {
    static let bg = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let cardBG = Color.white.opacity(0.04)
    static let cardHover = Color.white.opacity(0.08)
    static let text = Color(red: 0.82, green: 0.82, blue: 0.83)
    static let brightText = Color(red: 0.91, green: 0.91, blue: 0.91)
    static let muted = Color.white.opacity(0.4)
    static let border = Color.white.opacity(0.08)
    static let danger = Color(red: 0.88, green: 0.12, blue: 0.35)
    static let success = Color(red: 0.22, green: 0.59, blue: 0.55)

    static let popupWidth: CGFloat = 380
    static let popupHeight: CGFloat = 520
}

// MARK: - App

@main
struct PortSentryApp: App {
    @State private var scanner = PortScanner()

    var body: some Scene {
        MenuBarExtra(
            "\(scanner.ports.count)",
            systemImage: scanner.ports.isEmpty
                ? "antenna.radiowaves.left.and.right.slash"
                : "antenna.radiowaves.left.and.right"
        ) {
            PortSentryView(scanner: scanner)
                .frame(width: SentryTheme.popupWidth, height: SentryTheme.popupHeight)
                .background(SentryTheme.bg)
                .onAppear { scanner.scan() }
                .task { scanner.startRefreshing() }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Main View

struct PortSentryView: View {
    @Bindable var scanner: PortScanner

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(SentryTheme.border)
            categoryBar
            Divider().overlay(SentryTheme.border)
            searchBar
            Divider().overlay(SentryTheme.border)
            portList
            Divider().overlay(SentryTheme.border)
            footer
        }
        .alert("Kill Process?", isPresented: .init(
            get: { scanner.killConfirmation != nil },
            set: { if !$0 { scanner.killConfirmation = nil } }
        )) {
            if let port = scanner.killConfirmation {
                Button("Cancel", role: .cancel) { scanner.killConfirmation = nil }
                Button("Kill \(port.processName)", role: .destructive) {
                    scanner.killProcess(port)
                    scanner.killConfirmation = nil
                }
            }
        } message: {
            if let port = scanner.killConfirmation {
                Text("Terminate \(port.processName) (PID \(port.pid)) on port \(port.port)?\n\nSends SIGTERM first, then SIGKILL after 500ms if still running.")
            }
        }
        .overlay(alignment: .bottom) {
            if let (port, result) = scanner.killResult {
                killResultBanner(port: port, result: result)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { scanner.killResult = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14))
                .foregroundStyle(SentryTheme.success)
            Text("PortSentry")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SentryTheme.brightText)

            Spacer()

            if scanner.isScanning {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            }

            Text("\(scanner.ports.count) ports")
                .font(.system(size: 12))
                .foregroundStyle(SentryTheme.muted)

            Button {
                scanner.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(SentryTheme.muted)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Category filter bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryChip(nil, label: "All", count: scanner.ports.count)
                ForEach(scanner.categoryCounts, id: \.0) { cat, count in
                    categoryChip(cat, label: cat.rawValue, count: count)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func categoryChip(_ category: PortCategory?, label: String, count: Int) -> some View {
        let isSelected = scanner.selectedCategory == category
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                scanner.selectedCategory = category
            }
        } label: {
            HStack(spacing: 4) {
                if let cat = category {
                    Image(systemName: cat.icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? .white : SentryTheme.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? (category?.color ?? SentryTheme.success) : SentryTheme.cardBG,
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : SentryTheme.text)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(SentryTheme.muted)
            TextField("Filter by name, port, or PID...", text: $scanner.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(SentryTheme.brightText)
            if !scanner.searchText.isEmpty {
                Button {
                    scanner.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SentryTheme.muted)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: - Port list

    private var portList: some View {
        Group {
            if scanner.filteredPorts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(scanner.filteredPorts) { port in
                            portRow(port)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: scanner.searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(SentryTheme.muted)
            Text(scanner.searchText.isEmpty ? "No listening ports" : "No ports match filter")
                .font(.system(size: 14))
                .foregroundStyle(SentryTheme.muted)
            if scanner.searchText.isEmpty {
                Text("All clear!")
                    .font(.system(size: 12))
                    .foregroundStyle(SentryTheme.muted.opacity(0.6))
            }
            Spacer()
        }
    }

    private func portRow(_ port: ListeningPort) -> some View {
        HStack(spacing: 10) {
            // Category icon
            Image(systemName: port.category.icon)
                .font(.system(size: 12))
                .foregroundStyle(port.category.color)
                .frame(width: 20)

            // Port number
            Text("\(port.port)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(SentryTheme.brightText)
                .frame(width: 52, alignment: .leading)

            // Process info
            VStack(alignment: .leading, spacing: 1) {
                Text(port.processName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SentryTheme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("PID \(port.pid)")
                        .font(.system(size: 10, design: .monospaced))
                    Text(port.address == "*" ? "all interfaces" : port.address)
                        .font(.system(size: 10))
                }
                .foregroundStyle(SentryTheme.muted)
            }

            Spacer()

            // Kill button
            Button {
                scanner.killConfirmation = port
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(SentryTheme.danger.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .help("Kill \(port.processName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(SentryTheme.cardBG, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let time = scanner.lastScanTime {
                Text("Updated \(time.formatted(.dateTime.hour().minute().second()))")
                    .font(.system(size: 10))
                    .foregroundStyle(SentryTheme.muted)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 11))
            .foregroundStyle(SentryTheme.muted)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Kill result banner

    private func killResultBanner(port: ListeningPort, result: KillResult) -> some View {
        HStack(spacing: 8) {
            switch result {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SentryTheme.success)
                Text("Killed \(port.processName) on port \(port.port)")
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Failed: \(reason)")
            case .alreadyDead:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SentryTheme.success)
                Text("\(port.processName) already stopped")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(SentryTheme.brightText)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
