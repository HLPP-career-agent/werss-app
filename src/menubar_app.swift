// WERSS菜单栏：常驻状态图标 + 下拉菜单（状态/14天趋势曲线/待办直达/可点击通知）
// 编译: bash bin/build_menubar.sh（与 src/review_ui.swift 一起编译——审核窗口/进程助手在那边）
// 趋势图样式参考 ai-quota-bar：SwiftUI Path 曲线 + 渐变填充 + NSHostingView 嵌入 NSMenu
import AppKit
import UserNotifications

// ---- 7 天趋势历史采样：logs/history.tsv，每行 "unix feeds articles" ----
struct Sample { let t: Date; let feeds: Double; let articles: Double; let hc: Double? }

enum History {
    static let file = root + "/logs/history.tsv"

    static func load() -> [Sample] {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-15 * 86400)   // 7 天柱状图 + 窗口前基线 + 缓冲
        return s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t")
            guard p.count >= 3, let t = TimeInterval(p[0]), let f = Double(p[1]), let a = Double(p[2]) else { return nil }
            let hc = p.count >= 4 ? Double(p[3]) : nil
            let d = Date(timeIntervalSince1970: t)
            return d >= cutoff ? Sample(t: d, feeds: f, articles: a, hc: hc) : nil
        }.sorted { $0.t < $1.t }
    }

    static func sample(feeds: Double, articles: Double, hc: Double?) {
        let lines = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-16 * 86400).timeIntervalSince1970
        var kept: [String] = []
        for line in lines.split(separator: "\n") {
            if let t = line.split(separator: "\t").first, let v = TimeInterval(t), v >= cutoff { kept.append(String(line)) }
        }
        var row = "\(Int(Date().timeIntervalSince1970))\t\(Int(feeds))\t\(Int(articles))"
        if let hc = hc { row += "\t\(Int(hc))" }
        kept.append(row)
        try? kept.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}

