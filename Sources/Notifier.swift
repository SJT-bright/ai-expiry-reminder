import Foundation
import UserNotifications

// MARK: - 系统通知 + 飞书机器人

enum Notifier {
    private static var authorized = false

    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorized = granted
        }
    }

    static func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: "aireminder-\(UUID().uuidString)",
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

enum Feishu {
    /// 向飞书群机器人 webhook 发送文本消息（settings 里配置后生效）
    static func send(webhook: String, text: String) {
        guard !webhook.isEmpty, let url = URL(string: webhook) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["msg_type": "text", "content": ["text": text]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
}

// MARK: - 到期预警引擎
// 纯函数计算，去重 key 由主线程写回 Store

enum AlertEngine {
    struct CheckOutcome {
        var fired: [SubItem]
        var newKeys: Set<String>
    }

    /// 找出进入预警窗口且未提醒过的条目
    static func check(items: [SubItem], knownKeys: Set<String>, now: Date) -> CheckOutcome {
        var fired: [SubItem] = []
        var keys = knownKeys
        for item in items {
            let remaining = item.expiresAt.timeIntervalSince(now)
            guard remaining > 0, remaining <= item.alertBeforeMinutes * 60 else { continue }
            let key = "\(item.id)|\(Int(item.expiresAt.timeIntervalSince1970))"
            if keys.insert(key).inserted {
                fired.append(item)
            }
        }
        var trimmed = keys
        if trimmed.count > 300 {
            trimmed = Set(trimmed.sorted().suffix(150))
        }
        return CheckOutcome(fired: fired, newKeys: trimmed)
    }

    static func composeMessage(_ items: [SubItem]) -> String {
        let lines = items.map { item -> String in
            let m = Int(item.expiresAt.timeIntervalSinceNow / 60)
            let when = m >= 1 ? "\(m) 分钟后" : "即将"
            return "· \(item.vendor) \(item.name) \(when)到期（\(Fmt.absTime(item.expiresAt))）"
        }
        return "⏳ AI到期提醒\n" + lines.joined(separator: "\n")
    }
}
