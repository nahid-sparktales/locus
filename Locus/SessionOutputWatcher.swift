import CoreServices
import Foundation

/// Watches a workspace for files a run produces, so the Outputs list is not
/// limited to what a tool happened to name.
///
/// The two existing feeds both miss the common case. Tool events only describe
/// files a *file* tool touched, and a PDF is usually built by a shell command
/// (`pandoc`, a Python script, `wkhtmltopdf`) whose arguments say nothing about
/// its output. Git status misses anything gitignored — generated files
/// routinely are — and cannot help at all in the App Store build, whose default
/// workspace is not a repository.
///
/// A sibling of `WorkspaceKnowledgeWatcher` rather than a change to it: that
/// one deliberately discards event paths because the backend re-hashes
/// everything anyway, and this one needs exactly those paths.
final class SessionOutputWatcher {
    struct Change: Equatable {
        enum Effect: Equatable { case created, edited }
        let path: String
        let effect: Effect
    }

    /// Distinct paths reported per run. A build that writes thousands of files
    /// is not a list of outputs, and past this point the tool and git feeds
    /// still carry the precise answers.
    static let changeBudget = 50
    /// Paths examined per callback. Bounds the cost of one noisy batch.
    static let batchCeiling = 500
    /// How deep under the workspace a produced file is still plausibly one.
    static let depthCeiling = 12

    private var stream: FSEventStreamRef?
    private var handler: (([Change]) -> Void)?
    private var root = ""
    private var since = Date.distantPast
    private var reported: Set<String> = []
    private let lock = NSLock()

    /// - Parameter since: run start. Anything created at or after it is new;
    ///   anything older that changed is an edit.
    func start(
        path: String,
        since: Date,
        handler: @escaping ([Change]) -> Void
    ) {
        stop()
        guard !path.isEmpty else { return }
        self.handler = handler
        self.root = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
        self.since = since
        reported.removeAll()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let paths = paths.assumingMemoryBound(
                to: UnsafePointer<CChar>?.self
            ) as UnsafeMutablePointer<UnsafePointer<CChar>?>? else { return }
            let watcher = Unmanaged<SessionOutputWatcher>.fromOpaque(info).takeUnretainedValue()
            var found: [String] = []
            for index in 0..<min(count, SessionOutputWatcher.batchCeiling) {
                guard let raw = paths[index] else { continue }
                found.append(String(cString: raw))
            }
            watcher.consume(found)
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [self.root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    // Locus writes proxy templates and session logs of its own;
                    // the agent is a separate process, so its work still
                    // arrives.
                    | kFSEventStreamCreateFlagIgnoreSelf
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }
        // Cheaper than filtering in userspace, and the noisiest trees are known
        // up front. Nested copies still fall to `isIgnored`.
        _ = FSEventStreamSetExclusionPaths(stream, Self.exclusionPaths(root: self.root) as CFArray)
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        handler = nil
        reported.removeAll()
    }

    deinit { stop() }

    private func consume(_ paths: [String]) {
        var changes: [Change] = []
        for path in paths {
            lock.lock()
            let budgetReached = reported.count >= Self.changeBudget
            let alreadySeen = reported.contains(path)
            lock.unlock()
            if budgetReached || alreadySeen { continue }
            guard let change = Self.classify(path: path, root: root, runStart: since) else {
                continue
            }
            lock.lock()
            let inserted = reported.insert(path).inserted
            lock.unlock()
            if inserted { changes.append(change) }
        }
        guard !changes.isEmpty, let handler else { return }
        handler(changes)
    }

    /// FSEvents exclusion takes at most eight paths.
    static func exclusionPaths(root: String) -> [String] {
        [".git", "node_modules", ".venv", "build", "dist", ".next", "target", "DerivedData"]
            .map { URL(fileURLWithPath: root, isDirectory: true).appending(path: $0).path }
    }

    /// Whether this path is worth reporting, and as what.
    ///
    /// Deliberately not driven by the event flags. An atomic write — which
    /// `apply_patch` and most editors perform — creates a temporary file and
    /// renames it over the target, and FSEvents coalesces the flags, so an
    /// ordinary edit arrives carrying `ItemCreated`. The file's own creation
    /// date is the honest signal.
    static func classify(path: String, root: String, runStart: Date) -> Change? {
        guard let relative = relativePath(path, root: root), !isIgnored(relative) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .creationDateKey]
        ), values.isRegularFile == true else {
            // Gone again, or never a file: a coalesced create-then-delete is a
            // temporary, not an output.
            return nil
        }
        // Without a creation date, calling it an edit is the safe half — the
        // reducer promotes an edit to a create if a precise feed says so, but
        // never demotes a create.
        let created = values.creationDate.map { $0 >= runStart } ?? false
        return Change(path: relative, effect: created ? .created : .edited)
    }

    static func relativePath(_ path: String, root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    static func isIgnored(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= depthCeiling else { return true }
        let name = components[components.count - 1]
        let directories = components.dropLast()

        if components.contains(where: { $0.hasPrefix(".") }) { return true }
        if isTransient(name) { return true }
        // Build output is the one skipped tree that still has to be examined:
        // deliverables land there.
        if directories.contains(where: {
            ContextFileTypes.skippedDirectories.contains($0)
                && !ContextFileTypes.buildOutputDirectories.contains($0)
        }) {
            return true
        }

        let inBuildOutput = directories.contains {
            ContextFileTypes.buildOutputDirectories.contains($0)
        }
        if inBuildOutput {
            let ext = (name as NSString).pathExtension.lowercased()
            // `dist/report.pdf` is an output; `dist/main.js.map` is rubble.
            return !ContextFileTypes.deliverableExtensions.contains(ext)
        }
        return false
    }

    /// Editor scratch files and half-written downloads.
    private static func isTransient(_ name: String) -> Bool {
        if name == ".DS_Store" || name.hasPrefix(".#") || name.hasSuffix("~") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["tmp", "swp", "swo", "part", "crdownload", "lock"].contains(ext)
    }
}
