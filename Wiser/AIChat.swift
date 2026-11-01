//
//  AIChat.swift
//  Wiser
//
//  Created by Marlin on 01/11/2026.
//

import Foundation
import Observation
import Security

/// One long conversation with AI about the user's focus, kept until they delete it: questions and answers, as Cue
/// keeps its conversations.
nonisolated struct Chat: Codable {
    struct Message: Codable, Identifiable, Equatable {
        enum Role: String, Codable { case user, assistant }
        var id = UUID()
        var role: Role
        var text: String
    }

    var messages: [Message] = []
}

/// The conversation as it is now. An answer streams into it as AI writes it, and goes on if the page is left; the
/// conversation is kept in a file as an answer starts and as it ends.
@Observable
final class FocusChat {
    static let shared = FocusChat()

    private(set) var messages: [Chat.Message] = []
    /// Whether an answer is being written, and why the last answer didn't come, if it didn't.
    private(set) var answering = false
    private(set) var failure: String?
    /// What was being written and not yet sent: still there when the page is opened again, for as long as the app runs.
    var draft = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isOpen = false

    /// Read in at once, so the page has its conversation from its first frame.
    private init() {
        open()
    }

    /// How many of the latest messages go with each question: a long conversation's oldest stay on screen but no
    /// longer cost anything.
    private static let remembered = 60

    /// Reads the conversation the first time it's needed. An answer the app was closed in the middle of, with nothing
    /// written yet, is let go, rather than thinking for good.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        var chat = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Chat.self, from: $0) } ?? Chat()
        if let last = chat.messages.last, last.role == .assistant, last.text.isEmpty {
            chat.messages.removeLast()
        }
        messages = chat.messages
    }

    /// Asks `text`, AI answering with what it knows of the user's focus, `records`. Returns the question as it stands
    /// in the conversation.
    @discardableResult
    func send(_ text: String, records: [String]) -> Chat.Message.ID? {
        open()
        guard !answering else { return nil }
        guard let key = OpenAIKey.value else {
            failure = OpenAIError.missingKey.localizedDescription
            return nil
        }
        let question = Chat.Message(role: .user, text: text)
        messages.append(question)
        let history = Array(messages.suffix(Self.remembered))
        messages.append(Chat.Message(role: .assistant, text: ""))
        failure = nil
        answering = true
        save()
        task = Task {
            defer {
                answering = false
                task = nil
                // An answer that never began leaves nothing behind it.
                if let last = messages.last, last.role == .assistant, last.text.isEmpty {
                    messages.removeLast()
                }
                save()
            }
            do {
                let onDelta: @MainActor (String) -> Void = { delta in
                    guard let last = self.messages.indices.last else { return }
                    self.messages[last].text += delta
                }
                #if DEBUG
                // `-rehearseChat YES`: an answer written here, in bursts as AI's come, to try the page without a key
                // or paying for one.
                if UserDefaults.standard.bool(forKey: "rehearseChat") {
                    try await ChatClient.rehearse(onDelta: onDelta)
                    return
                }
                #endif
                try await ChatClient.stream(history, instructions: ChatClient.instructions(records), key: key, onDelta: onDelta)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                failure = error.localizedDescription
            }
        }
        return question.id
    }

    /// Stops the answer being written, keeping what has come of it.
    func stop() {
        task?.cancel()
    }

    /// Deletes the conversation.
    func clear() {
        stop()
        messages = []
        failure = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func save() {
        guard !messages.isEmpty else {
            try? FileManager.default.removeItem(at: Self.file)
            return
        }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Chat(messages: messages)).write(to: Self.file, options: .atomic)
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Conversation.json")
}

