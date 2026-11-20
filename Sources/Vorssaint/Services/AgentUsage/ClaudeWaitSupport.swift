// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// How cross the companion is with a Claude Code session that has been
/// waiting on the person this long.
enum ClaudeWaitStage: Int, Comparable, CaseIterable {
    /// Just asked: it looks up.
    case attention
    /// A minute gone: it taps its foot.
    case impatient
    /// Four minutes gone, close to when Claude's prompt cache expires.
    case angry

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func stage(waited: TimeInterval) -> Self {
        waited < 60 ? .attention : waited < 240 ? .impatient : .angry
    }
}

/// A wait for the person starting or ending in one Claude Code session, as
/// the hook records it. Only these four fields are ever kept: never the
/// command, question, folder or transcript the hook's input also carries.
struct ClaudeWaitEvent: Equatable, Codable {
    enum Kind: String, Codable { case began, ended }

    let kind: Kind
    let session: String
    let tool: String?
    let date: Date
}

extension ClaudeWaitEvent {
    /// The hook events that start or end a wait, with the matcher each is
    /// installed with. A permission request is the prompt itself; it comes
    /// only when Claude Code shows one, never for what it allows by itself.
    static let hookEvents: [(event: String, matcher: String?)] = [
        ("PermissionRequest", "*"), ("Notification", "*"), ("PostToolUse", "*"), ("PostToolUseFailure", "*"),
        ("UserPromptSubmit", nil), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
    ]

    /// Notifications that mean a prompt waits on screen. The idle one only
    /// says a finished turn was not answered yet, which is no wait.
    private static let promptNotifications: Set<String> = ["permission_prompt", "elicitation_dialog"]
    private static let endings: Set<String> = [
        "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd",
    ]

    /// What one hook input says about waiting, from its event name, session,
    /// tool and notification type alone. Nil when it says nothing.
    static func classify(_ input: [String: Any], at date: Date) -> ClaudeWaitEvent? {
        guard let name = input["hook_event_name"] as? String,
              let session = input["session_id"] as? String, !session.isEmpty else { return nil }
        let tool = input["tool_name"] as? String
        switch name {
        case "PermissionRequest":
            return ClaudeWaitEvent(kind: .began, session: session, tool: tool, date: date)
        case "Notification":
            guard let type = input["notification_type"] as? String, promptNotifications.contains(type) else { return nil }
            return ClaudeWaitEvent(kind: .began, session: session, tool: tool, date: date)
        case _ where endings.contains(name):
            return ClaudeWaitEvent(kind: .ended, session: session, tool: tool, date: date)
        default:
            return nil
        }
    }
}

/// The sessions waiting on the person, each since its first prompt.
struct ClaudeWaitTracker: Equatable {
    /// A wait nothing has ended after this long is let go, so a missed
    /// ending never keeps the companion cross for good.
    static let timeout: TimeInterval = 1800
    /// The transcript is written as the prompt appears; only writing after
    /// this long means the session moved on.
    static let transcriptGrace: TimeInterval = 3

    struct Wait: Equatable {
        let began: Date
        /// The tool the prompt is for, when it is known.
        let tool: String?
        /// Another tool finished in the session while it waited, so the
        /// transcript moves on without the prompt being answered.
        var othersRan = false
    }

    private(set) var waits: [String: Wait] = [:]

    mutating func apply(_ event: ClaudeWaitEvent) {
        switch event.kind {
        case .began:
            if waits[event.session] == nil { waits[event.session] = Wait(began: event.date, tool: event.tool) }
        case .ended:
            // A tool finishing ends only the wait for that tool: parallel
            // calls and subagents share the session and keep running while
            // a prompt waits. An ending without a tool, as a prompt sent or
            // a turn over, ends it whatever it waited for.
            guard let wait = waits[event.session] else { return }
            if let tool = event.tool, let waited = wait.tool, tool != waited {
                waits[event.session]?.othersRan = true
                return
            }
            waits[event.session] = nil
        }
    }

    /// Claude Code writes nothing to a session's transcript while a prompt
    /// waits, so a later write means it was answered, refused or cancelled,
    /// unless other tools at work in the session wrote it.
    mutating func transcriptChanged(session: String, at date: Date) {
        guard let wait = waits[session], !wait.othersRan,
              date.timeIntervalSince(wait.began) > Self.transcriptGrace else { return }
        waits[session] = nil
    }

    mutating func expire(now: Date) {
        waits = waits.filter { now.timeIntervalSince($0.value.began) <= Self.timeout }
    }

    var oldest: Date? { waits.values.map(\.began).min() }

    func stage(now: Date) -> ClaudeWaitStage? {
        oldest.map { .stage(waited: max(0, now.timeIntervalSince($0))) }
    }
}

/// Turns what the hook appended to its file into waits, as it is read in
/// pieces. Lines from before the app started looking are old news.
struct ClaudeWaitFeed {
    var tracker = ClaudeWaitTracker()
    let since: Date
    private var partial = Data()

    init(since: Date) { self.since = since }

    mutating func consume(_ data: Data) {
        partial.append(data)
        while let end = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<end]
            partial.removeSubrange(partial.startIndex...end)
            guard let event = try? JSONDecoder().decode(ClaudeWaitEvent.self, from: line), event.date >= since else { continue }
            tracker.apply(event)
        }
        partial = Data(partial)
    }
}
