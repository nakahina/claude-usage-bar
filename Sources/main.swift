import AppKit
import Foundation
import ServiceManagement
import UserNotifications

// MARK: - 設定（必要に応じてここの数値を変えてビルドし直せます）

enum Config {
    /// 使用量API（/usage と同じデータ）の取得間隔。短くしすぎるとレート制限されるため3分以上を推奨
    static let apiPollInterval: TimeInterval = 300
    /// 使用量（5時間枠・週間）の通知しきい値（%）
    static let usageThresholds: [Double] = [80, 95, 100]

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"
}

// MARK: - データ型

struct UsageWindow {
    let utilization: Double
    let resetsAt: Date?
}

struct ExtraUsage {
    let isEnabled: Bool
    let usedCredits: Double
    let monthlyLimit: Double?
}

struct UsageData {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var sevenDaySonnet: UsageWindow?
    var sevenDayOpus: UsageWindow?
    var sevenDayCowork: UsageWindow?
    var extra: ExtraUsage?
    var fetchedAt: Date
}

// MARK: - 日付ユーティリティ

enum Dates {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? isoFractional.date(from: s)
    }

    static func display(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "H:mm"
            return "今日 " + f.string(from: date)
        }
        f.dateFormat = "M/d(E) H:mm"
        return f.string(from: date)
    }
}

// MARK: - パネル用の部品ビュー