// ---- 7 天趋势图（纯 AppKit 自绘；三列：左饼图（公众号进度 csv_added/pending/notfound）+ 右上公众号小时柱 + 右下文章天柱）----
final class TrendView: NSView {
    var samples: [Sample] = [] { didSet { needsDisplay = true } }
    var articlesSub = "" { didSet { needsDisplay = true } }   // 如 "正文 790"
    // 实时 feeds / articles（来自 status.sh），跨过午夜 history 还没今天采样时兜底
    var liveFeeds: Double = -1 { didSet { needsDisplay = true } }
    var liveArticles: Double = -1 { didSet { needsDisplay = true } }
    // 饼图数据源（公众号进度：已采/待采/未找到，任一 < 0 表示数据无效）
    var pieAdded: Double = -1 { didSet { needsDisplay = true } }
    var piePending: Double = -1 { didSet { needsDisplay = true } }
    var pieNotfound: Double = -1 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 340, height: 150) }

    // 7 天 × 24 小时柱状图：168 根柱子（每天一组 24 根），高度 = 该小时增量；x 轴每天显示一次日期；组间用浅色分隔线
    // liveValue（status.sh 实时 feeds/articles）覆盖今天当前小时 lastValue 并重算 delta
    // 头行：色点 名称 [副信息] …… 当前值（公众号/文章两图共用）
    private func drawHead(_ rect: NSRect, name: String, color: NSColor, sub: String?, lastValue: Double) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - 8, width: 4, height: 4), xRadius: 1.5, yRadius: 1.5).fill()
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        (name as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.maxY - 12), withAttributes: nameAttrs)
        if let sub = sub, !sub.isEmpty {
            let nx = rect.minX + 10 + (name as NSString).size(withAttributes: nameAttrs).width + 6
            (sub as NSString).draw(at: NSPoint(x: nx, y: rect.maxY - 12),
                withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        let head = NSMutableAttributedString()
        head.append(NSAttributedString(string: "\(Int(lastValue))", attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        head.draw(at: NSPoint(x: rect.maxX - head.size().width - 2, y: rect.maxY - 13))
    }

    private func drawBars(_ rect: NSRect, name: String, color: NSColor, samples: [Sample], value: (Sample) -> Double, sub: String?, axisBottom: Bool, liveValue: Double = -1) {
        // rect 结构：[头行 13][曲线区][底 12]
        var daily = dailyBars(samples, value: value)            // 168 项（7×24）
        let currentIdx = 6 * 24 + Calendar.current.component(.hour, from: Date())

        // 用 status.sh 实时值覆盖今天当前小时（索引 6*24+currentHour）
        if liveValue >= 0, currentIdx < daily.count {
            let prevHourVal: Double = currentIdx > 0 ? daily[currentIdx - 1].lastValue : 0
            // prevHourVal=0 = 还没有任何基线（如刚装菜单栏、history.tsv 还没采样）：只立基线不计增量，避免全量值画成一根巨柱
            let hourDelta = prevHourVal > 0 ? max(0, liveValue - prevHourVal) : 0
            daily[currentIdx] = (day: daily[currentIdx].day, lastValue: liveValue, delta: hourDelta)
        }

        // 头行当前值 = 今天当前小时桶的 lastValue（实时覆盖后即最新累计值）
        // 不能读 daily.last——那是今天 23 点的桶，未来小时 lastValue 恒为 0，会整天显示 0
        let lastValue = daily[min(currentIdx, daily.count - 1)].lastValue
        drawHead(rect, name: name, color: color, sub: sub, lastValue: lastValue)

        // 柱状区
        let chart = NSRect(x: rect.minX, y: rect.minY + (axisBottom ? 12 : 5), width: rect.width, height: rect.height - 24)
        let maxDelta = max(daily.map { $0.delta }.max() ?? 0, 1)
        let barCount = 168
        let gap: CGFloat = 0
        let barW = chart.width / CGFloat(barCount)   // 每根柱子 ~1.2px，无间隙（barcode 风格）
        let baseY = chart.minY

        // 柱子：delta>0 画细彩色矩形；delta=0 画明显浅色 baseline（让 24 个小时位置都肉眼可见）
        for (i, item) in daily.enumerated() {
            let x = chart.minX + CGFloat(i) * barW
            NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: max(0.5, barW - 0.1), height: 1.5), xRadius: 0.3, yRadius: 0.3).fill()
            if item.delta > 0 {
                let h = CGFloat(item.delta / maxDelta) * chart.height
                let barH = max(1.5, h)
                let bar = NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: max(0.5, barW - 0.1), height: barH), xRadius: 0.3, yRadius: 0.3)
                color.setFill()
                bar.fill()
            }
        }

        // 每天总增量（7 个数字，画在每天组内最高柱子的顶上方居中）
        let dayTotalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let dayTotalHaloAttrs = dayTotalAttrs.merging([.foregroundColor: NSColor.windowBackgroundColor]) { _, new in new }
        for d in 0..<7 {
            let dayTotal: Double = (0..<24).reduce(0.0) { $0 + max(0, daily[d*24 + $1].delta) }
            guard dayTotal > 0 else { continue }
            let maxH: CGFloat = (0..<24).map { CGFloat(daily[d*24 + $0].delta / maxDelta) * chart.height }.max() ?? 0
            let i = d * 24 + 12   // x 位置：每天中午 12 点（组内居中）
            let x = chart.minX + CGFloat(i) * barW + barW / 2
            let txt = "\(Int(dayTotal))" as NSString
            let size = txt.size(withAttributes: dayTotalAttrs)
            let lx = min(max(chart.minX, x - size.width / 2), chart.maxX - size.width)
            // y 封顶在柱状区内：柱子太高时数字不许顶进头行（色点/名称/当前总数）
            let ly = min(baseY + max(1.0, maxH) + 1, chart.maxY - size.height - 2)
            // 封顶后数字可能压在柱子上：四周描一圈窗口底色光晕保证可读（在菜单底色上则不可见）
            for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
                txt.draw(at: NSPoint(x: lx + dx, y: ly + dy), withAttributes: dayTotalHaloAttrs)
            }
            txt.draw(at: NSPoint(x: lx, y: ly), withAttributes: dayTotalAttrs)
        }

        // 组间分隔线：每天末尾只画底部 6px 短刻度（避免看起来像柱子）；颜色更淡
        NSColor.tertiaryLabelColor.withAlphaComponent(0.18).setStroke()
        for d in 1..<7 {
            let x = chart.minX + CGFloat(d * 24) * barW - gap / 2
            let sep = NSBezierPath()
            sep.move(to: NSPoint(x: x, y: baseY - 1))
            sep.line(to: NSPoint(x: x, y: baseY - 7))   // 仅底部 6px
            sep.lineWidth = 0.5
            sep.stroke()
        }

        // x 轴日期：每天中午（i = d*24 + 12）画一个日期标签，7 个标签
        if axisBottom {
            let lAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let df = DateFormatter(); df.dateFormat = "d"
            for d in 0..<7 {
                let i = d * 24 + 12   // 每天的中午 12 点
                guard i < daily.count else { continue }
                let item = daily[i]
                let txt = df.string(from: item.day) as NSString
                let x = chart.minX + CGFloat(i) * barW + barW / 2
                let size = txt.size(withAttributes: lAttrs)
                let lx = min(max(chart.minX, x - size.width / 2), chart.maxX - size.width)
                txt.draw(at: NSPoint(x: lx, y: rect.minY + 1), withAttributes: lAttrs)
            }
        }
    }

    // 文章 7 天柱状图（按天）：文章列表经微信读书通道同步，实测每天只在风控放行窗口（约 0 点后几分钟）
    // 成功落库一批，一天之内没有小时级变化，小时柱全贴地——所以与公众号的小时柱分开，每根柱 = 当天文章增量。
    // 数据聚合复用 dailyBars 的小时分桶结果按天求和（含 status.sh 实时值对当前小时的覆盖），头行同款显示当前累计
    private func drawDayBars(_ rect: NSRect, name: String, color: NSColor, samples: [Sample], value: (Sample) -> Double, sub: String?, liveValue: Double = -1) {
        var hourly = dailyBars(samples, value: value)           // 168 项（7×24）
        let currentIdx = 6 * 24 + Calendar.current.component(.hour, from: Date())

        // status.sh 实时值覆盖今天当前小时（与小时图同一逻辑，保证头行是最新累计值）
        if liveValue >= 0, currentIdx < hourly.count {
            let prevHourVal: Double = currentIdx > 0 ? hourly[currentIdx - 1].lastValue : 0
            let hourDelta = prevHourVal > 0 ? max(0, liveValue - prevHourVal) : 0
            hourly[currentIdx] = (day: hourly[currentIdx].day, lastValue: liveValue, delta: hourDelta)
        }

        let lastValue = hourly[min(currentIdx, hourly.count - 1)].lastValue
        drawHead(rect, name: name, color: color, sub: sub, lastValue: lastValue)

        // 按天聚合：柱高 = 当天增量（该天 24 个小时 delta 之和）
        let chart = NSRect(x: rect.minX, y: rect.minY + 12, width: rect.width, height: rect.height - 24)
        var dayTotals: [Double] = []
        for d in 0..<7 {
            dayTotals.append((0..<24).reduce(0.0) { $0 + max(0, hourly[d*24 + $1].delta) })
        }
        let maxDelta = max(dayTotals.max() ?? 0, 1)
        let slotW = chart.width / 7
        let barW = max(8, slotW - 8)     // 柱间留缝：7 根粗柱，与小时 barcode 风格区分
        let baseY = chart.minY

        for d in 0..<7 {
            let x = chart.minX + CGFloat(d) * slotW + (slotW - barW) / 2
            // 底座：无增量的天也画浅色短底，让 7 天位置都肉眼可见
            NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: 1.5), xRadius: 0.3, yRadius: 0.3).fill()
            let total = dayTotals[d]
            guard total > 0 else { continue }
            let h = max(1.5, CGFloat(total / maxDelta) * chart.height)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: h), xRadius: 0.3, yRadius: 0.3).fill()
        }

        // 每根柱顶上方标注当天增量（光晕描边保证可读，与小时图同款手法）
        let totalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let totalHaloAttrs = totalAttrs.merging([.foregroundColor: NSColor.windowBackgroundColor]) { _, new in new }
        for d in 0..<7 {
            let total = dayTotals[d]
            guard total > 0 else { continue }
            let h = max(1.5, CGFloat(total / maxDelta) * chart.height)
            let x = chart.minX + CGFloat(d) * slotW + slotW / 2
            let txt = "\(Int(total))" as NSString
            let size = txt.size(withAttributes: totalAttrs)
            let lx = min(max(chart.minX, x - size.width / 2), chart.maxX - size.width)
            let ly = min(baseY + h + 1, chart.maxY - size.height - 2)
            for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
                txt.draw(at: NSPoint(x: lx + dx, y: ly + dy), withAttributes: totalHaloAttrs)
            }
            txt.draw(at: NSPoint(x: lx, y: ly), withAttributes: totalAttrs)
        }

        // x 轴日期：每天柱子正下方一个标签
        let lAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let df = DateFormatter(); df.dateFormat = "d"
        for d in 0..<7 {
            let txt = df.string(from: hourly[d * 24].day) as NSString
            let x = chart.minX + CGFloat(d) * slotW + slotW / 2
            let size = txt.size(withAttributes: lAttrs)
            let lx = min(max(chart.minX, x - size.width / 2), chart.maxX - size.width)
            txt.draw(at: NSPoint(x: lx, y: rect.minY + 1), withAttributes: lAttrs)
        }
    }

    // 按小时分桶：最近 7 天 × 24 小时 = 168 项（day 0..6，day 6 = 今天）；每项代表那一个小时
    // delta = max(0, lastValue - 前一小时 lastValue)；基线取窗口(7天)前最后一个采样（load 保留 15 天）
    // 没有基线时（如刚装机）窗口内首个采样只作起点 delta=0——否则全量累计值会被当成一小时的增量画出巨柱
    // 缺失小时 delta=0（lastVal 沿用 prevVal）；未来小时 lastVal=0 delta=0
    private func dailyBars(_ samples: [Sample], value: (Sample) -> Double) -> [(day: Date, lastValue: Double, delta: Double)] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let currentHour = cal.component(.hour, from: now)  // 0..23
        let windowStart = cal.date(byAdding: .day, value: -6, to: today)!   // day 0 的 0 点

        // byHour[hour] = 该小时最后一个采样值（只统计 7 天内的）；seed = 窗口前最后一个采样（delta 基线）
        var byHour: [Date: Double] = [:]
        var seed: Double?
        for s in samples {
            if s.t < windowStart { seed = value(s); continue }   // samples 已按时间升序，最后一个窗口前采样胜出
            let day = cal.startOfDay(for: s.t)
            let dayDiff = cal.dateComponents([.day], from: day, to: today).day ?? 99
            guard dayDiff >= 0 && dayDiff < 7 else { continue }
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: s.t)
            if let h = cal.date(from: comps) {
                byHour[h] = value(s)
            }
        }

        var result: [(Date, Double, Double)] = []
        var prevVal = seed   // nil = 尚无任何基线
        for d in 0..<7 {
            let day = cal.date(byAdding: .day, value: -(6 - d), to: today)!
            for h in 0..<24 {
                let hour = cal.date(byAdding: .hour, value: h, to: day)!
                let isFuture = (d == 6 && h > currentHour)
                let lastVal: Double
                let delta: Double
                if isFuture {
                    lastVal = 0
                    delta = 0
                } else if let v = byHour[hour] {
                    lastVal = v
                    delta = prevVal.map { max(0, v - $0) } ?? 0   // 无基线时首个采样只作起点，不计增量
                    prevVal = v
                } else {
                    // 该小时没采样：lastVal 沿用 prevVal（保持连续），delta = 0
                    // 注意缺失/未来桶不得改写 prevVal——否则"尚无基线"的 nil 会被固化成 0，后续首个采样又变全量巨柱
                    lastVal = prevVal ?? 0
                    delta = 0
                }
                result.append((hour, lastVal, delta))
            }
        }
        return result.map { (day: $0.0, lastValue: $0.1, delta: $0.2) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inner = NSRect(x: bounds.minX + 14, y: bounds.minY + 6, width: bounds.width - 28, height: bounds.height - 14)
        // 三列布局：左饼图（~1/3 宽）+ 间隔 + 右上公众号小时柱状图 + 右下文章天柱状图
        let pieW: CGFloat = 96
        let gap: CGFloat = 14
        let trendX = inner.minX + pieW + gap
        let trendW = inner.maxX - trendX
        // 左列：饼图 + 图例 + 总数（垂直排列）
        drawPieChart(in: NSRect(x: inner.minX, y: inner.minY, width: pieW, height: inner.height))
        // 右两行：公众号小时柱（数据全天都有）+ 文章天柱（数据每天仅午夜落库一批，见 drawDayBars 注释）
        let rowH = (inner.height - 16) / 2
        drawBars(NSRect(x: trendX, y: inner.minY + rowH + 16, width: trendW, height: rowH),
                 name: "公众号", color: .controlAccentColor, samples: samples, value: { $0.feeds }, sub: nil, axisBottom: false, liveValue: liveFeeds)
        drawDayBars(NSRect(x: trendX, y: inner.minY, width: trendW, height: rowH),
                 name: "文章", color: .systemOrange, samples: samples, value: { $0.articles }, sub: articlesSub.isEmpty ? nil : articlesSub, liveValue: liveArticles)
    }

    // 左列饼图：饼图（56px 直径，居顶）+ 3 行图例（已采/待采/未找到）+ 总数
    private func drawPieChart(in rect: NSRect) {
        let pieValid = pieAdded >= 0 && piePending >= 0 && pieNotfound >= 0 && (pieAdded + piePending + pieNotfound) > 0
        let dia: CGFloat = 56
        let pieTopY = rect.maxY - dia - 6    // 距顶 6px
        let pieRect = NSRect(x: rect.midX - dia / 2, y: pieTopY, width: dia, height: dia)
        let cx = pieRect.midX, cy = pieRect.midY, r = dia / 2

        // 扇形
        if pieValid {
            let total = pieAdded + piePending + pieNotfound
            let slices: [(Double, NSColor)] = [
                (pieAdded, NSColor.systemGreen),
                (piePending, NSColor.controlAccentColor),
                (pieNotfound, NSColor.systemGray),
            ]
            var startDeg = -90.0
            for (val, color) in slices where val > 0 {
                let sweep = 360.0 * val / total
                let endDeg = startDeg - sweep
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx, y: cy))
                p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                    startAngle: CGFloat(startDeg), endAngle: CGFloat(endDeg), clockwise: true)
                p.close()
                color.setFill()
                p.fill()
                startDeg = endDeg
            }
            NSColor.windowBackgroundColor.setStroke()
            let ring = NSBezierPath(ovalIn: pieRect.insetBy(dx: -0.5, dy: -0.5))
            ring.lineWidth = 1.0
            ring.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            NSBezierPath(ovalIn: pieRect).stroke()
            ("无数据" as NSString).draw(at: NSPoint(x: cx - 18, y: cy - 5),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor])
        }

        // 图例（饼图下方三行，留 16px 呼吸空间）
        let legendTopY: CGFloat = pieRect.minY - 16   // 饼图底留 16px
        let rowH: CGFloat = 14
        let dotR: CGFloat = 3
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]

        func drawLegend(_ y: CGFloat, label: String, color: NSColor, value: Double) {
            color.setFill()
            // 圆点上移 2px，让 visual center 跟文字（10pt baseline）一致（不"掉下去"）
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 2, y: y - dotR + 2, width: dotR * 2, height: dotR * 2)).fill()
            (label as NSString).draw(at: NSPoint(x: rect.minX + 11, y: y - 4), withAttributes: labelAttrs)
            let valTxt = pieValid ? "\(Int(value))" : "?"
            (valTxt as NSString).draw(at: NSPoint(x: rect.maxX - 2 - (valTxt as NSString).size(withAttributes: valueAttrs).width, y: y - 5),
                withAttributes: valueAttrs)
        }
        // 三行图例：已采（顶）→ 待采 → 未找到（底）
        drawLegend(legendTopY - rowH * 0, label: "已采",   color: NSColor.systemGreen,        value: pieAdded)
        drawLegend(legendTopY - rowH * 1, label: "待采",   color: NSColor.controlAccentColor,  value: piePending)
        drawLegend(legendTopY - rowH * 2, label: "未找到", color: NSColor.systemGray,         value: pieNotfound)

        // 上市公司（与图例同款样式：label 10pt secondaryLabelColor 在左、value 11pt bold labelColor 右对齐）
        if pieValid {
            let totalY: CGFloat = legendTopY - rowH * 3   // 与三行图例保持相同行间距
            let total = Int(pieAdded + piePending + pieNotfound)
            ("上市公司总数" as NSString).draw(at: NSPoint(x: rect.minX + 2, y: totalY - 4),
                withAttributes: labelAttrs)
            let valTxt = "\(total)" as NSString
            let valSize = valTxt.size(withAttributes: valueAttrs)
            (valTxt as NSString).draw(at: NSPoint(x: rect.maxX - 2 - valSize.width, y: totalY - 5),
                withAttributes: valueAttrs)
        }
    }
}

