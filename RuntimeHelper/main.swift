import Darwin
import Foundation

// A signed launch agent replaces itself with the installed immutable runtime.
// launchd owns the resulting process; it has no dependency on the desktop PID.
let manager = FileManager.default
let root = manager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Locus/Runtime")
do {
    let data = try Data(contentsOf: root.appending(path: "launch.json"))
    guard let configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let package = configuration["package"] as? String,
          let workspace = configuration["workspace"] as? String,
          URL(fileURLWithPath: package).resolvingSymlinksInPath().path.hasPrefix(root.appending(path: "versions").path + "/")
    else { exit(78) }
    let environmentPath = package + "/source:" + package + "/site-packages"
    setenv("PYTHONPATH", environmentPath, 1)
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
    setenv("PYTHONUNBUFFERED", "1", 1)
    setenv("LOCUS_DOCUMENT_COORDINATOR", "1", 1)
    unsetenv("LOCUS_PARENT_PID")
    if let helper = configuration["codex"] as? String, !helper.isEmpty {
        setenv("LOCUS_CODEX_APP_SERVER_PATH", helper, 1)
    }
    setenv("LOCUS_CODEX_HOME", root.deletingLastPathComponent().appending(path: "Codex").path, 1)
    let python = package + "/python/bin/python3"
    let arguments = ["/usr/bin/env", python, "-m", "ollama_code.runtime", "--home", root.path,
                     "--cwd", workspace, "--port", String(configuration["port"] as? Int ?? 8793)]
    let pointers = arguments.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    pointers.withUnsafeBufferPointer { buffer in _ = execv("/usr/bin/env", buffer.baseAddress!) }
    exit(71)
} catch { exit(78) }
