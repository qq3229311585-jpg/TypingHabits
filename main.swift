import SwiftUI
import Charts
import AppKit
import CoreGraphics

// MARK: - 数据模型
struct VoiceSession: Codable { var start: Date; var dur: Double; var app: String }
struct VoiceStats: Codable {
    var count = 0
    var seconds = 0.0
    var longest = 0.0
    var hourlySec = [Double](repeating: 0, count: 24)
    var appSec: [String: Double] = [:]
    var sessions: [VoiceSession] = []
}
func durStr(_ sec: Double) -> String {
    let t = Int(sec)
    if t >= 3600 { return "\(t / 3600)时\(t % 3600 / 60)分" }
    if t >= 60 { return "\(t / 60)分\(t % 60)秒" }
    return "\(t)秒"
}

struct SessionStats: Codable {
    var voice: VoiceStats?
    var v: VoiceStats { get { voice ?? VoiceStats() } set { voice = newValue } }
    var total = 0
    var hourly = [Int](repeating: 0, count: 24)
    var categories: [String: Int] = [:]
    var apps: [String: Int] = [:]
    var appChars: [String: Int] = [:]
    var minuteKeys: [Int: Int] = [:]
    var intervals = [Int](repeating: 0, count: 7)
    var keyCounts: [String: Int] = [:]
    var shortcuts: [String: Int] = [:]
    var pairLat: [String: [Double]] = [:]   // 相邻两键 -> [总毫秒, 次数]
    var errorKeys: [String: Int] = [:]      // 紧接着被退格删掉的那个键
    var words: [String: Int] = [:]          // 连续字母串(英文词/拼音)
    var mouseClicks = 0
    var appSwitches = 0
    var pauses = 0                          // 间隔>2s的停顿次数
    var longestPause = 0.0                  // 最长停顿(秒,<10分钟的算思考停顿)
    var longestBurst = 0
    var firstKey: Date?
    var lastKey: Date?
}
struct Saved: Codable { var start: Date; var stats: SessionStats; var finished: Bool; var accum: Double?; var began: Bool? }

let intervalLabels = ["<100", "100-150", "150-200", "200-300", "300-500", "0.5-1s", "1-2s"]
let intervalEdges: [Double] = [0.1, 0.15, 0.2, 0.3, 0.5, 1.0, 2.0]
let charCats = ["字母", "数字", "标点符号", "空格"]
let specialNames: [Int64: String] = [51: "⌫", 117: "⌦", 36: "↩", 76: "⌤", 49: "␣", 48: "⇥", 53: "⎋",
    123: "←", 124: "→", 125: "↓", 126: "↑", 57: "⇪"]

// MARK: - 采集 + 存储
final class Store: ObservableObject {
    @Published var stats = SessionStats()
    @Published var hasPermission = false
    @Published var running = false
    @Published var began = false
    var accum = 0.0
    var runStart: Date?
    var started = false
    @Published var recentCPM = 0
    var sessionStart = Date()
    var elapsed: Double { accum + (runStart.map { Date().timeIntervalSince($0) } ?? 0) }
    static let maxSeconds = 24.0 * 3600
    private var recent: [Date] = []
    private var lastKeyTime: Date?
    private var lastLabel = ""
    private var lastWasBack = false
    private var lastApp = ""
    private var burst = 0
    private var wordBuf = ""
    private var tap: CFMachPort?
    private var fnDownAt: Date?
    private var fnCancelled = false
    private var voiceActive: Date?
    private var lastTap: Date?
    @Published var voiceMode = UserDefaults.standard.integer(forKey: "voiceMode") {
        didSet { UserDefaults.standard.set(voiceMode, forKey: "voiceMode"); voiceActive = nil; lastTap = nil }
    }
    var voiceLive: Date? { voiceMode == 0 ? fnDownAt : voiceActive }
    private var dirty = false
    private var raw: FileHandle?

