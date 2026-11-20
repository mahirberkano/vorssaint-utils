// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// Follows Claude Code waiting on the person, for the companion. While the
/// setting is on it keeps the wait hook in the watched Claude profile's
/// `settings.json`, reads the lines the hook appends as they come and says
/// how cross the companion should be. Turned off, it takes the hook out
/// again. Everything runs on the main thread; the file stays small.
final class ClaudeWaitService: ObservableObject {
    static let shared = ClaudeWaitService()

    /// Nil while nothing waits.
    @Published private(set) var stage: ClaudeWaitStage?
    /// The last time the hook could not be put in or taken out.
    @Published private(set) var installFailure: ClaudeHookInstaller.Failure?

    /// How often a wait is looked at again: its stage, its transcript and
    /// its timeout.
    static let checkInterval: TimeInterval = 5

    private var feed = ClaudeWaitFeed(since: .distantFuture)
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var timer: Timer?
    /// The settings file the hook was last put in, and with which executable.
    private var installed: (settings: URL, executable: String)?
    /// Each waiting session's transcript, once found.
    private var transcripts: [String: URL] = [:]
    private var watching = false
    private var preferences: AnyCancellable?

    private init() {}

    /// Syncs now and after every preference change, a moment later so a burst
    /// of changes is read once. On its own rather than through the island,
    /// so the hook also comes out while the island is off or has no screen.
    func startObservingPreferences() {
        sync()
        preferences = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var profileDirectory: URL { ClaudeAccountProfile.selected().configurationURL(home: home) }

    /// Puts the hook in or takes it out and starts or stops reading, as the
    /// preferences now say. Called on launch and on every preference change;
    /// it touches the settings file only when something it depends on changed.
    func sync() {
        guard NotchMascotSupport.waitsForClaude(), let executable = Bundle.main.executablePath else {
            stop()
            uninstall()
            return
        }
        let settings = profileDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
        if installed?.settings != settings || installed?.executable != executable {
            if let previous = installed, previous.settings != settings {
                remove(from: previous.settings, executable: previous.executable)
            }
            do {
                try ClaudeHookInstaller.apply(install: true, settingsURL: settings, executable: executable)
                installed = (settings, executable)
                installFailure = nil
            } catch {
                installFailure = error as? ClaudeHookInstaller.Failure ?? .unwritable
                installed = nil
            }
        }
        start()
    }

    /// Off: the hook comes out of the profile it was put in, and of the
    /// watched one, which an earlier run may have left it in.
    private func uninstall() {
        let executable = installed?.executable ?? Bundle.main.executablePath ?? ""
        if let previous = installed { remove(from: previous.settings, executable: previous.executable) }
        installed = nil
        remove(from: profileDirectory.appending(path: "settings.json", directoryHint: .notDirectory), executable: executable)
    }

    /// Takes out this build's hook, and any left by a build that is gone;
    /// another installed build keeps its own.
    private func remove(from settings: URL, executable: String) {
        guard FileManager.default.fileExists(atPath: settings.path) else { return }
        do {
            try ClaudeHookInstaller.apply(install: false, settingsURL: settings, executable: executable)
        } catch {
            installFailure = error as? ClaudeHookInstaller.Failure ?? .unwritable
        }
    }

    // MARK: Reading

    private func start() {
        guard !watching, let folder = ClaudeWaitHook.supportDirectory() else { return }
        watching = true
        feed = ClaudeWaitFeed(since: Date())
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        watch(ClaudeWaitHook.eventsURL(supportDirectory: folder), skippingExisting: true)
    }

    private func stop() {
        guard watching else { return }
        watching = false
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
        feed = ClaudeWaitFeed(since: .distantFuture)
        transcripts = [:]
        publish()
    }

    /// Opens the file for events. What it already holds is skipped when the
    /// app starts looking; a file made again after it was removed is read
    /// from its start.
    private func watch(_ url: URL, skippingExisting: Bool) {
        source?.cancel(); source = nil
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        offset = skippingExisting ? (fileSize(url) ?? 0) : 0
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // Watching the name, not the file that went away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.watching else { return }
                    self.watch(url, skippingExisting: false)
                }
                return
            }
            self.read(url)
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        read(url)
    }

    private func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    private func read(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // The hook empties the file past its limit and starts over.
        if let size = fileSize(url), size < offset { offset = 0 }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        feed.consume(data)
        check()
    }

    // MARK: Waiting

    /// Lets go of waits that timed out or whose session moved on, and
    /// publishes how cross the companion is now.
    private func check() {
        let now = Date()
        feed.tracker.expire(now: now)
        for session in feed.tracker.waits.keys {
            guard let transcript = transcript(for: session),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.modificationDate] as? Date
            else { continue }
            feed.tracker.transcriptChanged(session: session, at: modified)
        }
        transcripts = transcripts.filter { feed.tracker.waits[$0.key] != nil }
        publish()
        if feed.tracker.waits.isEmpty {
            timer?.invalidate(); timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func publish() {
        let next = feed.tracker.stage(now: Date())
        if stage != next { stage = next }
    }

    /// Claude Code names a session's transcript after the session, in the
    /// folder of the project it works in.
    private func transcript(for session: String) -> URL? {
        if let known = transcripts[session] { return known }
        let projects = profileDirectory.appending(path: "projects", directoryHint: .isDirectory)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let candidate = folder.appending(path: "\(session).jsonl", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                transcripts[session] = candidate
                return candidate
            }
        }
        return nil
    }
}
