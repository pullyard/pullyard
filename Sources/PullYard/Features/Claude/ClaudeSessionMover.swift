import Foundation

/// Moves Claude Code session history from one account's config folder to another's.
///
/// A session lives in `<config>/projects/<encoded cwd>/<id>.jsonl`, with optional
/// `<id>/` next to it (subagents, large tool results) and `<config>/file-history/<id>/`
/// (checkpoints for rewind). All of it moves, keeping the same relative paths, so
/// `claude --resume <id>` works under the target account afterwards.
enum ClaudeSessionMover {
    struct Result: Equatable {
        var moved = 0
        var skipped = 0
    }

    /// The config folder a session file belongs to: `<config>/projects/<dir>/<id>.jsonl`.
    static func configDir(of file: URL) -> URL {
        file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func move(sessionFiles files: [URL], to targetConfig: URL) throws -> Result {
        let fm = FileManager.default
        var result = Result()
        let target = targetConfig.standardizedFileURL
        for file in files {
            let source = configDir(of: file).standardizedFileURL
            guard source.resolvingSymlinksInPath().path != target.resolvingSymlinksInPath().path else { result.skipped += 1; continue }
            let id = file.deletingPathExtension().lastPathComponent
            let projectDir = file.deletingLastPathComponent().lastPathComponent
            let destDir = target.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(projectDir, isDirectory: true)
            let dest = destDir.appendingPathComponent(file.lastPathComponent)
            guard fm.fileExists(atPath: file.path), !fm.fileExists(atPath: dest.path) else { result.skipped += 1; continue }
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.moveItem(at: file, to: dest)
            result.moved += 1

            let sidecar = file.deletingLastPathComponent().appendingPathComponent(id, isDirectory: true)
            let sidecarDest = destDir.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: sidecar.path), !fm.fileExists(atPath: sidecarDest.path) {
                try? fm.moveItem(at: sidecar, to: sidecarDest)
            }
            let history = source.appendingPathComponent("file-history", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            let historyDest = target.appendingPathComponent("file-history", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: history.path), !fm.fileExists(atPath: historyDest.path) {
                try? fm.createDirectory(at: historyDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: history, to: historyDest)
            }
            let oldDir = file.deletingLastPathComponent()
            if let left = try? fm.contentsOfDirectory(atPath: oldDir.path), left.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: oldDir)
            }
        }
        return result
    }
}
