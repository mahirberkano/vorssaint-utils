// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Adds the wait hook to a Claude Code profile's `settings.json` and takes it
/// out again. Its entries are told apart by the `--claude-wait-hook` flag in
/// their command, so every other hook and setting is left as it was, and a
/// moved app replaces its entries rather than adding new ones.
enum ClaudeHookInstaller {
    enum Failure: Error, Equatable {
        /// The file is there but could not be read.
        case unreadable
        /// The file is not a JSON object, so nothing is written to it.
        case malformed
        case unwritable
    }

    static let backupSuffix = ".vorssaint-backup"

    /// The app's executable, quoted for the shell, with the hook's flag.
    /// Once the app is gone the hook quietly does nothing, so a leftover
    /// entry never fails a Claude Code event.
    static func command(executable: String) -> String {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return "[ -x \(quoted) ] && \(quoted) \(ClaudeWaitHook.flag) || true"
    }

    /// The executable a wait hook's command runs, as `command(executable:)` wrote it.
    static func executable(in command: String) -> String? {
        let start = "[ -x '", end = "' ] && "
        guard command.hasPrefix(start), let close = command.range(of: end) else { return nil }
        return String(command[command.index(command.startIndex, offsetBy: start.count)..<close.lowerBound])
            .replacingOccurrences(of: #"'\''"#, with: "'")
    }

    /// A wait hook this app may take out: its own, or one left by a build of
    /// the app that is no longer there. Another installed build's stays.
    private static func isRemovable(_ hook: [String: Any], command: String) -> Bool {
        guard let entry = hook["command"] as? String, entry.contains(ClaudeWaitHook.flag) else { return false }
        if entry == command { return true }
        guard let executable = executable(in: entry) else { return true }
        return !FileManager.default.isExecutableFile(atPath: executable)
    }

    static func installing(into settings: [String: Any], command: String) -> [String: Any] {
        var result = removing(from: settings, command: command)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for (event, matcher) in ClaudeWaitEvent.hookEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "async": true, "timeout": 5] as [String: Any]],
            ]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    static func removing(from settings: [String: Any], command: String) -> [String: Any] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return settings }
        var result = settings
        var kept: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { kept[event] = value; continue }
            let remaining: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]],
                      entries.contains(where: { isRemovable($0, command: command) }) else { return group }
                let others = entries.filter { !isRemovable($0, command: command) }
                guard !others.isEmpty else { return nil }
                var trimmed = group
                trimmed["hooks"] = others
                return trimmed
            }
            if !remaining.isEmpty { kept[event] = remaining }
        }
        if kept.isEmpty { result["hooks"] = nil } else { result["hooks"] = kept }
        return result
    }

    static func isInstalled(in settings: [String: Any], command: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return ClaudeWaitEvent.hookEvents.allSatisfy { event, _ in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    /// Installs or removes the hook in the file at `settingsURL`. Settings
    /// that do not parse are never written; the first change is preceded by
    /// a copy beside the file that later changes never overwrite. A hook
    /// already in place leaves the file alone, since Claude Code writes it
    /// too, and a linked file is written through its link.
    static func apply(install: Bool, settingsURL: URL, executable: String) throws {
        let manager = FileManager.default
        let target = settingsURL.resolvingSymlinksInPath()
        let exists = manager.fileExists(atPath: target.path)
        var current: [String: Any] = [:]
        var original = Data()
        if exists {
            guard let data = try? Data(contentsOf: target) else { throw Failure.unreadable }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
            current = object
            original = data
        }
        let ours = command(executable: executable)
        if install, isInstalled(in: current, command: ours) { return }
        let next = install ? installing(into: current, command: ours) : removing(from: current, command: ours)
        if NSDictionary(dictionary: next).isEqual(to: current), exists || !install { return }

        let backup = URL(fileURLWithPath: settingsURL.path + backupSuffix)
        if exists, !manager.fileExists(atPath: backup.path) {
            do { try original.write(to: backup) } catch { throw Failure.unwritable }
        }
        guard var data = try? JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { throw Failure.unwritable }
        data.append(UInt8(ascii: "\n"))
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        } catch {
            throw Failure.unwritable
        }
    }
}
