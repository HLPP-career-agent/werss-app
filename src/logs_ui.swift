// logs_ui.swift —— 「全量日志」窗口（数据来自 logs/events.jsonl：process_chunk/run_forever/keepalive
// 的结构化事件 + 从 companies.csv 播种的第一/二批"已添加"历史）。
// 与 menubar_app.swift 同模块编译（bash bin/build_menubar.sh）。
// 窗口/VM/自动刷新模式照搬 review_ui.swift（ReviewVM/ReviewWindowController）。
import AppKit
import SwiftUI

// Shell 侧事件经 bin/ev.py 写入;Swift 侧(菜单栏实时检测授权状态变化)用这个直接追加
func emitEvent(_ type: String, detail: String, state: String? = nil) {
    DispatchQueue.global(qos: .utility).async {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        var o: [String: Any] = ["ts": f.string(from: Date()), "type": type, "detail": detail]
        if let s = state { o["state"] = s }
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let line = String(data: data, encoding: .utf8) else { return }
        let path = root + "/logs/events.jsonl"
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            try? h.seekToEnd()
            if let d = line.data(using: .utf8) { try? h.write(d) }
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

struct LogEvent {
    var ts = ""
    var type = ""
    var detail = ""
    var companyID = ""
    var companyName = ""
    var mpName = ""
    var round: Int?
    var worker = ""
    var kws = ""
    var state = ""          // scan 类型专用: fail=需扫码 / ok=已恢复

    // 普通事件只保留 7 天(keepalive 里 ev.py prune);added 是台账镜像,全量保留
    static let retainDays = 7

    var timeText: String {
        guard ts.count >= 16 else { return ts.isEmpty ? "—" : ts }
        // "2026-10-04T15:14:12" → "10-04 15:14"
        let body = ts.prefix(16).replacingOccurrences(of: "T", with: " ")
        return String(body.dropFirst(5))
    }

    var typeLabel: String {
        if type == "scan" {
            if state == "ok" { return "已恢复" }
            if state == "open" { return "已开扫码页" }
            return "需扫码"
        }
        switch type {
        case "added":          return "已添加"
        case "not_found":      return "未找到"
        case "pending_review": return "待复核"
        case "abort":          return "异常"
        case "canary":         return "金丝雀"
        case "chunk":          return "进度"
        case "runner":         return "运行器"
        case "keepalive":      return "保活"
        default:               return type
        }
    }

    var color: Color {
        if type == "scan" {
            if state == "ok" { return .green }
            if state == "open" { return .yellow }
            return .red
        }
        switch type {
        case "added":          return .green
        case "pending_review": return .orange
        case "abort":          return .red
        case "canary":         return .blue
        case "chunk":          return .teal
        case "runner", "keepalive": return .purple
        default:               return .secondary
        }
    }

    var roundText: String {
        guard let r = round else { return "" }
        return "第\(r)轮"
    }
}

final class LogsVM: ObservableObject {
    @Published var rows: [LogEvent] = []
    @Published var filter = "all"
    @Published var search = ""
    @Published var counts: [String: Int] = [:]
    @Published var lastLoaded = "--:--:--"

    private var all: [LogEvent] = []
    private var autoTimer: Timer?

    func startAutoRefresh() {
        reload()
        guard autoTimer == nil else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reload(quiet: true)
        }
    }

    func stopAutoRefresh() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    func reload(quiet: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let events = LogsVM.loadEvents()
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = events
                var c: [String: Int] = ["total": events.count]
                for e in events { c[e.type, default: 0] += 1 }
                c["system"] = ["abort", "canary", "chunk", "runner", "keepalive"]
                    .reduce(0) { $0 + (c[$1] ?? 0) }
                self.counts = c
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                self.lastLoaded = f.string(from: Date())
                self.applyFilter()
            }
        }
    }

    func applyFilter() {
        let q = search.lowercased()
        rows = all.filter { e in
            let typeOK: Bool
            switch filter {
            case "added":          typeOK = e.type == "added"
            case "not_found":      typeOK = e.type == "not_found"
            case "pending_review": typeOK = e.type == "pending_review"
            case "scan":           typeOK = e.type == "scan"
            case "system":         typeOK = ["abort", "canary", "chunk", "runner", "keepalive"].contains(e.type)
            default:               typeOK = true
            }
            guard typeOK else { return false }
            if q.isEmpty { return true }
            return [e.companyName, e.companyID, e.mpName, e.detail, e.kws]
                .contains { $0.lowercased().contains(q) }
        }
    }

    static func loadEvents() -> [LogEvent] {
        let path = root + "/logs/events.jsonl"
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        // 普通事件 7 天窗口;added 全量(跨第一/二批的"最近添加成功"场景)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let cutoff = f.string(from: Date().addingTimeInterval(-Double(LogEvent.retainDays) * 86400))
        return s.split(separator: "\n").compactMap { line -> LogEvent? in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            let type = o["type"] as? String ?? ""
            let ts = o["ts"] as? String ?? ""
            if type != "added" && ts < cutoff { return nil }
            var e = LogEvent()
            e.ts = ts
            e.type = type
            e.detail = o["detail"] as? String ?? ""
            e.companyID = o["company_id"] as? String ?? ""
            e.companyName = o["company_name"] as? String ?? ""
            e.mpName = o["mp_name"] as? String ?? ""
            e.round = (o["round"] as? NSNumber)?.intValue
            e.worker = (o["worker"] as? String) ?? ""
            e.kws = o["kws"] as? String ?? ""
            e.state = o["state"] as? String ?? ""
            return e
        }.sorted { $0.ts > $1.ts }   // 最新在最前
    }
}

