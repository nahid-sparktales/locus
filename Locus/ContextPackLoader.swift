import Foundation

enum ContextPackLoader {
    static func readContextSelection(
        _ selected: [URL],
        excluding existing: Set<URL>,
        limit: Int
    ) -> ContextLoadResult {
        guard limit > 0 else {
            return ContextLoadResult(files: [], notice: "Context packs support up to 50 files.")
        }
        let urls = expandedContextURLs(selected, limit: limit)
        var files: [ContextFile] = []
        var oversized = 0
        var unreadable = 0
        var overPackBudget = 0
        var totalBytes = 0

        for url in urls where files.count < limit {
            let normalized = url.standardizedFileURL
            guard !existing.contains(normalized) else { continue }
            let values = try? normalized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            guard size <= 256_000 else {
                oversized += 1
                continue
            }
            guard totalBytes + size <= 1_000_000 else {
                overPackBudget += 1
                continue
            }
            guard let data = try? Data(contentsOf: normalized, options: .mappedIfSafe),
                  let content = String(data: data, encoding: .utf8)
            else {
                unreadable += 1
                continue
            }
            totalBytes += data.count
            files.append(
                ContextFile(
                    url: normalized,
                    content: content,
                    modificationDate: values?.contentModificationDate
                )
            )
        }

        var warnings: [String] = []
        if oversized > 0 {
            warnings.append("\(oversized) oversized")
        }
        if unreadable > 0 {
            warnings.append("\(unreadable) binary or unreadable")
        }
        if overPackBudget > 0 {
            warnings.append("\(overPackBudget) over the 1 MB pack limit")
        }
        if urls.count == limit {
            warnings.append("selection capped at 50 text files")
        }
        let notice = warnings.isEmpty ? nil : "Skipped: \(warnings.joined(separator: ", "))."
        return ContextLoadResult(files: files, notice: notice)
    }

    static func reloadContextReference(_ reference: ContextFile) -> ContextFile {
        let url = reference.url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ContextFile(
                id: reference.id,
                url: url,
                isIncluded: false,
                issue: "File is missing"
            )
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard (values?.fileSize ?? 0) <= 256_000 else {
            return ContextFile(
                id: reference.id,
                url: url,
                isIncluded: false,
                modificationDate: values?.contentModificationDate,
                issue: "File is larger than 256 KB"
            )
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let content = String(data: data, encoding: .utf8)
        else {
            return ContextFile(
                id: reference.id,
                url: url,
                isIncluded: false,
                modificationDate: values?.contentModificationDate,
                issue: "File is unreadable or not UTF-8 text"
            )
        }
        return ContextFile(
            id: reference.id,
            url: url,
            content: content,
            isIncluded: reference.isIncluded,
            modificationDate: values?.contentModificationDate
        )
    }

    private static func expandedContextURLs(_ selected: [URL], limit: Int) -> [URL] {
        var output: [URL] = []

        for url in selected where output.count < limit {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                output.append(url)
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let child as URL in enumerator {
                if ContextFileTypes.skippedDirectories.contains(child.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard output.count < limit,
                      ContextFileTypes.allowedExtensions.contains(child.pathExtension.lowercased()),
                      (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                output.append(child)
            }
        }
        return output
    }
}
