// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Claude Code waiting on the person: which hook events start and end a
/// wait, how long waits are kept per session, and how cross the companion is.
enum ClaudeWaitTests {
    static func run(_ suite: TestSuite) {
        stages(suite)
        classification(suite)
        tracking(suite)
        hookRecording(suite)
        installation(suite)
        feeding(suite)
        gating(suite)
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func stages(_ suite: TestSuite) {
        let cases: [(TimeInterval, ClaudeWaitStage)] = [
            (0, .attention), (59.9, .attention), (60, .impatient), (239.9, .impatient), (240, .angry), (3000, .angry),
        ]
        for (waited, stage) in cases {
            suite.expect(ClaudeWaitStage.stage(waited: waited) == stage, "after \(waited) s of waiting it is \(stage)")
        }
    }

    private static func classification(_ suite: TestSuite) {
        func event(_ input: [String: Any]) -> ClaudeWaitEvent? { ClaudeWaitEvent.classify(input, at: t0) }
        let permission: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": "rm -rf secret"], "cwd": "/Users/someone/project",
            "transcript_path": "/Users/someone/.claude/projects/p/s1.jsonl",
        ]
        suite.expect(event(permission) == ClaudeWaitEvent(kind: .began, session: "s1", tool: "Bash", date: t0),
                     "a permission request begins a wait")
        for type in ["permission_prompt", "elicitation_dialog"] {
            suite.expect(event(["hook_event_name": "Notification", "session_id": "s1", "notification_type": type])?.kind == .began,
                         "a \(type) notification begins a wait")
        }
        suite.expect(event(["hook_event_name": "Notification", "session_id": "s1", "notification_type": "idle_prompt"]) == nil,
                     "an idle prompt is no wait for an answer")
        for name in ["PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"] {
            suite.expect(event(["hook_event_name": name, "session_id": "s1"])?.kind == .ended, "\(name) ends a wait")
        }
        suite.expect(event(["hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "AskUserQuestion"]) == nil,
                     "a tool about to run is checked before any prompt, so it starts nothing")
        suite.expect(event(["hook_event_name": "PermissionRequest", "tool_name": "Bash"]) == nil,
                     "an event without a session is ignored")

        // Only the kind, session, tool and time are kept: never the command,
        // the folder or the transcript's path.
        if let kept = event(permission), let data = try? JSONEncoder().encode(kept),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            suite.expect(object.keys.sorted() == ["date", "kind", "session", "tool"], "a wait keeps only its kind, session, tool and time")
            let text = String(decoding: data, as: UTF8.self)
            suite.expect(!text.contains("secret") && !text.contains("someone"), "no command or path is kept")
        } else {
            suite.expect(false, "a permission request encodes")
        }
        let names = Set(ClaudeWaitEvent.hookEvents.map(\.event))
        suite.expect(names == ["PermissionRequest", "Notification", "PostToolUse", "PostToolUseFailure",
                               "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"],
                     "the hook listens to exactly the events that start and end a wait")
    }

    private static func tracking(_ suite: TestSuite) {
        func began(_ session: String, _ offset: TimeInterval) -> ClaudeWaitEvent {
            ClaudeWaitEvent(kind: .began, session: session, tool: "Bash", date: t0 + offset)
        }
        func ended(_ session: String, _ offset: TimeInterval) -> ClaudeWaitEvent {
            ClaudeWaitEvent(kind: .ended, session: session, tool: nil, date: t0 + offset)
        }

        var tracker = ClaudeWaitTracker()
        suite.expect(tracker.oldest == nil && tracker.stage(now: t0) == nil, "nothing waits at first")
        tracker.apply(began("A", 0))
        suite.expect(tracker.oldest == t0, "a wait starts when it began")
        tracker.apply(began("B", 10))
        suite.expect(tracker.oldest == t0, "the oldest wait sets how cross it is")
        tracker.apply(ended("A", 20))
        suite.expect(tracker.oldest == t0 + 10, "one session answered leaves the other one waiting")
        tracker.apply(ended("B", 30))
        suite.expect(tracker.oldest == nil && tracker.stage(now: t0 + 40) == nil, "every session answered, nothing waits")

        tracker.apply(began("A", 0))
        tracker.apply(began("A", 50))
        suite.expect(tracker.oldest == t0, "a second prompt in the same wait keeps its start")

        // Another tool finishing in the same session, as parallel calls or a
        // subagent do, leaves the prompt waiting; only its own tool or the
        // turn moving on ends it.
        var parallel = ClaudeWaitTracker()
        parallel.apply(began("P", 0))
        parallel.apply(ClaudeWaitEvent(kind: .ended, session: "P", tool: "Read", date: t0 + 1))
        suite.expect(parallel.oldest == t0, "a different tool finishing does not end the wait for a Bash prompt")
        parallel.transcriptChanged(session: "P", at: t0 + 10)
        suite.expect(parallel.oldest == t0, "with other tools at work the transcript moving on is theirs, not an answer")
        parallel.apply(ClaudeWaitEvent(kind: .ended, session: "P", tool: "Bash", date: t0 + 2))
        suite.expect(parallel.oldest == nil, "the prompted tool finishing ends it")
        parallel.apply(ClaudeWaitEvent(kind: .began, session: "Q", tool: nil, date: t0))
        parallel.apply(ClaudeWaitEvent(kind: .ended, session: "Q", tool: "Read", date: t0 + 1))
        suite.expect(parallel.oldest == nil, "a wait whose tool is unknown ends with any tool")

        var transcript = tracker
        transcript.transcriptChanged(session: "A", at: t0 + 2)
        suite.expect(transcript.oldest == t0, "what the transcript writes with the prompt does not end it")
        transcript.transcriptChanged(session: "A", at: t0 + 3.1)
        suite.expect(transcript.oldest == nil, "the transcript moving on ends the wait, as after a refusal")

        var sleeping = tracker
        suite.expect(sleeping.stage(now: t0 + 300) == .angry, "a wait is measured on the wall clock")
        sleeping.expire(now: t0 + 1799)
        suite.expect(sleeping.oldest == t0, "a wait is kept up to half an hour")
        sleeping.expire(now: t0 + 1801)
        suite.expect(sleeping.oldest == nil, "a wait older than half an hour is dropped")
    }
    private static func hookRecording(_ suite: TestSuite) {
        let input = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"cat secret"},"cwd":"/Users/someone"}"#.utf8)
        if let line = ClaudeWaitHook.line(for: input, at: t0) {
            suite.expect(line.last == UInt8(ascii: "\n") && line.filter { $0 == UInt8(ascii: "\n") }.count == 1,
                         "a wait is recorded as one line")
            let decoded = try? JSONDecoder().decode(ClaudeWaitEvent.self, from: line.dropLast())
            suite.expect(decoded == ClaudeWaitEvent(kind: .began, session: "s1", tool: "Bash", date: t0),
                         "the recorded line reads back as the wait")
            let text = String(decoding: line, as: UTF8.self)
            suite.expect(!text.contains("secret") && !text.contains("someone"), "the command and folder are not recorded")
        } else {
            suite.expect(false, "a permission request is recorded")
        }
        suite.expect(ClaudeWaitHook.line(for: Data(#"{"hook_event_name":"PreToolUse","session_id":"s1"}"#.utf8), at: t0) == nil,
                     "an event that says nothing about waiting is not recorded")
        suite.expect(ClaudeWaitHook.line(for: Data("not json".utf8), at: t0) == nil, "broken input is not recorded")

        let folder = FileManager.default.temporaryDirectory.appending(path: "claude-wait-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = ClaudeWaitHook.eventsURL(supportDirectory: folder)
        suite.expect(url.lastPathComponent == "claude-waits.jsonl", "waits go to their own file")
        let one = Data("{\"a\":1}\n".utf8)
        try? ClaudeWaitHook.append(one, to: url)
        try? ClaudeWaitHook.append(one, to: url)
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count
        suite.expect(lines == 2, "each wait adds a line")
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        suite.expect(mode == 0o600, "only the person can read the file")
        let filler = Data(repeating: UInt8(ascii: "x"), count: ClaudeWaitHook.sizeLimit)
        try? ClaudeWaitHook.append(filler, to: url)
        try? ClaudeWaitHook.append(one, to: url)
        suite.expect((try? Data(contentsOf: url)) == one, "a file past its limit starts over")
    }
    private static func installation(_ suite: TestSuite) {
        let url = URL(fileURLWithPath: "Tests/Fixtures/claude-settings-with-hooks.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            suite.expect(false, "the Claude settings fixture loads"); return
        }
        let command = ClaudeHookInstaller.command(executable: "/Applications/Vorssaint (Developer).app/Contents/MacOS/VorssaintDeveloper")
        let quoted = "'/Applications/Vorssaint (Developer).app/Contents/MacOS/VorssaintDeveloper'"
        suite.expect(command == "[ -x \(quoted) ] && \(quoted) --claude-wait-hook || true",
                     "the hook runs the app's own executable, quoted, and does nothing once the app is gone")
        suite.expect(ClaudeHookInstaller.command(executable: "/a/it's/app").hasPrefix(#"[ -x '/a/it'\''s/app' ]"#),
                     "a quote in the path is escaped for the shell")

        func ours(_ settings: [String: Any]) -> [String: Int] {
            var found: [String: Int] = [:]
            for (event, groups) in settings["hooks"] as? [String: [[String: Any]]] ?? [:] {
                for group in groups {
                    for hook in group["hooks"] as? [[String: Any]] ?? [] where (hook["command"] as? String)?.contains(ClaudeWaitHook.flag) == true {
                        found[event, default: 0] += 1
                    }
                }
            }
            return found
        }
        func others(_ settings: [String: Any]) -> NSDictionary {
            NSDictionary(dictionary: ClaudeHookInstaller.removing(from: settings, command: command))
        }

        let installed = ClaudeHookInstaller.installing(into: fixture, command: command)
        let expected = Dictionary(uniqueKeysWithValues: ClaudeWaitEvent.hookEvents.map { ($0.event, 1) })
        suite.expect(ours(installed) == expected, "every wait event gets exactly one hook")
        suite.expect(ClaudeHookInstaller.isInstalled(in: installed, command: command), "the hook reads as installed")
        suite.expect(!ClaudeHookInstaller.isInstalled(in: fixture, command: command), "the fixture has none yet")
        suite.expect(others(installed).isEqual(to: fixture), "every other hook and setting is left exactly as it was")
        if let stop = (installed["hooks"] as? [String: [[String: Any]]])?["Stop"] {
            suite.expect(stop.count == 3, "the Stop event keeps its two hooks and gains one")
        }
        if let group = ((installed["hooks"] as? [String: [[String: Any]]])?["PermissionRequest"])?.last,
           let hook = (group["hooks"] as? [[String: Any]])?.first {
            suite.expect(group["matcher"] as? String == "*", "a tool event's hook matches every tool")
            suite.expect(hook["type"] as? String == "command" && hook["async"] as? Bool == true && hook["timeout"] as? Int == 5,
                         "the hook runs in the background and briefly")
        }
        if let group = ((installed["hooks"] as? [String: [[String: Any]]])?["Stop"])?.last {
            suite.expect(group["matcher"] == nil, "an event without tools has no matcher")
        }

        let twice = ClaudeHookInstaller.installing(into: installed, command: command)
        suite.expect(ours(twice) == expected, "installing again adds nothing")
        let gone = ClaudeHookInstaller.installing(into: fixture, command: ClaudeHookInstaller.command(executable: "/nonexistent/Old Vorssaint"))
        let moved = ClaudeHookInstaller.installing(into: gone, command: command)
        suite.expect(ours(moved) == expected && ClaudeHookInstaller.isInstalled(in: moved, command: command),
                     "a moved app replaces the hook it left at its old place rather than adding one")
        suite.expect(ClaudeHookInstaller.executable(in: ClaudeHookInstaller.command(executable: "/a/it's/app")) == "/a/it's/app",
                     "the executable reads back from a hook's command")
        suite.expect(NSDictionary(dictionary: ClaudeHookInstaller.removing(from: installed, command: command)).isEqual(to: fixture),
                     "removing gives back the settings as they were")
        let bare = ClaudeHookInstaller.installing(into: ["model": "opus"], command: command)
        suite.expect(NSDictionary(dictionary: ClaudeHookInstaller.removing(from: bare, command: command)).isEqual(to: ["model": "opus"]),
                     "removing drops the hooks section it created")

        // The released and the Developer build each keep their own hook while
        // both are installed; one whose app is gone is cleared by either.
        let released = ClaudeHookInstaller.command(executable: "/bin/sh")
        let developer = ClaudeHookInstaller.command(executable: "/bin/ls")
        let both = ClaudeHookInstaller.installing(into: ClaudeHookInstaller.installing(into: fixture, command: released),
                                                  command: developer)
        suite.expect(ours(both) == expected.mapValues { $0 * 2 } && ClaudeHookInstaller.isInstalled(in: both, command: released)
                     && ClaudeHookInstaller.isInstalled(in: both, command: developer),
                     "two installed builds keep a hook each")
        let developerOff = ClaudeHookInstaller.removing(from: both, command: developer)
        suite.expect(ClaudeHookInstaller.isInstalled(in: developerOff, command: released) && ours(developerOff) == expected,
                     "turning one build off leaves the other build's hook")

        let folder = FileManager.default.temporaryDirectory.appending(path: "claude-hooks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = folder.appending(path: "settings.json")
        let backup = folder.appending(path: "settings.json.vorssaint-backup")
        let executable = "/Applications/Vorssaint.app/Contents/MacOS/Vorssaint"

        do {
            try ClaudeHookInstaller.apply(install: true, settingsURL: settings, executable: executable)
            let written = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] ?? [:]
            suite.expect(ours(written) == expected, "a missing settings file is created with the hook")
        } catch {
            suite.expect(false, "installing into a missing file works: \(error)")
        }

        try? data.write(to: settings)
        try? FileManager.default.removeItem(at: backup)
        do {
            try ClaudeHookInstaller.apply(install: true, settingsURL: settings, executable: executable)
            suite.expect((try? Data(contentsOf: backup)) == data, "the settings are backed up before the first change")
            try ClaudeHookInstaller.apply(install: false, settingsURL: settings, executable: executable)
            let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] ?? [:]
            suite.expect(NSDictionary(dictionary: restored).isEqual(to: fixture), "turning it off leaves the settings as they were")
            try ClaudeHookInstaller.apply(install: true, settingsURL: settings, executable: executable)
            suite.expect((try? Data(contentsOf: backup)) == data, "an existing backup is never overwritten")
        } catch {
            suite.expect(false, "installing and removing works: \(error)")
        }

        // Already in place, the file is not written again, even when the
        // person added hooks after it: Claude Code writes this file too.
        do {
            try ClaudeHookInstaller.apply(install: true, settingsURL: settings, executable: executable)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] ?? [:]
            var hooks = object["hooks"] as? [String: Any] ?? [:]
            var stop = hooks["Stop"] as? [[String: Any]] ?? []
            stop.append(["hooks": [["type": "command", "command": "/usr/bin/true"]]])
            hooks["Stop"] = stop
            object["hooks"] = hooks
            let edited = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            try edited.write(to: settings)
            try ClaudeHookInstaller.apply(install: true, settingsURL: settings, executable: executable)
            suite.expect((try? Data(contentsOf: settings)) == edited, "an installed hook leaves the file as it is")
        } catch {
            suite.expect(false, "installing over an installed hook works: \(error)")
        }

        // A settings file kept elsewhere and linked in stays linked.
        let linkFolder = folder.appending(path: "dotfiles")
        try? FileManager.default.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        let target = linkFolder.appending(path: "settings.json")
        let link = folder.appending(path: "linked.json")
        try? data.write(to: target)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            try ClaudeHookInstaller.apply(install: true, settingsURL: link, executable: executable)
            let kind = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
            let written = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any] ?? [:]
            suite.expect(kind == .typeSymbolicLink && ours(written) == expected,
                         "a linked settings file stays a link and its target gets the hook")
        } catch {
            suite.expect(false, "installing through a link works: \(error)")
        }