/// Talks to OpenAI with the user's own key, as Cue does with one: the conversation so far goes up, and the answer
/// comes back as it is written.
nonisolated enum ChatClient {
    static let model = "gpt-6.1-sol"

    static func stream(_ messages: [Chat.Message], instructions: String, key: String,
                       onDelta: @MainActor (String) -> Void) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "low"],
            "store": false,
            "stream": true,
            "instructions": instructions,
            "input": messages.filter { !$0.text.isEmpty }.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenAIError.server(try await EventStream.errorMessage(in: bytes) ?? String(localized: "AI didn’t answer."))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = EventStream.event(from: line) else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String { await onDelta(delta) }
            case "response.completed":
                return
            case "response.failed", "response.incomplete", "error":
                let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? event["message"] as? String
                throw OpenAIError.server(message ?? String(localized: "AI didn’t answer."))
            default:
                continue
            }
        }
        // The stream ended before the answer did: the connection dropped. (Cue took it as done, and showed nothing.)
        try Task.checkCancellation()
        throw OpenAIError.server(String(localized: "The answer was cut off. Try asking again."))
    }

    private static var endpoint: URL {
        #if DEBUG
        // `-openAIURL http://…`: somewhere else that answers as OpenAI does.
        if let url = UserDefaults.standard.string(forKey: "openAIURL").flatMap(URL.init(string:)) { return url }
        #endif
        return URL(string: "https://api.openai.com/v1/responses")!
    }

    /// How AI talks, then what it knows of the user's focus.
    static func instructions(_ records: [String]) -> String {
        """
        You are the companion inside Wiser, a focus timer: the user starts a session when they settle down to work, \
        and a stack of stones in the sky stands for it. You know their focus records, below. Talk with them as a calm, \
        perceptive coach would.

        - Reply in the language they write in, usually Chinese.
        - Answer what was asked, briefly. No preamble, and no offer of more at the end.
        - Plain text: no Markdown, no **, #, tables or bullet symbols. Separate paragraphs with a blank line; number items 1. 2. 3. when a list helps.
        - Say what the records show and only that: never make up a number, a day or a session. If they don't say, say so.
        - Encourage without flattering, and never make them feel guilty about a day without focus.

        Their focus records (times are the user's local time):
        \(records.joined(separator: "\n"))
        """
    }
}

#if DEBUG
extension ChatClient {
    /// An answer as AI might write one, after a second and a half of thought, in pieces of one to a dozen characters
    /// coming 20 to 160 ms apart, as Cue rehearses its own.
    static func rehearse(onDelta: @MainActor (String) -> Void) async throws {
        try await Task.sleep(for: .seconds(1.5))
        var rest = Substring(rehearsal)
        while !rest.isEmpty {
            try Task.checkCancellation()
            let piece = rest.prefix(Int.random(in: 1...12))
            rest = rest.dropFirst(piece.count)
            await onDelta(String(piece))
            try await Task.sleep(for: .milliseconds(Int.random(in: 20...160)))
        }
    }

    static let rehearsal = """
        这周你专注了 10 小时 15 分钟，比上周多了不少，节奏一下子起来了。

        1. 最好的一天是周二，2 小时 45 分钟，其中早上 7 点那一段有一个半小时。
        2. 你最常在上午 9 点到 11 点之间开始，这个时段的专注加起来最多。
        3. 周一没有记录，其余六天每天都有。

        如果想保持下去，可以把最难的事放在上午 9 点那一段，下午留给轻一点的事。
        """
}
#endif

