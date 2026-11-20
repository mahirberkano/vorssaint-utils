// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The command Claude Code runs as a hook: `<app executable> --claude-wait-hook`.
/// It reads the hook's input, keeps only whether a wait began or ended, in
/// which session, for which tool and when, appends that as one line to a
/// file in the app's Application Support folder and exits. It never writes
/// anywhere else, prints nothing and always succeeds, so it cannot get in
/// Claude Code's way.
enum ClaudeWaitHook {
    static let flag = "--claude-wait-hook"
    static let fileName = "claude-waits.jsonl"
    /// The file starts over past this size; the app reads it as it grows,
    /// so older lines are no longer needed.
    static let sizeLimit = 262_144

    static func eventsURL(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// This app's own Application Support folder, which differs between the
    /// released and the Developer build.
    static func supportDirectory() -> URL? {
        guard let identifier = Bundle.main.bundleIdentifier,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appending(path: identifier, directoryHint: .isDirectory)
    }

    /// The line to record for one hook input, or nil when it says nothing
    /// about waiting.
    static func line(for input: Data, at date: Date) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = ClaudeWaitEvent.classify(object, at: date),
              var data = try? JSONEncoder().encode(event) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Appends `line` in a single write, so lines from sessions running at
    /// once never interleave. A file past `sizeLimit` is emptied first.
    static func append(_ line: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        var status = stat()
        if fstat(descriptor, &status) == 0, status.st_size > 0, Int(status.st_size) + line.count > sizeLimit {
            _ = ftruncate(descriptor, 0)
        }
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
    }

    static func run(stdin: FileHandle, supportDirectory: URL) -> Int32 {
        guard let input = try? stdin.readToEnd(), let line = line(for: input, at: Date()) else { return 0 }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? append(line, to: eventsURL(supportDirectory: supportDirectory))
        return 0
    }

    /// Started by Claude Code: never brings up the app.
    static func runFromCommandLine() -> Int32 {
        guard let folder = supportDirectory() else { return 0 }
        return run(stdin: .standardInput, supportDirectory: folder)
    }
}