        let broken = Data("{ \"hooks\": ".utf8)
        try? broken.write(to: settings)
        var failure: ClaudeHookInstaller.Failure?
        do { try ClaudeHookInstaller.apply(install: true, settingsURL: settings, executable: executable) }
        catch let error as ClaudeHookInstaller.Failure { failure = error }
        catch {}
        suite.expect(failure == .malformed, "settings that do not parse are reported")
        suite.expect((try? Data(contentsOf: settings)) == broken, "settings that do not parse are left untouched")
    }
    private static func feeding(_ suite: TestSuite) {
        func line(_ event: ClaudeWaitEvent) -> Data {
            var data = (try? JSONEncoder().encode(event)) ?? Data()
            data.append(UInt8(ascii: "\n"))
            return data
        }
        var feed = ClaudeWaitFeed(since: t0)
        feed.consume(line(ClaudeWaitEvent(kind: .began, session: "old", tool: "Bash", date: t0 - 3600)))
        suite.expect(feed.tracker.oldest == nil, "a wait recorded before the app looked is no news")
        let fresh = line(ClaudeWaitEvent(kind: .began, session: "new", tool: "Bash", date: t0 + 5))
        feed.consume(fresh.prefix(10))
        suite.expect(feed.tracker.oldest == nil, "half a line waits for the rest")
        feed.consume(fresh.dropFirst(10))
        suite.expect(feed.tracker.oldest == t0 + 5, "a line read in two parts is one wait")
        feed.consume(Data("garbage\n".utf8))
        feed.consume(line(ClaudeWaitEvent(kind: .ended, session: "new", tool: nil, date: t0 + 9)))
        suite.expect(feed.tracker.oldest == nil, "a broken line is skipped and the next one still counts")
    }

    private static func gating(_ suite: TestSuite) {
        let domain = "com.vorssaint.tests.claude-wait"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { defaults.set(value, forKey: key) }
        for (key, value) in AppFeature.availabilityDefaults { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: AppFeature.notch.availabilityKey)
        defaults.set(true, forKey: AppFeature.notchMascot.availabilityKey)
        defaults.set(true, forKey: AppFeature.notchAgents.availabilityKey)
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        defaults.set(true, forKey: DefaultsKey.notchMascotEnabled)
        defaults.set(true, forKey: DefaultsKey.notchAgentsEnabled)

        suite.expect(defaults.bool(forKey: DefaultsKey.notchMascotClaudeWait) == false, "waiting for Claude is opt-in")
        suite.expect(!NotchMascotSupport.waitsForClaude(in: defaults), "off until it is switched on")
        defaults.set(true, forKey: DefaultsKey.notchMascotClaudeWait)
        suite.expect(NotchMascotSupport.waitsForClaude(in: defaults), "on with the companion, AI Agents and Claude")
        defaults.set(false, forKey: DefaultsKey.notchAgentsClaude)
        suite.expect(!NotchMascotSupport.waitsForClaude(in: defaults), "Claude turned off in AI Agents turns it off")
        defaults.set(true, forKey: DefaultsKey.notchAgentsClaude)
        defaults.set(false, forKey: DefaultsKey.notchAgentsEnabled)
        suite.expect(!NotchMascotSupport.waitsForClaude(in: defaults), "AI Agents turned off turns it off")
        defaults.set(true, forKey: DefaultsKey.notchAgentsEnabled)
        defaults.set(false, forKey: DefaultsKey.notchMascotEnabled)
        suite.expect(!NotchMascotSupport.waitsForClaude(in: defaults), "no companion, no wait")
    }
}