/// 上が原点になる座標系（frameベースのレイアウトを書きやすくするため）
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 円形のリングゲージ（12時位置から時計回りに使用率を描く）
/// このビュー自身はflippedにしない（NSBezierPathの角度計算を標準の座標系のまま使うため）
private final class RingGaugeView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var ringColor: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 7

    override func draw(_ dirtyRect: NSRect) {
        let inset = lineWidth / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        track.stroke()

        let clamped = max(0, min(1, value))
        guard clamped > 0 else { return }

        let progress = NSBezierPath()
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        if clamped >= 0.999 {
            progress.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        } else {
            let sweep = 360 * clamped
            progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        }
        ringColor.setStroke()
        progress.stroke()
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var usage: UsageData?
    private var lastError: String?
    private var backoffUntil: Date?

    private var apiTimer: Timer?

    private let defaults = UserDefaults.standard
    private let notifiedKeysKey = "notifiedKeys"

    // MARK: 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Claude 使用量モニター"
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.title = "…"

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        pruneNotifiedKeys()
        rebuildMenu()

        apiTimer = Timer.scheduledTimer(withTimeInterval: Config.apiPollInterval, repeats: true) { [weak self] _ in
            self?.fetchUsage()
        }
        apiTimer?.tolerance = 30

        fetchUsage()
    }

    // 前面にいなくても通知バナーを表示する
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: メニューバー表示

    private func color(for percent: Double) -> NSColor {
        if percent >= 80 { return .systemRed }
        if percent >= 50 { return .systemOrange }
        return .systemGreen
    }

    private func titleFont(_ weight: NSFont.Weight = .semibold) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 12, weight: weight)
    }

    private func segment(_ label: String, _ percent: Double) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "\(label) ", attributes: [
            .foregroundColor: NSColor.white,
            .font: titleFont(.regular),
        ])
        // 100%以上（上限到達・超過）は数字だけでなく警告マークでも一目でわかるようにする
        let isOver = percent >= 100
        let numberText = isOver ? "⚠\(Int(percent.rounded()))%" : "\(Int(percent.rounded()))%"
        s.append(NSAttributedString(string: numberText, attributes: [
            .foregroundColor: color(for: percent),
            .font: titleFont(isOver ? .bold : .semibold),
        ]))
        return s
    }

    private func updateTitle() {
        guard let usage else {
            let placeholder = NSMutableAttributedString(string: "Claude ", attributes: [
                .foregroundColor: brandColor,
                .font: titleFont(.semibold),
            ])
            placeholder.append(NSAttributedString(string: "--", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: titleFont(.regular),
            ]))
            statusItem.button?.attributedTitle = placeholder
            return
        }
        let five = usage.fiveHour?.utilization ?? 0
        let week = max(usage.sevenDay?.utilization ?? 0,
                       usage.sevenDaySonnet?.utilization ?? 0,
                       usage.sevenDayOpus?.utilization ?? 0,
                       usage.sevenDayCowork?.utilization ?? 0)

        let title = NSMutableAttributedString(string: "Claude ", attributes: [
            .foregroundColor: brandColor,
            .font: titleFont(.semibold),
        ])
        title.append(segment("5h", five))
        title.append(NSAttributedString(string: " | ", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: titleFont(.regular),
        ]))
        title.append(segment("W", week))
        statusItem.button?.attributedTitle = title
    }

    // MARK: 認証トークン

    /// Claude Codeが保存した認証情報を読む（キーチェーン → ファイルの順）。
    /// 初回はmacOSがキーチェーンへのアクセス許可を求めるので「常に許可」を選ぶ。
    private func readAccessToken() -> String? {
        if let json = keychainCredentials() ?? fileCredentials(),
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String {
            return token
        }
        return nil
    }

    private func keychainCredentials() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", Config.keychainService, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func fileCredentials() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: 使用量APIの取得

    @objc func fetchUsage() {
        if let until = backoffUntil, Date() < until { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let token = self.readAccessToken() else {
                DispatchQueue.main.async {
                    self.lastError = "認証情報が見つかりません。Claude Codeを一度起動してログインしてください。"
                    self.updateTitle()
                    self.rebuildMenu()
                }
                return
            }

            var req = URLRequest(url: Config.usageURL)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20

            URLSession.shared.dataTask(with: req) { data, response, error in
                DispatchQueue.main.async {
                    self.handleUsageResponse(data: data, response: response, error: error)
                }
            }.resume()
        }
    }

    private func handleUsageResponse(data: Data?, response: URLResponse?, error: Error?) {
        defer {
            updateTitle()
            rebuildMenu()
        }
        if let error {
            lastError = "通信エラー: \(error.localizedDescription)"
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200:
            break
        case 401:
            lastError = "認証の期限切れです。Claude Codeを一度起動すると自動で更新されます。"
            return
        case 429:
            lastError = "取得間隔の制限中です。しばらくすると自動で再開します。"
            backoffUntil = Date().addingTimeInterval(15 * 60)
            return
        default:
            lastError = "サーバーエラー（\(http.statusCode)）"
            return
        }
        guard let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            lastError = "応答を解析できませんでした"
            return
        }

        func window(_ key: String) -> UsageWindow? {
            guard let obj = json[key] as? [String: Any],
                  let util = (obj["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (obj["resets_at"] as? String).flatMap(Dates.parse)
            return UsageWindow(utilization: util, resetsAt: resets)
        }
        var extra: ExtraUsage?
        if let e = json["extra_usage"] as? [String: Any] {
            // APIはセント単位（1/100ドル）で返すため、ドル表示にするには100で割る
            let rawCredits = (e["used_credits"] as? NSNumber)?.doubleValue ?? 0
            let rawLimit = (e["monthly_limit"] as? NSNumber)?.doubleValue
            extra = ExtraUsage(
                isEnabled: (e["is_enabled"] as? Bool) ?? false,
                usedCredits: rawCredits / 100,
                monthlyLimit: rawLimit.map { $0 / 100 }
            )
        }

        usage = UsageData(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            sevenDaySonnet: window("seven_day_sonnet"),
            sevenDayOpus: window("seven_day_opus"),
            sevenDayCowork: window("seven_day_cowork"),
            extra: extra,
            fetchedAt: Date()
        )
        lastError = nil
        checkUsageAlerts()
    }

    // MARK: 使用量アラート

    private func checkUsageAlerts() {
        guard let usage else { return }

        checkWindow(usage.fiveHour, label: "5時間枠", keyPrefix: "5h",
                    limitHitBody: "これ以降の利用は追加課金（従量課金）になるか、リセットまで待つ必要があります。")
        checkWindow(usage.sevenDay, label: "週間制限", keyPrefix: "7d",
                    limitHitBody: "今週の上限に達しました。これ以降の利用は追加課金になる可能性があります。")
        checkWindow(usage.sevenDaySonnet, label: "週間制限（Sonnet）", keyPrefix: "7ds",
                    limitHitBody: "Sonnetの週間上限に達しました。")
        checkWindow(usage.sevenDayOpus, label: "週間制限（Opus）", keyPrefix: "7do",
                    limitHitBody: "Opusの週間上限に達しました。")
        checkWindow(usage.sevenDayCowork, label: "週間制限（Cowork）", keyPrefix: "7dc",
                    limitHitBody: "Coworkの週間上限に達しました。")

        if let extra = usage.extra, extra.usedCredits > 0 {
            let month = Calendar.current.dateComponents([.year, .month], from: Date())
            let key = "extra-\(month.year ?? 0)-\(month.month ?? 0)"
            let amount = String(format: "$%.2f", extra.usedCredits)
            notifyOnce(key: key,
                       title: "⚠️ Claude: 追加課金（従量課金）が発生しています",
                       body: "今月の追加使用額: \(amount)。制限のリセットを待ってから使うと追加課金を避けられます。",
                       sound: true)
        }
    }

    private func checkWindow(_ w: UsageWindow?, label: String, keyPrefix: String, limitHitBody: String) {
        guard let w else { return }
        let resetText = w.resetsAt.map { "リセット: \(Dates.display($0))" } ?? ""
        // リセット時刻ごとに1回だけ通知する（次の窓では再度通知される）
        let windowId = w.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "static"

        for threshold in Config.usageThresholds where w.utilization >= threshold {
            let key = "\(keyPrefix)-\(Int(threshold))-\(windowId)"
            switch threshold {
            case 100:
                notifyOnce(key: key,
                           title: "🚨 Claude: \(label)の上限に達しました",
                           body: "\(limitHitBody) \(resetText)",
                           sound: true)
            case 95:
                notifyOnce(key: key,
                           title: "🔴 Claude: \(label)が残りわずかです（\(Int(w.utilization))%）",
                           body: "まもなく上限です。急ぎでない作業はリセット後にしましょう。\(resetText)",
                           sound: true)
            default:
                notifyOnce(key: key,
                           title: "🟡 Claude: \(label)を\(Int(threshold))%使いました",
                           body: "残量に注意しましょう。\(resetText)",
                           sound: false)
            }
        }
    }

    // MARK: 通知（同じ内容は1回だけ）

    private func notifyOnce(key: String, title: String, body: String, sound: Bool) {
        var notified = (defaults.dictionary(forKey: notifiedKeysKey) as? [String: Double]) ?? [:]
        guard notified[key] == nil else { return }
        notified[key] = Date().timeIntervalSince1970
        defaults.set(notified, forKey: notifiedKeysKey)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func pruneNotifiedKeys() {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600).timeIntervalSince1970
        var notified = (defaults.dictionary(forKey: notifiedKeysKey) as? [String: Double]) ?? [:]
        notified = notified.filter { $0.value > cutoff }
        defaults.set(notified, forKey: notifiedKeysKey)
    }

    // MARK: メニュー

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func item(_ title: String, action: Selector? = nil, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.indentationLevel = indent
        if action == nil { item.isEnabled = false }
        return item
    }

    /// Claudeのブランドカラー（アプリアイコンと同系色）
    private let brandColor = NSColor(calibratedRed: 0.80, green: 0.42, blue: 0.29, alpha: 1.0)

    /// ゲージの色分け。0-70% 緑 / 70-90% 橙 / 90%以上 赤
    private func gaugeColor(for percent: Double) -> NSColor {
        if percent >= 90 { return .systemRed }
        if percent >= 70 { return .systemOrange }
        return .systemGreen
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                        color: NSColor = .labelColor, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        return field
    }

    /// 角丸の背景カード（グルーピング用の薄い塗り）
    @discardableResult
    private func addCard(to container: NSView, frame: NSRect, fillColor: NSColor, cornerRadius: CGFloat = 14) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.backgroundColor = fillColor.cgColor
        container.addSubview(card)
        return card
    }

    /// リング＋中央の%＋タイトル＋リセット時刻の1カラムを、薄いカード背景の上に作る
    @discardableResult
    private func addRingColumn(to container: NSView, x: CGFloat, colWidth: CGFloat, topY: CGFloat,
                                title: String, window: UsageWindow?) -> CGFloat {
        guard let window else { return topY }
        let percent = window.utilization
        let color = gaugeColor(for: percent)
        let diameter: CGFloat = 74

        var contentBottom = topY + diameter + 8 + 15 + 2
        if window.resetsAt != nil { contentBottom += 13 }
        let cardPadding: CGFloat = 12
        let cardFrame = NSRect(x: x - 6, y: topY - cardPadding,
                                width: colWidth + 12, height: (contentBottom - topY) + cardPadding * 2)
        addCard(to: container, frame: cardFrame, fillColor: NSColor.labelColor.withAlphaComponent(0.045))

        let ring = RingGaugeView(frame: NSRect(x: x + (colWidth - diameter) / 2, y: topY, width: diameter, height: diameter))
        ring.value = percent / 100
        ring.ringColor = color
        container.addSubview(ring)

        let isOver = percent >= 100
        let pctText = isOver ? "⚠\(Int(percent.rounded()))%" : "\(Int(percent.rounded()))%"
        let pctLabel = label(pctText, size: isOver ? 15 : 18, weight: .bold, color: color, alignment: .center)
        pctLabel.frame = NSRect(x: x, y: topY + diameter / 2 - 12, width: colWidth, height: 24)
        container.addSubview(pctLabel)

        var y = topY + diameter + 8
        let titleLabel = label(title, size: 11.5, weight: .semibold, alignment: .center)
        titleLabel.frame = NSRect(x: x, y: y, width: colWidth, height: 15)
        container.addSubview(titleLabel)
        y += 15 + 2

        if let resets = window.resetsAt {
            let resetLabel = label("\(Dates.display(resets)) リセット", size: 10, color: .secondaryLabelColor, alignment: .center)
            resetLabel.frame = NSRect(x: x, y: y, width: colWidth, height: 13)
            container.addSubview(resetLabel)
            y += 13
        }
        return y + cardPadding
    }

    /// バーなしの補足1行（Sonnet/Opus/Cowork個別枠など）。色付きの小さな丸で見分けやすくする
    private func addCompactLine(to container: NSView, y: inout CGFloat, width: CGFloat,
                                 text: String, dotColor: NSColor) {
        let dot = NSView(frame: NSRect(x: 20, y: y + 5, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = dotColor.cgColor
        container.addSubview(dot)

        let line = label(text, size: 11.5, color: .secondaryLabelColor)
        line.frame = NSRect(x: 34, y: y, width: width - 34 - 16, height: 16)
        container.addSubview(line)
        y += 16 + 6
    }

    private func buildUsagePanel() -> NSView {
        let width: CGFloat = 300
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 16

        let titleText = NSMutableAttributedString(string: "Claude", attributes: [
            .foregroundColor: brandColor, .font: NSFont.systemFont(ofSize: 16, weight: .bold),
        ])
        titleText.append(NSAttributedString(string: " 使用量", attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 16, weight: .bold),
        ]))
        let title = NSTextField(labelWithAttributedString: titleText)
        title.alignment = .center
        title.frame = NSRect(x: 16, y: y, width: width - 32, height: 22)
        container.addSubview(title)
        y += 22 + 18

        guard let usage else {
            let text = lastError ?? "使用量を取得中…"
            let color: NSColor = lastError == nil ? .secondaryLabelColor : .systemRed
            let loading = label(text, size: 12, color: color, alignment: .center)
            loading.lineBreakMode = .byWordWrapping
            let fitHeight = loading.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 32, height: 80)).height ?? 18
            loading.frame = NSRect(x: 16, y: y, width: width - 32, height: fitHeight)
            container.addSubview(loading)
            y += fitHeight + 16
            container.frame = NSRect(x: 0, y: 0, width: width, height: y)
            return container
        }

        let gap: CGFloat = 20
        let colWidth = (width - 32 - gap) / 2
        let leftX: CGFloat = 16
        let rightX = leftX + colWidth + gap
        let leftBottom = addRingColumn(to: container, x: leftX, colWidth: colWidth, topY: y,
                                        title: "セッション（5時間）", window: usage.fiveHour)
        let rightBottom = addRingColumn(to: container, x: rightX, colWidth: colWidth, topY: y,
                                         title: "週間（7日間）", window: usage.sevenDay)
        y = max(leftBottom, rightBottom) + 14

        // モデル別・Cowork別の週間枠は、値がある場合だけ補足として表示する
        if let w = usage.sevenDaySonnet {
            addCompactLine(to: container, y: &y, width: width, text: "Sonnet \(Int(w.utilization.rounded()))%",
                           dotColor: gaugeColor(for: w.utilization))
        }
        if let w = usage.sevenDayOpus {
            addCompactLine(to: container, y: &y, width: width, text: "Opus \(Int(w.utilization.rounded()))%",
                           dotColor: gaugeColor(for: w.utilization))
        }
        if let w = usage.sevenDayCowork {
            addCompactLine(to: container, y: &y, width: width, text: "Cowork \(Int(w.utilization.rounded()))%",
                           dotColor: gaugeColor(for: w.utilization))
        }

        y += 6

        let updatedLabel = label("最終更新: \(Dates.display(usage.fetchedAt))", size: 11, color: .secondaryLabelColor)
        updatedLabel.frame = NSRect(x: 16, y: y + 3, width: width * 0.6, height: 16)
        container.addSubview(updatedLabel)

        let refreshButton = NSButton(title: "更新", target: self, action: #selector(refreshNow))
        refreshButton.isBordered = false
        refreshButton.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        refreshButton.contentTintColor = .darkGray
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "更新")
        refreshButton.imagePosition = .imageLeading
        refreshButton.imageScaling = .scaleProportionallyDown
        refreshButton.sizeToFit()

        let pillWidth = refreshButton.frame.width + 18
        let pillHeight: CGFloat = 24
        let pillFrame = NSRect(x: width - 16 - pillWidth, y: y - 4, width: pillWidth, height: pillHeight)
        addCard(to: container, frame: pillFrame, fillColor: NSColor.gray.withAlphaComponent(0.18), cornerRadius: pillHeight / 2)
        refreshButton.frame = NSRect(x: pillFrame.minX + 9, y: y - 1,
                                      width: refreshButton.frame.width, height: refreshButton.frame.height)
        container.addSubview(refreshButton)
        y += 16 + 14

        if let extra = usage.extra, extra.usedCredits > 0 {
            let text = "⚠️ 追加課金（今月）: \(String(format: "$%.2f", extra.usedCredits))"
            let chipHeight: CGFloat = 26
            let chipFrame = NSRect(x: 16, y: y, width: width - 32, height: chipHeight)
            addCard(to: container, frame: chipFrame, fillColor: NSColor.systemRed.withAlphaComponent(0.13), cornerRadius: 8)
            let chipLabel = label(text, size: 11.5, weight: .medium, color: .systemRed, alignment: .center)
            let labelHeight: CGFloat = 16
            chipLabel.frame = NSRect(x: chipFrame.minX, y: chipFrame.minY + (chipHeight - labelHeight) / 2,
                                      width: chipFrame.width, height: labelHeight)
            container.addSubview(chipLabel)
            y += chipHeight + 6
        }

        // 正常時はなにも表示せず、エラーがある時だけ知らせる
        if let lastError {
            y += 4
            let statusLine = NSMutableAttributedString(string: "● ", attributes: [
                .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 11),
            ])
            statusLine.append(NSAttributedString(string: lastError, attributes: [
                .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12),
            ]))
            let statusField = NSTextField(labelWithAttributedString: statusLine)
            statusField.lineBreakMode = .byWordWrapping
            statusField.frame = NSRect(x: 16, y: y, width: width - 32, height: statusField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 32, height: 40)).height ?? 18)
            container.addSubview(statusField)
            y += statusField.frame.height + 4
        }

        y += 8
        container.frame = NSRect(x: 0, y: 0, width: width, height: y)
        return container
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let panelItem = NSMenuItem()
        panelItem.view = buildUsagePanel()
        menu.addItem(panelItem)

        menu.addItem(.separator())

        let webItem = item("使用量の詳細を見る", action: #selector(openUsagePage))
        menu.addItem(webItem)

        let loginItem = item("ログイン時に自動起動", action: #selector(toggleLoginItem))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = item("終了", action: #selector(quit))
        quitItem.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: "終了")
        menu.addItem(quitItem)
    }

    // MARK: メニュー操作

    @objc private func refreshNow() {
        backoffUntil = nil
        fetchUsage()
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "自動起動の設定に失敗しました"
            alert.informativeText = "アプリを「アプリケーション」フォルダに入れてから再度お試しください。\n\(error.localizedDescription)"
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - エントリポイント

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