    static var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TypingHabits")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }
    var metaURL: URL { Store.dir.appendingPathComponent("session.json") }
    var rawURL: URL { Store.dir.appendingPathComponent("raw.jsonl") }

    // 启动 App 只加载数据,不会自动开始记录
    func start() {
        if started { return }
        started = true
        if let d = try? Data(contentsOf: metaURL), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            sessionStart = s.start; stats = s.stats
            accum = s.accum ?? 0; began = s.began ?? (s.stats.total > 0)
        }
        hasPermission = CGPreflightListenEventAccess()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.save() }
    }

    func begin() {
        if running { return }
        if !began { sessionStart = Date(); began = true }
        running = true; runStart = Date(); dirty = true
        if raw == nil { openRaw() }
        installTap(); save()
    }

    func stop() {
        guard running else { return }
        accum = elapsed; runStart = nil; running = false
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
        flushWord(); fnDownAt = nil; voiceActive = nil; lastTap = nil; lastKeyTime = nil
        dirty = true; save()
        try? raw?.close(); raw = nil
        objectWillChange.send()
    }

    func openRaw() {
        if !FileManager.default.fileExists(atPath: rawURL.path) {
            FileManager.default.createFile(atPath: rawURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        raw = try? FileHandle(forWritingTo: rawURL)
        _ = try? raw?.seekToEnd()
    }
    func log(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        raw?.write(d); raw?.write(Data([10]))
    }

    func installTap() {
        if tap != nil || !running { return }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<Store>.fromOpaque(refcon!).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            case .keyDown: me.handleKey(event)
            case .flagsChanged: me.handleFlags(event)
            case .leftMouseDown, .rightMouseDown: me.handleClick()
            default: break
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            hasPermission = false; return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        hasPermission = true
    }

    func handleFlags(_ e: CGEvent) {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        guard code == 63 || code == 179 else { return }
        let now = Date()
        if elapsed >= Store.maxSeconds { stop(); return }
        if e.flags.contains(.maskSecondaryFn) { fnDownAt = now; fnCancelled = false; return }
        guard let d = fnDownAt else { return }
        fnDownAt = nil
        if fnCancelled { return }
        let hold = now.timeIntervalSince(d)
        if let a = voiceActive, now.timeIntervalSince(a) > 900 { voiceActive = nil }
        switch voiceMode {
        case 0: if hold >= 0.3 { recordVoice(d, now) }
        case 1:
            if hold < 0.8 {
                if let a = voiceActive { recordVoice(a, now); voiceActive = nil } else { voiceActive = now }
            }
        default:
            if hold < 0.8 {
                if let a = voiceActive { recordVoice(a, now); voiceActive = nil }
                else if let lt = lastTap, now.timeIntervalSince(lt) < 0.6 { voiceActive = now; lastTap = nil }
                else { lastTap = now }
            }
        }
    }

    func recordVoice(_ start: Date, _ end: Date) {
        let dur = end.timeIntervalSince(start)
        guard dur >= 0.3, dur <= 1800 else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
        let h = Calendar.current.component(.hour, from: start)
        var v = stats.v
        v.count += 1; v.seconds += dur; v.longest = max(v.longest, dur)
        v.hourlySec[h] += dur; v.appSec[app, default: 0] += dur
        v.sessions.append(VoiceSession(start: start, dur: dur, app: app))
        stats.v = v; dirty = true
        log(["t": Int(start.timeIntervalSince1970 * 1000), "type": "voice", "dur": dur, "app": app])
        objectWillChange.send()
    }

    func handleClick() {
        stats.mouseClicks += 1; dirty = true
        log(["t": Int(Date().timeIntervalSince1970 * 1000), "type": "click", "app": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])
    }

    func flushWord() {
        if wordBuf.count >= 2 { stats.words[wordBuf, default: 0] += 1 }
        wordBuf = ""
    }

    func handleKey(_ e: CGEvent) {
        if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        if fnDownAt != nil { fnCancelled = true }
        let now = Date()
        if elapsed >= Store.maxSeconds { stop(); return }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let flags = e.flags
        var mods = ""
        if flags.contains(.maskControl) { mods += "⌃" }
        if flags.contains(.maskAlternate) { mods += "⌥" }
        if flags.contains(.maskShift) { mods += "⇧" }
        if flags.contains(.maskCommand) { mods += "⌘" }
        var len = 0; var buf = [UniChar](repeating: 0, count: 4)
        e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        let ch = len > 0 ? String(utf16CodeUnits: buf, count: len) : ""
        let isShortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)

        // 分类
        var cat = "其他"
        if code == 51 || code == 117 { cat = "退格/删除" }
        else if code == 36 || code == 76 { cat = "回车" }
        else if code == 49 { cat = "空格" }
        else if code == 48 { cat = "Tab" }
        else if code == 53 { cat = "Esc" }
        else if (123...126).contains(code) { cat = "方向键" }
        else if isShortcut { cat = "快捷键" }
        else if let s = ch.unicodeScalars.first {
            if CharacterSet.letters.contains(s) { cat = "字母" }
            else if CharacterSet.decimalDigits.contains(s) { cat = "数字" }
            else if !CharacterSet.controlCharacters.contains(s) { cat = "标点符号" }
        }
        let label = specialNames[code] ?? (ch.isEmpty ? "key\(code)" : ch.uppercased())
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let h = c.hour ?? 0, m = h * 60 + (c.minute ?? 0)

        log(["t": Int(now.timeIntervalSince1970 * 1000), "type": "key", "app": app, "key": label, "mods": mods, "code": code])

        stats.total += 1
        stats.hourly[h] += 1
        stats.categories[cat, default: 0] += 1
        stats.apps[app, default: 0] += 1
        if !lastApp.isEmpty && lastApp != app { stats.appSwitches += 1 }
        lastApp = app
        if stats.firstKey == nil { stats.firstKey = now }
        stats.lastKey = now
        if charCats.contains(cat) { stats.minuteKeys[m, default: 0] += 1; stats.appChars[app, default: 0] += 1; recent.append(now) }
        if cat != "退格/删除" && cat != "其他" { stats.keyCounts[isShortcut ? mods + label : label, default: 0] += 1 }
        if isShortcut { stats.shortcuts[mods + label, default: 0] += 1 }

        // 错误习惯:第一个退格之前的那个键
        if cat == "退格/删除" {
            if !lastWasBack && !lastLabel.isEmpty { stats.errorKeys[lastLabel, default: 0] += 1 }
            if !wordBuf.isEmpty { wordBuf.removeLast() }
        }
        lastWasBack = (cat == "退格/删除")

        // 词
        if cat == "字母" { wordBuf += ch.lowercased() } else if cat != "退格/删除" { flushWord() }

        // 间隔、停顿、相邻键延迟
        if let last = lastKeyTime {
            let dt = now.timeIntervalSince(last)
            if dt < 2.0 {
                stats.intervals[intervalEdges.firstIndex { dt < $0 } ?? 6] += 1
                burst += 1; stats.longestBurst = max(stats.longestBurst, burst)
                if dt < 1.0, label.count == 1, lastLabel.count == 1, !isShortcut {
                    var p = stats.pairLat[lastLabel + label] ?? [0, 0]
                    p[0] += dt * 1000; p[1] += 1; stats.pairLat[lastLabel + label] = p
                }
            } else {
                burst = 1; stats.pauses += 1
                if dt < 600 { stats.longestPause = max(stats.longestPause, dt) }
            }
        } else { burst = 1 }
        lastKeyTime = now; lastLabel = (cat == "退格/删除" || cat == "快捷键") ? "" : label
        if cat == "退格/删除" { lastLabel = "" }
        dirty = true
        objectWillChange.send()
    }

    func tick() {
        recent.removeAll { $0 < Date().addingTimeInterval(-60) }
        recentCPM = recent.count
        if running && elapsed >= Store.maxSeconds { stop() }
        if running && !hasPermission { installTap() }
        objectWillChange.send()
    }

    func save() {
        guard dirty else { return }
        if let d = try? JSONEncoder().encode(Saved(start: sessionStart, stats: stats, finished: false, accum: elapsed, began: began)) {
            try? d.write(to: metaURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
        }
        dirty = false
    }

    func resetAll() {
        stop()
        try? FileManager.default.removeItem(at: rawURL)
        try? FileManager.default.removeItem(at: metaURL)
        stats = SessionStats(); began = false; accum = 0; runStart = nil; running = false; sessionStart = Date()
        lastKeyTime = nil; wordBuf = ""; fnDownAt = nil; voiceActive = nil; lastTap = nil; dirty = true; save()
    }

    // MARK: 导出
    func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map { f in
            (f.contains(",") || f.contains("\"") || f.contains("\n")) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
    func exportAll() {
        save()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "导出到此文件夹"; panel.message = "选择导出位置,会在里面新建一个 TypingHabits-导出 文件夹"
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let out = base.appendingPathComponent("TypingHabits-导出-" + f.string(from: Date()))
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func w(_ name: String, _ rows: [[String]]) {
            // 加 BOM,Excel 打开中文不乱码
            try? ("\u{FEFF}" + csv(rows)).write(to: out.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let s = stats
        w("概览.csv", [["指标", "值"],
            ["开始时间", ISO8601DateFormatter().string(from: sessionStart)],
            ["总按键", "\(s.total)"], ["字符键", "\(chars)"],
            ["平均速度WPM", String(format: "%.1f", avgWPM)], ["活跃分钟", "\(activeMinutes)"],
            ["退格率", String(format: "%.4f", backspaceRate)], ["平均按键间隔ms", "\(avgInterval)"],
            ["最长连续输入", "\(s.longestBurst)"], ["停顿次数", "\(s.pauses)"], ["最长思考停顿秒", String(format: "%.1f", s.longestPause)],
            ["语音次数", "\(s.v.count)"], ["语音总秒数", String(format: "%.1f", s.v.seconds)], ["语音最长秒", String(format: "%.1f", s.v.longest)],
            ["鼠标点击", "\(s.mouseClicks)"], ["App切换", "\(s.appSwitches)"]])
        func dict(_ name: String, _ h: String, _ d: [String: Int]) {
            w(name, [[h, "次数"]] + d.sorted { $0.value > $1.value }.map { [$0.key, "\($0.value)"] })
        }
        dict("按键类型.csv", "类型", s.categories); dict("App按键数.csv", "App", s.apps)
        dict("按键频率.csv", "键", s.keyCounts); dict("快捷键.csv", "快捷键", s.shortcuts)
        dict("出错键.csv", "键(之后被退格)", s.errorKeys); dict("词频.csv", "词/拼音串", s.words)
        w("语音记录.csv", [["开始时间", "时长秒", "App"]] + s.v.sessions.map { [ISO8601DateFormatter().string(from: $0.start), String(format: "%.1f", $0.dur), $0.app] })
        w("每小时语音秒数.csv", [["小时", "秒"]] + (0..<24).map { ["\($0)", String(format: "%.1f", s.v.hourlySec[$0])] })
        w("语音App时长.csv", [["App", "秒"]] + s.v.appSec.sorted { $0.value > $1.value }.map { [$0.key, String(format: "%.1f", $0.value)] })
        w("每小时.csv", [["小时", "按键数"]] + (0..<24).map { ["\($0)", "\(s.hourly[$0])"] })
        w("每分钟速度.csv", [["时间", "字符数"]] + s.minuteKeys.sorted { $0.key < $1.key }.map { [hm($0.key), "\($0.value)"] })
        w("按键间隔分布.csv", [["间隔ms", "次数"]] + (0..<7).map { [intervalLabels[$0], "\(s.intervals[$0])"] })
        w("键对延迟.csv", [["键对", "平均ms", "次数"]] + s.pairLat.sorted { $0.value[0] / max($0.value[1], 1) > $1.value[0] / max($1.value[1], 1) }
            .map { [$0.key, String(format: "%.0f", $0.value[0] / max($0.value[1], 1)), String(format: "%.0f", $0.value[1])] })
        // 原始日志:JSONL 原样复制 + CSV
        try? FileManager.default.copyItem(at: rawURL, to: out.appendingPathComponent("原始日志.jsonl"))
        var rows = [["时间", "类型", "App", "键", "修饰键", "keycode"]]
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let txt = try? String(contentsOf: rawURL, encoding: .utf8) {
            for line in txt.split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let t = (o["t"] as? Double ?? 0) / 1000
                rows.append([iso.string(from: Date(timeIntervalSince1970: t)), o["type"] as? String ?? "", o["app"] as? String ?? "",
                             o["key"] as? String ?? "", o["mods"] as? String ?? "", (o["code"] as? Int).map { "\($0)" } ?? ""])
            }
        }
        w("原始日志.csv", rows)
        if let d = try? JSONEncoder().encode(Saved(start: sessionStart, stats: stats, finished: false, accum: elapsed, began: began)) { try? d.write(to: out.appendingPathComponent("完整统计.json")) }
        NSWorkspace.shared.activateFileViewerSelecting([out])
    }

    // 派生指标
    var chars: Int { charCats.reduce(0) { $0 + (stats.categories[$1] ?? 0) } }
    var backspaceRate: Double { chars == 0 ? 0 : Double(stats.categories["退格/删除"] ?? 0) / Double(chars) }
    var activeMinutes: Int { stats.minuteKeys.values.filter { $0 > 0 }.count }
    var avgWPM: Double { activeMinutes == 0 ? 0 : Double(chars) / Double(activeMinutes) / 5 }
    var peak: (minute: Int, n: Int)? { stats.minuteKeys.max { $0.value < $1.value }.map { ($0.key, $0.value) } }
    var avgInterval: Int {
        let mids: [Double] = [75, 125, 175, 250, 400, 750, 1500]
        let n = stats.intervals.reduce(0, +); if n == 0 { return 0 }
        return Int(zip(stats.intervals, mids).reduce(0) { $0 + Double($1.0) * $1.1 } / Double(n))
    }
    var elapsedStr: String {
        let t = Int(elapsed)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

// MARK: - 界面
struct Card: View {
    let title: String, value: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
func tm(_ d: Date?) -> String { d.map { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); return hm((c.hour ?? 0) * 60 + (c.minute ?? 0)) } ?? "-" }

struct BarList: View {
    let title: String; let data: [(String, Int)]; var color: Color = .blue
    var body: some View {
        GroupBox(title) {
            if data.isEmpty { Text("暂无数据").foregroundStyle(.secondary).frame(height: 200) }
            else {
                Chart(data, id: \.0) { kv in
                    BarMark(x: .value("次", kv.1), y: .value("项", kv.0)).foregroundStyle(color)
                        .annotation(position: .trailing) { Text("\(kv.1)").font(.caption2) }
                }.chartYScale(domain: data.map { $0.0 }).frame(height: max(120, CGFloat(data.count) * 24))
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    var body: some View {
        let s = store.stats
        let topKeys = s.keyCounts.sorted { $0.value > $1.value }.prefix(15).map { ($0.key, $0.value) }
        let topWords = s.words.sorted { $0.value > $1.value }.prefix(15).map { ($0.key, $0.value) }
        let slow = s.pairLat.filter { $0.value[1] >= 8 }.map { ($0.key, Int($0.value[0] / $0.value[1])) }.sorted { $0.1 > $1.1 }.prefix(10).map { ($0.0, $0.1) }
        let err = s.errorKeys.sorted { $0.value > $1.value }.prefix(10).map { ($0.key, $0.value) }
        let sc = s.shortcuts.sorted { $0.value > $1.value }.prefix(10).map { ($0.key, $0.value) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("打字与语音习惯").font(.title2.bold())
                    Spacer()
                    Button { store.exportAll() } label: { Label("导出数据", systemImage: "square.and.arrow.up") }
                    if store.running {
                        Label("记录中 · 已记 \(store.elapsedStr)", systemImage: "record.circle").foregroundStyle(.green)
                        Button { store.stop() } label: { Label("结束记录", systemImage: "stop.fill") }.tint(.red).buttonStyle(.borderedProminent)
                    } else {
                        Label(store.began ? "已结束 · 共记 \(store.elapsedStr)" : "未开始", systemImage: store.began ? "checkmark.circle" : "pause.circle")
                            .foregroundStyle(store.began ? .blue : .secondary)
                        Button { store.begin() } label: { Label(store.began ? "继续记录" : "开始记录", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                    }
                }
                if store.running && !store.hasPermission {
                    Text("需要授权:系统设置 → 隐私与安全性 → 输入监控,勾选 TypingHabits,然后重启本 App。").font(.callout)
                        .padding(10).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("数据只存在本机 ~/Library/Application Support/TypingHabits/,累计记录满 24 小时会自动停止。点「开始/结束」随时控制。密码框等系统安全输入不会被记录。").font(.caption).foregroundStyle(.secondary)

                GroupBox("语音输入(Fn 键)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("你的 Fn 语音方式").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $store.voiceMode) {
                                Text("按住说话").tag(0); Text("单击开始/再单击结束").tag(1); Text("双击开始/单击结束").tag(2)
                            }.pickerStyle(.segmented).labelsHidden()
                            if let t = store.voiceLive { TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Label("录音中 " + durStr(Date().timeIntervalSince(t)), systemImage: "mic.fill").foregroundStyle(.red).font(.caption) } }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                            Card(title: "语音次数", value: "\(s.v.count)", sub: "每次按Fn说话算一次")
                            Card(title: "语音总时长", value: durStr(s.v.seconds), sub: "")
                            Card(title: "平均每次", value: s.v.count == 0 ? "-" : durStr(s.v.seconds / Double(s.v.count)), sub: "")
                            Card(title: "最长一次", value: durStr(s.v.longest), sub: "")
                        }
                        Chart(0..<24, id: \.self) { h in BarMark(x: .value("时", h), y: .value("分钟", s.v.hourlySec[h] / 60)).foregroundStyle(.pink) }
                            .chartXScale(domain: -0.5...23.5).chartXAxis { AxisMarks(values: .stride(by: 3)) }.frame(height: 110)
                        Text("说话的文字内容系统听写直接插入输入框,不经过键盘事件,本 App 抓不到,这里只记时长。").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    Card(title: "总按键", value: "\(s.total)", sub: "字符键 \(store.chars)")
                    Card(title: "实时速度", value: "\(store.recentCPM)", sub: "字符/分钟(近60秒)")
                    Card(title: "平均速度", value: String(format: "%.0f WPM", store.avgWPM), sub: "活跃 \(store.activeMinutes) 分钟")
                    Card(title: "退格率", value: String(format: "%.1f%%", store.backspaceRate * 100), sub: "退格 ÷ 字符键")
                    Card(title: "平均按键间隔", value: "\(store.avgInterval) ms", sub: "连续输入时")
                    Card(title: "最长连续输入", value: "\(s.longestBurst) 键", sub: "中间无>2秒停顿")
                    Card(title: "峰值分钟", value: store.peak.map { "\($0.n) 字符" } ?? "-", sub: store.peak.map { "出现在 \(hm($0.minute))" } ?? "")
                    Card(title: "停顿次数", value: "\(s.pauses)", sub: "最长思考停顿 \(Int(s.longestPause)) 秒")
                    Card(title: "鼠标点击", value: "\(s.mouseClicks)", sub: "键鼠比 " + (s.mouseClicks == 0 ? "-" : String(format: "%.1f : 1", Double(s.total) / Double(s.mouseClicks))))
                    Card(title: "App 切换", value: "\(s.appSwitches)", sub: "按键期间前台切换")
                    Card(title: "首次按键", value: tm(s.firstKey), sub: "")
                    Card(title: "最近按键", value: tm(s.lastKey), sub: "")
                }

                GroupBox("每小时按键量") {
                    Chart(0..<24, id: \.self) { h in BarMark(x: .value("时", h), y: .value("次", s.hourly[h])) }
                        .chartXScale(domain: -0.5...23.5).chartXAxis { AxisMarks(values: .stride(by: 3)) }.frame(height: 150)
                }
                GroupBox("速度时间线(每分钟字符数)") {
                    let pts = s.minuteKeys.sorted { $0.key < $1.key }
                    Chart(pts, id: \.key) { kv in PointMark(x: .value("分钟", kv.key), y: .value("字符", kv.value)).symbolSize(12) }
                        .chartXScale(domain: 0...1440).chartXAxis {
                            AxisMarks(values: .stride(by: 180)) { v in
                                AxisGridLine(); AxisValueLabel { if let m = v.as(Int.self) { Text(hm(m)) } }
                            }
                        }.frame(height: 140)
                }
                HStack(alignment: .top, spacing: 12) {
                    BarList(title: "按键类型", data: s.categories.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
                    BarList(title: "常用 App(按键数)", data: s.apps.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }, color: .teal)
                }
                HStack(alignment: .top, spacing: 12) {
                    BarList(title: "最常按的键", data: Array(topKeys), color: .indigo)
                    BarList(title: "最常打的词/拼音串", data: Array(topWords), color: .purple)
                }
                HStack(alignment: .top, spacing: 12) {
                    BarList(title: "最容易出错的键(紧接着被退格)", data: Array(err), color: .red)
                    BarList(title: "最慢的键对(平均 ms)", data: Array(slow), color: .orange)
                }
                HStack(alignment: .top, spacing: 12) {
                    BarList(title: "常用快捷键", data: Array(sc), color: .green)
                    GroupBox("按键间隔分布(ms)") {
                        Chart(0..<7, id: \.self) { i in BarMark(x: .value("间隔", intervalLabels[i]), y: .value("次", s.intervals[i])).foregroundStyle(.orange) }
                            .frame(height: 200)
                    }
                }
            }.padding(20)
        }
        .frame(minWidth: 820, minHeight: 700)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

@main
struct TypingHabitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store()
    var body: some Scene {
        Window("打字习惯", id: "main") {
            ContentView(store: store).onAppear { store.start() }
        }
        MenuBarExtra {
            Text("\(store.stats.total) 键 · 语音 \(durStr(store.stats.v.seconds)) · 退格率 " + String(format: "%.1f%%", store.backspaceRate * 100) + " · " + (store.running ? "记录中 \(store.elapsedStr)" : "未在记录"))
            Divider()
            if store.running { Button("结束记录") { store.stop() } } else { Button(store.began ? "继续记录" : "开始记录") { store.begin() } }
            Button("导出数据…") { store.exportAll() }
            Button("清空数据,重新来过") { store.resetAll() }
            Button("退出(保存数据)") { store.save(); NSApp.terminate(nil) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.running ? "record.circle" : "keyboard")
                Text("\(store.stats.total)")
                Image(systemName: "waveform")
                Text(durStr(store.stats.v.seconds))
            }
        }
    }
}
