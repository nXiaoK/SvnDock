import Foundation
import SvnDockCore

struct SvnDockIgnoreRecommendation: Identifiable, Hashable, Sendable {
    let rule: SvnDockIgnoreRule
    let reason: String
    let project: String
    var id: String { rule.targetRelativePath }
}

struct SvnDockIgnoreRecommendationPlan: Sendable {
    let workingCopy: SvnDockWorkingCopy
    let items: [SvnDockIgnoreRecommendation]
    let scannedDirectories: Int
    let isPartial: Bool
}

/// Reads names and node metadata only. No project code or configuration is run.
enum SvnDockIgnoreRecommendationScanner {
    struct Limits: Sendable {
        var directories = 300
        var entries = 20_000
        var depth = 10
    }

    static func scan(in copy: SvnDockWorkingCopy, statuses: [StatusEntry],
                     limits: Limits = Limits()) throws -> SvnDockIgnoreRecommendationPlan {
        let root = copy.rootURL.resolvingSymlinksInPath().standardizedFileURL
        var indexed: [String: StatusEntry] = [:]
        var blocked = Set<String>()
        for status in statuses {
            let url = status.path.hasPrefix("/") ? URL(fileURLWithPath: status.path)
                : root.appendingPathComponent(status.path)
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: root.pathComponents) else { continue }
            let relative = components.dropFirst(root.pathComponents.count).joined(separator: "/")
            let path = relative.isEmpty ? "." : relative
            indexed[path] = status
            if status.status == .external || status.isFileExternal == true || status.isSwitched
                || status.isCopied || status.isTreeConflicted || status.propertyStatus == .conflicted
                || [.ignored, .conflicted, .missing, .deleted, .replaced, .obstructed].contains(status.status) {
                blocked.insert(path)
            }
        }
        let opaqueNames: Set<String> = [".svn", ".git", ".hg", "node_modules", "vendor", "Pods", "Carthage",
            ".github", "outputs", ".build", "DerivedData", "target", "build", "dist", "bin", "obj", ".venv", "venv", "env",
            "__pycache__", ".next", ".nuxt", ".output", ".gradle", ".dart_tool", ".tox", "coverage"]
        var pending: [(path: String, depth: Int, projects: Set<String>)] = [(".", 0, [])]
        var offset = 0
        var visited = 0
        var inspected = 0
        var partial = false
        var items: [SvnDockIgnoreRecommendation] = []
        while offset < pending.count {
            try Task.checkCancellation()
            guard visited < limits.directories, inspected < limits.entries else { partial = true; break }
            let current = pending[offset]
            offset += 1
            if blocked.contains(current.path) { continue }
            let directory = current.path == "." ? root : root.appendingPathComponent(current.path)
            guard safeDirectory(directory, root: root) else { continue }
            let urls: [URL]
            do { urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch { partial = true; continue }
            visited += 1
            let names = Set(urls.map(\.lastPathComponent))
            let projects = current.projects.union(detectProjects(names))
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                inspected += 1
                guard inspected <= limits.entries else { partial = true; break }
                let name = url.lastPathComponent
                // Git metadata can be ignored by SVN, but must remain opaque
                // to the scanner. Never inspect SVN's own administrative data.
                guard name != ".svn", name != ".hg" else { continue }
                let path = current.path == "." ? name : current.path + "/" + name
                guard !blocked.contains(path),
                      let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
                      type == .typeDirectory || type == .typeRegular else { continue }
                let directoryNode = type == .typeDirectory
                if directoryNode, !safeDirectory(url, root: root) { continue }
                let status = indexed[path]?.status
                let unversioned = status == .unversioned || (status == nil && hasUnversionedAncestor(path, indexed: indexed))
                if unversioned, let match = recommendation(name: name, directory: directoryNode,
                                                          parent: current.path, projects: projects) {
                    items.append(.init(rule: .init(targetRelativePath: path, parentRelativePath: current.path,
                                                  pattern: name, mode: .name), reason: match.reason, project: match.project))
                    if directoryNode { continue }
                }
                if directoryNode, !opaqueNames.contains(name) {
                    if current.depth < limits.depth, pending.count < limits.directories {
                        pending.append((path, current.depth + 1, projects))
                    } else { partial = true }
                }
            }
        }
        return .init(workingCopy: copy, items: items.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
                     scannedDirectories: visited, isPartial: partial)
    }

    private static func hasUnversionedAncestor(_ path: String, indexed: [String: StatusEntry]) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if let status = indexed[parent] { return status.status == .unversioned }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Reject all symlink components and nested WCs, even if inside the root.
    static func safeDirectory(_ directory: URL, root: URL) -> Bool {
        let relative = directory.standardizedFileURL.pathComponents
        guard relative.starts(with: root.pathComponents) else { return false }
        var cursor = root
        for component in relative.dropFirst(root.pathComponents.count) {
            cursor.appendPathComponent(component)
            guard let type = (try? FileManager.default.attributesOfItem(atPath: cursor.path))?[.type] as? FileAttributeType,
                  type == .typeDirectory,
                  !FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".svn").path) else { return false }
        }
        return true
    }

    private static func detectProjects(_ names: Set<String>) -> Set<String> {
        var types = Set<String>()
        if names.contains("package.json") { types.insert("Node.js") }
        if names.contains("pom.xml") { types.insert("Maven") }
        if !names.isDisjoint(with: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]) { types.insert("Gradle") }
        if !names.isDisjoint(with: ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"]) { types.insert("Python") }
        if names.contains("Package.swift") { types.insert("Swift") }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { types.insert("Xcode") }
        if names.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".sln") }) { types.insert(".NET") }
        if names.contains("Cargo.toml") { types.insert("Rust") }
        if names.contains("pubspec.yaml") { types.insert("Dart / Flutter") }
        return types
    }

    private static func recommendation(name: String, directory: Bool, parent: String,
                                       projects: Set<String>) -> (project: String, reason: String)? {
        if !directory, [".DS_Store", "Thumbs.db", "desktop.ini"].contains(name) {
            return ("系统文件", "操作系统生成的目录元数据")
        }
        if name == ".git" {
            return ("Git", "Git 本地仓库元数据或工作树引用；忽略后仍保留在磁盘上")
        }
        if directory {
            switch name {
            case ".github":
                return ("GitHub", "GitHub 工作流和协作配置；如需在 SVN 中共享，请取消勾选")
            case ".idea":
                return ("JetBrains IDE", "IDE 项目配置和工作区状态；如需在 SVN 中共享，请取消勾选")
            case "outputs":
                return ("项目输出", "常见输出目录；如包含需要纳管的交付文件，请取消勾选")
            default: break
            }
        }
        if (parent as NSString).lastPathComponent == ".idea",
           (!directory && ["workspace.xml", "tasks.xml", "usage.statistics.xml"].contains(name)
            || directory && name == "shelf") {
            return ("JetBrains IDE", "个人工作区状态；保留团队共享的项目配置")
        }
        if directory, name == "xcuserdata", projects.contains("Xcode") {
            return ("Xcode", "本机用户的 IDE 状态")
        }
        let candidates: [(String, Set<String>, String)] = [
            ("Node.js", ["node_modules", "dist", "build", ".next", ".nuxt", ".output", ".vite", ".turbo", ".parcel-cache", ".svelte-kit", "coverage"], "依赖、构建输出或测试覆盖率"),
            ("Maven", ["target"], "Maven 编译输出"),
            ("Gradle", [".gradle", "build"], "Gradle 缓存或编译输出"),
            ("Python", [".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox"], "虚拟环境或 Python 缓存"),
            ("Swift", [".build"], "Swift Package Manager 构建输出"),
            ("Xcode", ["DerivedData"], "Xcode 构建缓存"),
            (".NET", ["bin", "obj"], ".NET 编译输出"),
            ("Rust", ["target"], "Cargo 编译输出"),
            ("Dart / Flutter", [".dart_tool", "build"], "Dart / Flutter 工具缓存和构建输出")
        ]
        for (project, names, reason) in candidates where directory && projects.contains(project) && names.contains(name) {
            return (project, reason)
        }
        return nil
    }
}
