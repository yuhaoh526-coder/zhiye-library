import AppKit
import Combine
import CryptoKit
import PDFKit

struct Collection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

struct Paper: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var originalName: String
    var fileName: String
    var sha256: String
    var collectionID: UUID?
    var addedAt: Date
    var pageCount: Int
    var lastPage: Int = 0
    var notes: String = ""
}

struct LibraryData: Codable {
    var version = 1
    var collections: [Collection] = []
    var papers: [Paper] = []
}

enum LibraryError: LocalizedError {
    case invalidPDF(String), unsupportedVersion, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidPDF(let name): return "“\(name)”不是可读取的 PDF，或文件已加密。"
        case .unsupportedVersion: return "文献库由更新版本创建，请使用兼容版本打开。"
        case .unavailable: return "文献库无法读取。为保护原有数据，已暂停修改。"
        }
    }
}

struct PreparedPaper: Sendable {
    let paper: Paper
    let destination: URL
}

extension Paper: Sendable {}
extension Collection: Sendable {}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var data = LibraryData()
    @Published var issue: String?
    @Published var notice: String?
    @Published private(set) var importing = false
    @Published private(set) var available = true
    let root: URL
    private var pendingSave: Task<Void, Never>?
    var papersFolder: URL { root.appendingPathComponent("PDFs", isDirectory: true) }
    var indexURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhiyeLibrary", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: papersFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let decoded = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: indexURL))
                guard decoded.version == 1 else { throw LibraryError.unsupportedVersion }
                data = decoded
            }
        } catch {
            available = false
            issue = "无法打开文献库：\(error.localizedDescription)\n原始文件已保留。文献库位置：\(self.root.path)"
        }
    }

    func url(for paper: Paper) -> URL { papersFolder.appendingPathComponent(paper.fileName) }

    func save() throws {
        guard available else { throw LibraryError.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: indexURL, options: .atomic)
    }

    @discardableResult
    private func change(_ action: (inout LibraryData) -> Void) -> Bool {
        guard available else { issue = LibraryError.unavailable.localizedDescription; return false }
        let previous = data
        action(&data)
        do { try save(); return true }
        catch { data = previous; issue = "保存失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    func addCollection(_ rawName: String) -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !data.collections.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            issue = "已经有同名分类。"; return nil
        }
        let collection = Collection(name: name)
        return change { $0.collections.append(collection) } ? collection.id : nil
    }

    func renameCollection(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !data.collections.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            issue = "已经有同名分类。"; return
        }
        change { library in
            if let i = library.collections.firstIndex(where: { $0.id == id }) { library.collections[i].name = name }
        }
    }

    func deleteCollection(_ id: UUID) {
        change { library in
            library.collections.removeAll { $0.id == id }
            for i in library.papers.indices where library.papers[i].collectionID == id { library.papers[i].collectionID = nil }
        }
    }

    func updatePaper(_ id: UUID, title: String, notes: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        change { library in
            if let i = library.papers.firstIndex(where: { $0.id == id }) {
                library.papers[i].title = title
                library.papers[i].notes = notes
            }
        }
    }

    func movePaper(_ id: UUID, to collectionID: UUID?) {
        change { library in
            if let i = library.papers.firstIndex(where: { $0.id == id }) { library.papers[i].collectionID = collectionID }
        }
    }

    // Removing an entry keeps its managed PDF in PDFs/ so the action never destroys a document.
    func removePaper(_ id: UUID) { change { $0.papers.removeAll { $0.id == id } } }

    func rememberPage(_ id: UUID, page: Int) {
        guard available, let i = data.papers.firstIndex(where: { $0.id == id }) else { return }
        let validPage = min(max(page, 0), max(data.papers[i].pageCount - 1, 0))
        guard data.papers[i].lastPage != validPage else { return }
        data.papers[i].lastPage = validPage
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel()
        guard available else { return }
        do { try save() } catch { issue = "阅读位置保存失败：\(error.localizedDescription)" }
    }

    static nonisolated func prepare(_ source: URL, folder: URL, collectionID: UUID?, knownHashes: Set<String>) throws -> PreparedPaper? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0 else {
            throw LibraryError.invalidPDF(source.lastPathComponent)
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if knownHashes.contains(hash) { return nil }
        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = folder.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        let paper = Paper(id: id, title: source.deletingPathExtension().lastPathComponent,
                          originalName: source.lastPathComponent, fileName: fileName, sha256: hash,
                          collectionID: collectionID, addedAt: Date(), pageCount: document.pageCount)
        return PreparedPaper(paper: paper, destination: destination)
    }

    func importPDFs(_ urls: [URL], into collectionID: UUID?) async {
        guard available, !importing, !urls.isEmpty else { return }
        importing = true
        defer { importing = false }
        notice = "正在导入 \(urls.count) 个文件…"
        var known = Set(data.papers.map(\.sha256))
        var prepared: [PreparedPaper] = []
        var failures: [String] = []
        var duplicates = 0
        let folder = papersFolder
        for (offset, source) in urls.enumerated() {
            let hashes = known
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.prepare(source, folder: folder, collectionID: collectionID, knownHashes: hashes)
                }.value
                if let result { prepared.append(result); known.insert(result.paper.sha256) }
                else { duplicates += 1 }
            } catch { failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
            notice = "正在导入 \(offset + 1) / \(urls.count)…"
        }
        let validCollection = data.collections.contains { $0.id == collectionID } ? collectionID : nil
        let saved = change { library in
            library.papers.append(contentsOf: prepared.map { item in
                var paper = item.paper; paper.collectionID = validCollection; return paper
            })
        }
        if !saved {
            // Roll back only copies created by this import, preserving all original files.
            for item in prepared { try? FileManager.default.removeItem(at: item.destination) }
            notice = "导入未保存，请检查文献库权限或磁盘空间。"
            return
        }
        notice = "已导入 \(prepared.count) 篇" + (duplicates > 0 ? "，跳过 \(duplicates) 个重复文件" : "") + (failures.isEmpty ? "" : "，\(failures.count) 个文件失败")
        if !failures.isEmpty { issue = failures.joined(separator: "\n") }
    }
}