// 状态行：单行文字。三行状态统一用本视图渲染，保证字体/颜色/边距完全一致
final class StatusRowView: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 18))
        addSubview(label)
    }

    init(attributedText: NSAttributedString) {
        label = NSTextField(labelWithAttributedString: attributedText)
        label.font = NSFont.systemFont(ofSize: 10)
        label.lineBreakMode = .byClipping
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 18))
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 14, y: (frame.height - label.frame.height) / 2)
    }
}

struct Status {
    var dict: [String: String] = [:]
    var wereadFail: Bool { dict["weread"] == "FAIL" || dict["weread"] == "LOGINERR" }
    // 微信主授权（公众号搜索/添加通道），与微信读书授权是两个独立凭证
    var wxAuthFail: Bool { dict["wx_auth"] == "EXPIRED" }
    var runnerDown: Bool { dict["runner"] == "DOWN" && sliceLeft > 0 }
    var appDown: Bool { dict["app"] != "OK" || dict["container"] != "UP" }
    var dockerDown: Bool { dict["docker"] == "DOWN" }
    var sliceLeft: Int { Int(dict["slice"] ?? "-1") ?? -1 }
    var level: Int { dockerDown ? 3 : (appDown ? 3 : (wereadFail || wxAuthFail || runnerDown ? 2 : 1)) }
}