/// What AI knows of the user's focus going into the conversation, as lines: today and the periods around it, every day
/// with focus in the last four weeks and its sessions, the months before, and the hours of the day it falls in.
enum FocusRecords {
    static func lines(_ sessions: [FocusSession], now: Date = .now, calendar: Calendar = .current) -> [String] {
        let english = Locale(identifier: "en_US_POSIX")
        func formatted(_ date: Date, _ format: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = english
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        func minutes(_ start: Date, _ end: Date) -> Int {
            Int(sessions.reduce(0.0) { total, session in
                let overlap = min(session.startDate.addingTimeInterval(session.durationSeconds), end)
                    .timeIntervalSince(max(session.startDate, start))
                return total + max(0, overlap)
            }) / 60
        }
        func period(_ component: Calendar.Component, _ offset: Int) -> DateInterval {
            calendar.dateInterval(of: component, for: calendar.date(byAdding: component, value: offset, to: now)!)!
        }
        func total(_ interval: DateInterval) -> String {
            let focused = minutes(interval.start, interval.end)
            return focused == 0 ? "none" : formatFocusTime(minutes: focused)
        }

        var lines = ["Now: \(formatted(now, "EEEE d MMMM yyyy, HH:mm")) (\(calendar.timeZone.identifier))"]
        guard let first = sessions.min(by: { $0.startDate < $1.startDate }) else {
            lines.append("No focus sessions recorded yet.")
            return lines
        }

        let today = period(.day, 0)
        let todays = sessions.filter { today.contains($0.startDate) }
        lines.append("Today: \(total(today)) in \(todays.count) session\(todays.count == 1 ? "" : "s")")
        lines.append("Yesterday: \(total(period(.day, -1)))")
        let week = period(.weekOfYear, 0)
        lines.append("This week (from \(formatted(week.start, "EEE d MMM"))): \(total(week)); last week: \(total(period(.weekOfYear, -1)))")
        lines.append("This month: \(total(period(.month, 0))); last month: \(total(period(.month, -1)))")
        let all = sessions.reduce(0) { $0 + $1.durationMinutes }
        lines.append("Since the first session on \(formatted(first.startDate, "d MMM yyyy")): \(formatFocusTime(minutes: all)) in \(sessions.count) sessions")

        // Days in a row with focus, up to today, or up to yesterday while today has none yet.
        var streak = 0
        var day = minutes(today.start, today.end) > 0 ? today.start : calendar.date(byAdding: .day, value: -1, to: today.start)!
        while minutes(day, calendar.date(byAdding: .day, value: 1, to: day)!) > 0 {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        lines.append("Days in a row with focus: \(streak)")

        lines.append("Each day of the last 28 with focus, newest first (days not listed had none):")
        let since = calendar.date(byAdding: .day, value: -27, to: today.start)!
        for offset in 0..<28 {
            let start = calendar.date(byAdding: .day, value: -offset, to: today.start)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let focused = minutes(start, end)
            guard focused > 0 else { continue }
            let pieces = sessions.filter { start <= $0.startDate && $0.startDate < end }
                .sorted { $0.startDate < $1.startDate }
                .map { "\(formatted($0.startDate, "HH:mm")) \(formatFocusTime(minutes: $0.durationMinutes))" }
            lines.append("\(formatted(start, "yyyy-MM-dd EEE")): \(formatFocusTime(minutes: focused)) (\(pieces.joined(separator: ", ")))")
        }

        let months = (1...12).map { period(.month, -$0) }.filter { $0.end > first.startDate }
        if !months.isEmpty {
            lines.append("Months before this one: " + months.map { "\(formatted($0.start, "MMM yyyy")) \(total($0))" }
                .joined(separator: "; "))
        }

        // When in the day the last four weeks' focus fell, an hour at a time.
        var hours = [Int](repeating: 0, count: 24)
        for session in sessions where session.startDate >= since {
            var start = session.startDate
            let end = session.startDate.addingTimeInterval(session.durationSeconds)
            while start < end {
                let hour = calendar.component(.hour, from: start)
                let next = min(calendar.date(byAdding: .hour, value: 1, to: calendar.dateInterval(of: .hour, for: start)!.start)!, end)
                hours[hour] += Int(next.timeIntervalSince(start)) / 60
                start = next
            }
        }
        let busy = hours.indices.filter { hours[$0] > 0 }
        if !busy.isEmpty {
            lines.append("Focus by hour of day, last 28 days: " + busy.map {
                String(format: "%02d:00 %@", $0, formatFocusTime(minutes: hours[$0]))
            }.joined(separator: ", "))
        }
        return lines
    }
}

/// The user's own OpenAI API key, typed in on the AI page and kept in the keychain, as Cue keeps one.
nonisolated enum OpenAIKey {
    private static let service = "com.chenyeni.wiser.openai"

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
    }

    static var value: String? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Keeps the key, or forgets it when it is empty.
    static func set(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(key.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// What can go wrong asking OpenAI with the user's key.
nonisolated enum OpenAIError: LocalizedError {
    case missingKey
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "Add your OpenAI API key first.")
        case .server(let message): message
        }
    }
}

/// Reading OpenAI's streamed replies, which arrive as server-sent events: one JSON object per `data:` line.
nonisolated enum EventStream {
    /// The event a line carries, if it is a `data:` line.
    static func event(from line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
    }

    /// The service's own message in an error reply that was asked for as a stream but came back whole.
    static func errorMessage(in bytes: URLSession.AsyncBytes) async throws -> String? {
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String
    }
}