struct LogRow: View {
    let e: LogEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(e.color).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.timeText).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text(e.typeLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(e.color)
                    if !e.roundText.isEmpty {
                        Text(e.roundText).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !e.worker.isEmpty {
                        Text("w\(e.worker)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Text(e.companyName.isEmpty ? e.companyID : e.companyName)
                        .font(.system(size: 12)).lineLimit(1)
                    if !e.mpName.isEmpty {
                        Text("→ " + e.mpName).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if !e.detail.isEmpty {
                    Text(e.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct LogsView: View {
    @ObservedObject var vm: LogsVM
    // 搜索不常驻:默认只留放大镜按钮(⌘F),展开后 Esc/再点收起并清空条件
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: $vm.filter) {
                Text("全部 \(vm.counts["total"] ?? 0)").tag("all")
                Text("已添加 \(vm.counts["added"] ?? 0)").tag("added")
                Text("未找到 \(vm.counts["not_found"] ?? 0)").tag("not_found")
                Text("待复核 \(vm.counts["pending_review"] ?? 0)").tag("pending_review")
                Text("需扫码 \(vm.counts["scan"] ?? 0)").tag("scan")
                Text("异常/系统 \(vm.counts["system"] ?? 0)").tag("system")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: 440, idealWidth: 540)
            .onChange(of: vm.filter) { _ in vm.applyFilter() }
            Spacer(minLength: 8)
            searchCluster
            Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("立即刷新")
        }
        .padding(10)
    }

    private var searchCluster: some View {
        HStack(spacing: 4) {
            if searchExpanded {
                TextField("搜索 公司 / 公众号 / 理由", text: $vm.search)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .focused($searchFocused)
                    .onExitCommand { collapseSearch() }
                    .frame(width: 160)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Button {
                searchExpanded ? collapseSearch() : expandSearch()
            } label: {
                Image(systemName: searchExpanded ? "xmark.circle.fill" : "magnifyingglass")
            }
            .help(searchExpanded ? "收起搜索(Esc)" : "搜索(⌘F)")
            .keyboardShortcut("f", modifiers: .command)
        }
        .onChange(of: vm.search) { _ in vm.applyFilter() }
    }

    private func expandSearch() {
        withAnimation(.easeOut(duration: 0.15)) { searchExpanded = true }
        DispatchQueue.main.async { searchFocused = true }
    }

    // 收起时必须清空条件,否则列表还被一个看不见的关键词过滤着
    private func collapseSearch() {
        searchFocused = false
        withAnimation(.easeIn(duration: 0.15)) {
            searchExpanded = false
            if !vm.search.isEmpty { vm.search = "" }
        }
    }

    private var list: some View {
        // ts 有同秒重复(播种数据),不能用 ts 作 id,用行号
        List(Array(vm.rows.enumerated()), id: \.offset) { _, e in
            LogRow(e: e)
        }
        .listStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text("普通事件保留 \(LogEvent.retainDays) 天 · 已添加全量(跨批次) · 共 \(vm.rows.count) 条")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text("每 10 秒自动刷新 · 最后加载 \(vm.lastLoaded)")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

final class LogsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LogsWindowController()
    let vm = LogsVM()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "全量日志"
        win.subtitle = "批量匹配执行明细 · 最新在前"
        win.contentView = NSHostingView(rootView: LogsView(vm: vm))
        win.center()
        super.init(window: win)
        win.delegate = self
        win.setFrameAutosaveName("WERSSLogsWindow")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        vm.reload()
        vm.startAutoRefresh()
    }

    func windowWillClose(_ notification: Notification) {
        vm.stopAutoRefresh()
    }
}