// ---- 可点击通知：真 App 进程 + 事件循环，权限/点击回调均可用 ----
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var authorized = false

    func bootstrap() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    func post(id: String, title: String, body: String, action: String, sound: Bool = true) {
        guard authorized else { return }
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [id])
        c.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["action": action]
        if sound { content.sound = .default }
        c.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.notification.request.content.userInfo["action"] as? String ?? "admin"
        switch action {
        case "scan":   runSh("bash '\(root)/bin/open_scan_page.sh'")
        case "wxscan": runSh("bash '\(root)/bin/open_scan_page.sh' --wx")
        case "repair": runSh("bash '\(root)/bin/keepalive.sh'")
        case "review": DispatchQueue.main.async { ReviewWindowController.shared.show() }
        default:       runSh("open http://localhost:8001/")
        }
        completionHandler()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var st = Status()
    var lastLevel = 0
    var prevWereadFail = false
    var lastWereadNag: Date?
    var prevWxAuthFail = false
    var lastWxNag: Date?
    var lastFaultNag: Date?
    var lastSample = Date.distantPast
    var samples: [Sample] = []
    var menu = NSMenu()
    var jobsPending = -1
    var jobsUnseen = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        dedupeInstances()
        Notifier.shared.bootstrap()
        samples = History.load()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "werss …"
        statusItem.button?.toolTip = "微信公众号采集系统"
        rebuildMenu()
        refresh()
        // 退出菜单栏会停掉 runner + 容器（用户定规则：关掉图标=这套服务不再需要），
        // 所以图标回来时服务是停的。立即补一轮保活把全套拉回来，不必干等 keepalive 的
        // 30 分钟间隔（否则菜单栏会先红着显示故障，等半小时才自愈）。
        // keepalive.sh 有在场闸、且全程幂等（已在跑就跳过），重复触发无副作用。
        runSh("bash '\(root)/bin/keepalive.sh' >> '\(root)/logs/launchd-keepalive.log' 2>&1")
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        // 深链/自动化：启动即打开审核窗口
        if CommandLine.arguments.contains("--open-review") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ReviewWindowController.shared.show() }
        }
    }

    /// 单实例守卫:同可执行文件的多实例按 pid 定胜负,只保留最新(launchd KeepAlive
    /// 与手动 open 撞车时自动收敛,2026-10-04 双实例事故的兜底)。
    private func dedupeInstances() {
        let myPath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first
        let mine = ProcessInfo.processInfo.processIdentifier
        let allApps = NSWorkspace.shared.runningApplications
        let others = allApps
            .filter { $0.processIdentifier != mine && $0.executableURL?.path == myPath }
        for other in others where other.processIdentifier > mine {
            exit(0)   // 已有更新的实例在跑,自己退出
        }
        for other in others where other.processIdentifier < mine {
            kill(other.processIdentifier, SIGTERM)   // 自己最新,淘汰旧实例
        }
    }

    func refresh() {
        runShCapture("bash '\(root)/bin/status.sh' --parse", timeout: 60) { [weak self] out in
            guard let self = self else { return }
            var d: [String: String] = [:]
            for line in out.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { d[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
            }
            self.prevWereadFail = self.st.wereadFail
            self.prevWxAuthFail = self.st.wxAuthFail
            self.lastLevel = self.st.level
            self.st = Status()
            self.st.dict = d
            // 每 5 分钟采样一次趋势数据
            if let f = Double(d["feeds"] ?? ""), f >= 0, Date().timeIntervalSince(self.lastSample) > 300 {
                History.sample(feeds: f, articles: Double(d["articles"] ?? "0") ?? 0, hc: Double(d["has_content"] ?? "") ?? nil)
                self.lastSample = Date()
                self.samples = History.load()
            }
            self.render()
            self.notifyOnTransitions()
        }
        refreshJobs()
    }

    // 招聘帖待审统计（jobs.py stats）：菜单角标 + 有新帖时系统通知
    func refreshJobs() {
        jobsCmd("stats", timeout: 20) { [weak self] out in
            guard let self = self else { return }
            var d: [String: String] = [:]
            for line in out.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { d[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
            }
            let p = Int(d["pending"] ?? "") ?? -1
            let u = Int(d["unseen"] ?? "") ?? 0
            let hadPrev = self.jobsPending >= 0
            let increased = hadPrev && p > self.jobsPending
            self.jobsPending = p
            self.jobsUnseen = u
            self.rebuildMenu()
            if increased && u > 0 {
                Notifier.shared.post(id: "werss-jobs",
                    title: "发现新招聘帖",
                    body: "新增待审，当前共 \(p) 篇待审核。点此打开审核窗口",
                    action: "review")
            }
        }
    }

    func notifyOnTransitions() {
        // 扫码事件:授权状态变化(失效/恢复)由菜单栏实时写日志,30 秒内可见;keepalive 不再重复发。
        // 此处 st 已是新数据、prev* 是上一轮数据,语义与下方通知逻辑一致。
        if st.wereadFail != prevWereadFail {
            emitEvent("scan", detail: st.wereadFail
                ? "微信读书授权失效,需扫码(文章正文采集暂停,账号添加不受影响)"
                : "微信读书授权已恢复",
                state: st.wereadFail ? "fail" : "ok")
        }
        if st.wxAuthFail != prevWxAuthFail {
            emitEvent("scan", detail: st.wxAuthFail
                ? "微信公众号主授权失效,需扫码(公众号搜索/添加已停,金丝雀自动拦截)"
                : "微信公众号主授权已恢复",
                state: st.wxAuthFail ? "fail" : "ok")
        }
        let now = Date()
        if st.wereadFail && (!prevWereadFail || lastWereadNag == nil || now.timeIntervalSince(lastWereadNag!) > 1800) {
            Notifier.shared.post(id: "werss-weread",
                title: "微信读书授权失效，待扫码",
                body: "点此直达扫码页（自动登录）。文章正文暂停中，扫码后 ≤10 分钟自动恢复采集",
                action: "scan")
            lastWereadNag = now
        }
        // 微信主授权（公众号搜索/添加通道）失效：批量添加已被金丝雀自动暂停，需重新扫码
        if st.wxAuthFail && (!prevWxAuthFail || lastWxNag == nil || now.timeIntervalSince(lastWxNag!) > 1800) {
            Notifier.shared.post(id: "werss-wxauth",
                title: "微信授权失效，公众号搜索/添加已停",
                body: "点此直达授权管理页扫码（自动登录）。扫码后采集自动恢复",
                action: "wxscan")
            lastWxNag = now
        }
        if st.level == 3 && (lastLevel < 3 || lastFaultNag == nil || now.timeIntervalSince(lastFaultNag!) > 1800) {
            Notifier.shared.post(id: "werss-fault",
                title: "werss 系统故障",
                body: "Docker/容器/应用异常。点此立即自动修复",
                action: "repair")
            lastFaultNag = now
        }
        if prevWereadFail && !st.wereadFail {
            Notifier.shared.post(id: "werss-recovered",
                title: "微信读书授权已恢复",
                body: "文章正文采集将自动继续（≤10 分钟内下一轮补抓生效）",
                action: "admin", sound: false)
        }
        if prevWxAuthFail && !st.wxAuthFail {
            Notifier.shared.post(id: "werss-wxrecovered",
                title: "微信授权已恢复",
                body: "公众号搜索/添加已恢复，采集自动继续",
                action: "admin", sound: false)
        }
        if lastLevel >= 2 && st.level == 1 {
            Notifier.shared.post(id: "werss-recovered",
                title: "werss 已恢复正常",
                body: "全部组件在线，采集运行中",
                action: "admin", sound: false)
        }
    }

    func render() {
        switch st.level {
        case 3: statusItem.button?.title = "werss ✕"
        case 2: statusItem.button?.title = "werss ⚠️"
        default: statusItem.button?.title = "werss ✓"
        }
        let d = st.dict
        // 公司总数 = 已采(csv_added) + 待采(csv_pending) + 未找到(csv_notfound)
        // 注意这里用 CSV 台账口径，不用 feeds/slice：feeds 是 SQLite 订阅数(≈已采但不等于)；
        // slice 是队列剩余(≈待采也不等于)；未找到(csv_notfound)在 feeds/slice 口径里完全体现不出来
        let a = Int(d["csv_added"] ?? "-1") ?? -1      // 已采
        let p = Int(d["csv_pending"] ?? "-1") ?? -1    // 待采
        let n = Int(d["csv_notfound"] ?? "-1") ?? -1    // 未找到
        let total = (a < 0 || p < 0 || n < 0) ? -1 : (a + p + n)
        let aTxt = a < 0 ? "?" : "\(a)"
        let pTxt = p < 0 ? "?" : "\(p)"
        let nTxt = n < 0 ? "?" : "\(n)"
        let totalTxt = total < 0 ? "?" : "\(total)"
        statusItem.button?.toolTip = "已采\(aTxt) 待采\(pTxt) 未找到\(nTxt) 总值\(totalTxt) 文章\(d["articles"] ?? "?")"
        rebuildMenu()
    }

    func mkItem(_ title: String, action: Selector? = nil, bold: Bool = false) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = action == nil ? nil : self
        m.isEnabled = action != nil
        if bold { m.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]) }
        return m
    }

    func rebuildMenu() {
        menu.removeAllItems()
        // 三行状态统一用 StatusRowView 渲染（字体/颜色/边距完全一致）；行1 右侧带刷新按钮
        let d = st.dict
        func addStatusRow(_ text: String) {
            let row = StatusRowView(text: text)
            row.frame = NSRect(x: 0, y: 0, width: 340, height: 18)
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        func addStatusRow(_ attributedText: NSAttributedString) {
            let row = StatusRowView(attributedText: attributedText)
            row.frame = NSRect(x: 0, y: 0, width: 340, height: 18)
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        // 顶部：Ego 操作最新 5 条过程日志（来自 batch/log_<N>.txt），跟其它状态行保持一致字号/对齐，前面加彩色小圆点区分类型；全量回看走「全量日志…」窗口
        let recentLogs = readLastProcessLog()
        if !recentLogs.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for entry in recentLogs.prefix(5) {
                addStatusRow(makeLogAttributedString(entry))
            }
        }
        addStatusRow("Docker \(d["docker"] ?? "?") · 容器 \(d["container"] ?? "?") · 应用 \(d["app"] ?? "?") · ego \(d["ego"] ?? "?")")
        // 公众号进度：已采(csv_added) + 待采(csv_pending) + 未找到(csv_notfound) = 公司总数
        // 用 CSV 台账口径，不用 feeds/slice，因为 feeds/slice 都漏算 csv_notfound
        let a = Int(d["csv_added"] ?? "-1") ?? -1
        let p = Int(d["csv_pending"] ?? "-1") ?? -1
        let n = Int(d["csv_notfound"] ?? "-1") ?? -1
        // 公众号进度（饼图 + 公众号trend + 文章trend）合并到一个 TrendView 里做三列布局
        addStatusRow("runner \(d["runner"] ?? "?") · 磁盘 \(d["disk_gb"] ?? "?")G · 备份 \(d["backup_days"] ?? "?")天前")
        // 微信读书授权 + 上次扫码时间 + 限流
        // 上次扫码时间所有已判定状态都显示——失效待扫码时最需要知道授权是多久前认证的
        let wereadState = d["weread"] ?? "?"
        let lastScanSuffix: String
        if let tsStr = d["weread_ok_at"], let ts = TimeInterval(tsStr), ts > 0 {
            lastScanSuffix = " · 上次扫码 \(formatAge(Date().timeIntervalSince1970 - ts))前"
        } else {
            lastScanSuffix = ""
        }
        var wereadText: String
        switch wereadState {
        case "OK":
            wereadText = "微信读书 OK" + lastScanSuffix
        case "FAIL":
            wereadText = "微信读书 失效待扫码" + lastScanSuffix
        case "LOGINERR":
            wereadText = "微信读书 登录失败" + lastScanSuffix
        default:
            wereadText = "微信读书 \(wereadState)"
        }
        let throttled = d["throttled"] == "yes" ? "冷却中" : "无"
        addStatusRow("\(wereadText) · 限流 \(throttled)")
        // 微信主授权（公众号搜索/添加通道）+ 上次扫码时间——与微信读书授权独立的凭证，
        // 失效时批量添加静默停摆，状态行必须一眼可见
        let wxState = d["wx_auth"] ?? "?"
        let wxScanSuffix: String
        if let tsStr = d["wx_ok_at"], let ts = TimeInterval(tsStr), ts > 0 {
            wxScanSuffix = " · 上次扫码 \(formatAge(Date().timeIntervalSince1970 - ts))前"
        } else {
            wxScanSuffix = ""
        }
        let wxText: String
        switch wxState {
        case "OK":      wxText = "微信授权(搜索) OK" + wxScanSuffix
        case "EXPIRED": wxText = "微信授权(搜索) 失效待扫码" + wxScanSuffix
        default:        wxText = "微信授权(搜索) \(wxState)"
        }
        addStatusRow(wxText)

        // 7 天趋势（三列布局：左饼图 + 右上公众号曲线 + 右下文章曲线）
        let trendItem = NSMenuItem()
        let trend = TrendView(frame: NSRect(x: 0, y: 0, width: 340, height: 150))
        trend.samples = samples
        trend.articlesSub = d["has_content"].flatMap { Int($0).map { "正文 \($0)" } } ?? ""
        trend.pieAdded = Double(a)
        trend.piePending = Double(p)
        trend.pieNotfound = Double(n)
        trend.liveFeeds = Double(d["feeds"] ?? "-1") ?? -1
        trend.liveArticles = Double(d["articles"] ?? "-1") ?? -1
        trendItem.view = trend
        menu.addItem(trendItem)

        // 招聘帖审核入口：有未看的新帖时加 ● 前缀并加粗
        menu.addItem(NSMenuItem.separator())
        let jobsTitle: String
        if jobsPending > 0 {
            jobsTitle = (jobsUnseen > 0 ? "● " : "") + "招聘帖审核（待审 \(jobsPending)）"
        } else {
            jobsTitle = "招聘帖审核（无待审）"
        }
        menu.addItem(mkItem(jobsTitle, action: #selector(openReview), bold: jobsUnseen > 0))
        menu.addItem(mkItem("全量日志…", action: #selector(openLogs)))

        if st.wereadFail || st.wxAuthFail || st.runnerDown || st.appDown || st.dockerDown {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(mkItem("── 待办（点击直达）──"))
            if st.wereadFail { menu.addItem(mkItem("→ 微信读书待扫码：ego 自动登录", action: #selector(openScan), bold: true)) }
            if st.wxAuthFail { menu.addItem(mkItem("→ 微信授权待扫码（搜索/添加已停）：直达授权页", action: #selector(openWxScan), bold: true)) }
            if st.appDown || st.dockerDown { menu.addItem(mkItem("→ 系统故障：立即保活修复", action: #selector(runKeepalive), bold: true)) }
            else if st.runnerDown { menu.addItem(mkItem("→ runner 未运行：拉起", action: #selector(runKeepalive), bold: true)) }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("打开管理页", action: #selector(openAdmin)))
        menu.addItem(mkItem("ego 自动登录 → 扫码页（微信读书）", action: #selector(openScan)))
        menu.addItem(mkItem("ego 自动登录 → 授权页（微信主授权）", action: #selector(openWxScan)))
        menu.addItem(mkItem("立即保活检查", action: #selector(runKeepalive)))
        // 文章同步频率：父项即现状显示（任务名/cron/启停），子菜单快速切换。
        // 走 we-mp-rss 官方 REST API（与网页端任务管理同款接口），容器程序零改动。
        // 注：文章数据经微信读书通道同步，白天常被风控拦、仅午夜放行窗口落库——
        // 调高频率不必然带来白天数据，但接口能力在此，按需选择。
        let syncCron = d["sync_task_cron"] ?? ""
        let syncParent = NSMenuItem(title: syncTitle(cron: syncCron,
                                                     name: d["sync_task_name"] ?? "",
                                                     enabled: (d["sync_task_status"] ?? "") == "1"),
                                    action: nil, keyEquivalent: "")
        let syncSub = NSMenu()
        for (label, cron, name) in [("每小时", "0 * * * *", "每小时全量更新"),
                                    ("每2小时", "0 */2 * * *", "每2小时全量更新"),
                                    ("每4小时", "0 */4 * * *", "每4小时全量更新"),
                                    ("每6小时", "0 */6 * * *", "每6小时全量更新"),
                                    ("每12小时", "0 */12 * * *", "每12小时全量更新"),
                                    ("每天一次（0 点）", "0 0 * * *", "每天全量更新")] {
            let it = NSMenuItem(title: "\(label)（\(cron)）", action: #selector(setSyncCron(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = "\(cron)\t\(name)"
            it.state = cron == syncCron ? .on : .off
            syncSub.addItem(it)
        }
        syncParent.submenu = syncSub
        menu.addItem(syncParent)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("交接导出（打备份包）", action: #selector(doExport)))
        menu.addItem(mkItem("交接导入（选备份包）", action: #selector(doImport)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("退出菜单栏", action: #selector(quit)))
        statusItem.menu = menu
    }

    // 读 batch/log_<N>.txt 里 mtime 最新那份的最后 3 行，解析成 (LogEntry 类型, 显示文本) 列表
    // 返回最新 3 条（最新在最前）；workerN 从文件名提取（log_1.txt → 1）
    private enum LogKind { case added, notFound, paused }
    private struct LogEntry { let kind: LogKind; let text: String }
    private func readLastProcessLog() -> [LogEntry] {
        let logDir = root + "/batch"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logDir) else { return [] }
        var newest: (path: String, mtime: Date)?
        for f in files {
            guard f.hasPrefix("log_") && f.hasSuffix(".txt") else { continue }
            let path = "\(logDir)/\(f)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest!.mtime { newest = (path, mtime) }
        }
        guard let logFile = newest?.path,
              let content = try? String(contentsOf: URL(fileURLWithPath: logFile), encoding: .utf8) else { return [] }
        let lines = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let recent = Array(lines.suffix(3)).reversed()   // 最新 3 条在最前
        let stem = (logFile as NSString).lastPathComponent  // "log_1.txt"
        let workerNum = stem.replacingOccurrences(of: "log_", with: "").replacingOccurrences(of: ".txt", with: "")
        return recent.map { parseProcessLog($0, workerNum: workerNum) }
    }

    // 把"距今多少秒"格式化成 "Ns/N分/Nh/Nd"（<60s→秒；<1h→分；<1d→时；≥1d→天）
    private func formatAge(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)分" }
        let h = m / 60
        if h < 24 { return "\(h)时" }
        let d = h / 24
        return "\(d)天"
    }

    // 文章同步子菜单父项标题 = 现状显示：人类频率 + 原始 cron + 任务名（+ 停用标记）
    private func syncTitle(cron: String, name: String, enabled: Bool) -> String {
        guard !cron.isEmpty else { return "文章同步：未配置定时任务" }
        let human: String
        switch cron {
        case "0 * * * *":   human = "每小时"
        case "0 */2 * * *": human = "每2小时"
        case "0 */4 * * *": human = "每4小时"
        case "0 */6 * * *": human = "每6小时"
        case "0 */12 * * *": human = "每12小时"
        case "0 0 * * *":   human = "每天一次"
        default:            human = cron
        }
        var t = "文章同步：\(human)（\(cron)"
        if !name.isEmpty { t += " · \(name)" }
        return t + (enabled ? "）" : "）· 已停用")
    }

    // 解析一行原始日志 → (类型, "HH:MM workerN 暂停 Xs" / "已添加 name" / "未找到")
    private func parseProcessLog(_ line: String, workerNum: String) -> LogEntry {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return LogEntry(kind: .paused, text: line) }
        let time = String(parts[0]).prefix(5)   // HH:MM（去掉秒）
        let rest = String(parts[1]).trimmingCharacters(in: .whitespaces)
        // [workerN 随机休息 Xs]
        if rest.hasPrefix("[") {
            let pattern = #"\[worker\d+ 随机休息 (\d+)s\]"#
            if let m = rest.range(of: pattern, options: .regularExpression) {
                let secs = rest[m].replacingOccurrences(of: #"\[worker\d+ 随机休息 (\d+)s\]"#, with: "$1", options: .regularExpression)
                return LogEntry(kind: .paused, text: "\(time) worker\(workerNum) 暂停 \(secs)s")
            }
            return LogEntry(kind: .paused, text: "\(time) worker\(workerNum) \(rest)")
        }
        // C0xxxx|已添加|name / C0xxxx|未找到|尝试:...
        let fields = rest.components(separatedBy: "|")
        if fields.count >= 3 {
            if fields[1] == "已添加" { return LogEntry(kind: .added, text: "\(time) worker\(workerNum) 已添加 \(fields[2])") }
            if fields[1] == "未找到" {
                // fields[2] 形如 "尝试:kw1;kw2;kw3;..." —— 拆出关键字，前 3 个用 " / " 连接，超出用 …
                let raw = fields[2]
                let stripped = raw.hasPrefix("尝试:") ? String(raw.dropFirst("尝试:".count)) : raw
                let kws = stripped.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let show = kws.prefix(3).joined(separator: " / ")
                let suffix = kws.count > 3 ? "…" : ""
                let kwStr = show.isEmpty ? "" : " 尝试: \(show)\(suffix)"
                return LogEntry(kind: .notFound, text: "\(time) worker\(workerNum) 未找到\(kwStr)")
            }
        }
        return LogEntry(kind: .paused, text: "\(time) worker\(workerNum) \(rest)")
    }

    // 把一条日志条目渲染成 NSAttributedString：前面加一个小小的右箭头 ▸（8pt tertiaryLabelColor，提示这是日志条目，不抢眼）
    private func makeLogAttributedString(_ entry: LogEntry) -> NSAttributedString {
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let arrowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "› ", attributes: arrowAttrs))   // 线性右箭头 + 空格
        result.append(NSAttributedString(string: entry.text, attributes: textAttrs))
        return result
    }
    @objc func openReview() { ReviewWindowController.shared.show() }
    @objc func openLogs() { LogsWindowController.shared.show() }
    @objc func openAdmin() { runSh("open http://localhost:8001/") }
    @objc func openScan() {
        statusItem.button?.title = "ego ⏳"
        // 立刻把 ego 拉到前台，避免脚本跑 5-30 秒期间用户看不到任何变化
        runSh("open -a 'ego lite' 2>/dev/null")
        runShCapture("bash '\(root)/bin/open_scan_page.sh'", timeout: 120) { [weak self] _ in
            // 脚本结束时再激活一次 ego，确保扫码窗口抢到焦点
            runSh("open -a 'ego lite' 2>/dev/null")
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    // 微信主授权（公众号搜索/添加通道）扫码页——与微信读书扫码页是两个不同页面
    @objc func openWxScan() {
        statusItem.button?.title = "ego ⏳"
        runSh("open -a 'ego lite' 2>/dev/null")
        runShCapture("bash '\(root)/bin/open_scan_page.sh' --wx", timeout: 120) { [weak self] _ in
            runSh("open -a 'ego lite' 2>/dev/null")
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    @objc func runKeepalive() { runSh("bash '\(root)/bin/keepalive.sh'") }

    // 子菜单选中新频率：article_sync_cron.sh 经官方 API 改任务 cron 并重载调度器，完成后立刻刷新状态行勾选
    @objc func setSyncCron(_ sender: NSMenuItem) {
        guard let rep = sender.representedObject as? String else { return }
        let parts = rep.components(separatedBy: "\t")
        guard parts.count >= 2 else { return }
        statusItem.button?.title = "werss ⏳"
        runShCapture("bash '\(root)/bin/article_sync_cron.sh' set '\(parts[0])' '\(parts[1])'", timeout: 60) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    @objc func doExport() { NSWorkspace.shared.open(rootURL.appendingPathComponent("交接导出.command")) }
    @objc func doImport() { NSWorkspace.shared.open(rootURL.appendingPathComponent("交接导入.command")) }
    /// 退出菜单栏 = 本项目相关服务（采集 runner、we-mp-rss 容器）用户都不再需要了
    /// （2026-10-08 用户定规则：「关闭 menubar icon 意味着这件事相关的服务我都不再需要了」）。
    /// 派发停服后立即退出 UI；stop.sh 在后台收尾（compose stop 只停不删，数据全在 bind mount）。
    /// 刻意不挂 applicationWillTerminate：那会让崩溃路径也停服，而崩溃时 launchd
    /// （KeepAlive SuccessfulExit=false）会自动拉回菜单栏，服务本就该继续。
    @objc func quit() {
        runSh("bash '\(root)/bin/stop.sh' >> '\(root)/logs/stop.log' 2>&1")
        NSApplication.shared.terminate(nil)
    }
}

// 入口（多文件编译不能用顶层表达式，@main 是标准方式）
@main
struct WERSSMenubarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
