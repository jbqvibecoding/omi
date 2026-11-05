import Accelerate
import CryptoKit
import Foundation
import GRDB

/// One retrieval hit from the user's notes folder.
struct NotesKBHit: Sendable {
    let chunkText: String
    let relativePath: String
    let headerContext: String
    let documentTitle: String
    let score: Float
    /// Adjacent sibling chunks from the same file (context expansion).
    let contextBefore: String?
    let contextAfter: String?

    /// e.g. "sales/pricing.md > Pricing tiers"
    var breadcrumb: String {
        headerContext.isEmpty ? relativePath : "\(relativePath) > \(headerContext)"
    }
}

/// Embedding index over the user's notes folder (.md/.txt — Obsidian-vault friendly),
/// so the live copilot can surface relevant notes when a key question comes up mid-meeting.
///
/// Ported from OpenOats' KnowledgeBase (header-aware markdown chunking, sha256-keyed
/// incremental re-embedding, multi-query max-cosine fusion), adapted to omi's stack:
/// embeddings via the shared Gemini `EmbeddingService` (normalized at index time) and
/// persistence in the Rewind GRDB database instead of a JSON cache.
actor NotesKnowledgeBase {
    static let shared = NotesKnowledgeBase()

    /// Chunk sizing (words). Sections below the min merge with neighbors; above the max
    /// they split with 20% overlap. Same tuning as OpenOats.
    private static let targetMinWords = 80
    private static let targetMaxWords = 500
    /// Similarity floor below which a chunk is not considered a match at all.
    private static let minSimilarity: Float = 0.1
    /// Candidates kept after score fusion, before topK truncation.
    private static let maxCandidates = 10
    /// Cap on chunks held in memory for search (~12KB each at 3072-dim ≈ 60MB).
    private static let maxLoadedChunks = 5000
    private static let embedBatchSize = 100

    private struct LoadedChunk {
        let id: Int64
        let relativePath: String
        let headerContext: String
        let documentTitle: String
        let chunkIndex: Int
        let chunkText: String
        let embedding: [Float]
    }

    private var _dbQueue: DatabasePool?
    private var loadedChunks: [LoadedChunk] = []
    private var chunksLoaded = false
    private var isIndexing = false

    // UserDefaults keys for cache-invalidation metadata (not user settings).
    private static let fingerprintKey = "copilotNotesKBFingerprint"
    private static let folderKey = "copilotNotesKBFolder"

    private init() {}

    // MARK: - Database

    private func ensureDB() async throws -> DatabasePool {
        if let db = _dbQueue { return db }
        try await RewindDatabase.shared.initialize()
        guard let db = await RewindDatabase.shared.getDatabaseQueue() else {
            throw NotesKBError.databaseNotInitialized
        }
        _dbQueue = db
        return db
    }

    // MARK: - Public API

    struct IndexResult: Sendable {
        var scannedFiles = 0
        var reusedFiles = 0
        var embeddedFiles = 0
        var embeddedChunks = 0
        var removedStaleFiles = 0
        var totalChunks = 0
        var error: String?
    }

    struct Stats: Sendable {
        let files: Int
        let chunks: Int
    }

    func stats() async -> Stats {
        guard let db = try? await ensureDB() else { return Stats(files: 0, chunks: 0) }
        do {
            return try await db.read { database in
                let chunks = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM notes_kb_chunks") ?? 0
                let files =
                    try Int.fetchOne(database, sql: "SELECT COUNT(DISTINCT cacheKey) FROM notes_kb_chunks") ?? 0
                return Stats(files: files, chunks: chunks)
            }
        } catch {
            return Stats(files: 0, chunks: 0)
        }
    }

    /// Index (or incrementally re-index) the configured notes folder. Unchanged files
    /// (same path + content hash) keep their stored embeddings; changed files re-embed;
    /// rows for deleted files are pruned. A provider/model change invalidates everything.
    func index() async -> IndexResult {
        var result = IndexResult()
        let folderPath = await MainActor.run { CopilotSettings.shared.notesFolderPath }
        guard let folderPath, !folderPath.isEmpty else {
            result.error = "No notes folder configured"
            return result
        }
        guard !isIndexing else {
            result.error = "Indexing already in progress"
            return result
        }
        isIndexing = true
        defer { isIndexing = false }

        let db: DatabasePool
        do {
            db = try await ensureDB()
        } catch {
            result.error = "Database not available: \(error)"
            return result
        }

        // Invalidate everything if the embedding config or folder changed.
        let fingerprint = Self.embeddingConfigFingerprint()
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.fingerprintKey) != fingerprint
            || defaults.string(forKey: Self.folderKey) != folderPath
        {
            try? await db.write { database in
                try database.execute(sql: "DELETE FROM notes_kb_chunks")
            }
            defaults.set(fingerprint, forKey: Self.fingerprintKey)
            defaults.set(folderPath, forKey: Self.folderKey)
        }

        // Scan the folder (pure file I/O).
        let folderURL = URL(fileURLWithPath: folderPath)
        let scanned = Self.scanFiles(in: folderURL)
        result.scannedFiles = scanned.count

        // Which files are already indexed with the same content?
        let existingKeys: Set<String>
        do {
            existingKeys = try await db.read { database in
                Set(try String.fetchAll(database, sql: "SELECT DISTINCT cacheKey FROM notes_kb_chunks"))
            }
        } catch {
            result.error = "Failed to read index: \(error)"
            return result
        }

        let currentKeys = Set(scanned.map(\.cacheKey))
        let filesToEmbed = scanned.filter { !existingKeys.contains($0.cacheKey) }
        result.reusedFiles = scanned.count - filesToEmbed.count

        // Prune rows whose file was deleted or whose content changed.
        let staleKeys = existingKeys.subtracting(currentKeys)
        if !staleKeys.isEmpty {
            result.removedStaleFiles = staleKeys.count
            try? await db.write { database in
                for key in staleKeys {
                    try database.execute(sql: "DELETE FROM notes_kb_chunks WHERE cacheKey = ?", arguments: [key])
                }
            }
        }

        // Embed new/changed files in batches. The breadcrumb prefix (path > header) is
        // part of the embedded text for better retrieval, matching OpenOats.
        struct PendingChunk {
            let file: ScannedFile
            let chunkIndex: Int
            let text: String
            let header: String
            let embedText: String
        }
        var pending: [PendingChunk] = []
        for file in filesToEmbed {
            for (i, chunk) in file.chunks.enumerated() {
                let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                var prefix = file.relativePath
                if !chunk.header.isEmpty { prefix += " > \(chunk.header)" }
                pending.append(
                    PendingChunk(
                        file: file, chunkIndex: i, text: chunk.text, header: chunk.header,
                        embedText: "\(prefix)\n\(trimmed)"))
            }
        }

        var offset = 0
        while offset < pending.count {
            let batch = Array(pending[offset..<min(offset + Self.embedBatchSize, pending.count)])
            do {
                // embedBatch normalizes each vector, so search is a plain dot product.
                let embeddings = try await EmbeddingService.shared.embedBatch(
                    texts: batch.map(\.embedText), taskType: "RETRIEVAL_DOCUMENT")
                guard embeddings.count == batch.count else {
                    result.error = "Embedding count mismatch (\(embeddings.count)/\(batch.count))"
                    break
                }
                try await db.write { database in
                    for (i, item) in batch.enumerated() {
                        try database.execute(
                            sql: """
                                INSERT INTO notes_kb_chunks
                                (cacheKey, relativePath, headerContext, documentTitle, chunkIndex, chunkText, embedding, indexedAt)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                item.file.cacheKey, item.file.relativePath, item.header,
                                item.file.documentTitle, item.chunkIndex, item.text,
                                Self.floatsToData(embeddings[i]), Date(),
                            ])
                    }
                }
                result.embeddedChunks += batch.count
            } catch {
                result.error = "Embedding failed at chunk \(offset): \(error)"
                break
            }
            offset += batch.count
        }
        result.embeddedFiles = filesToEmbed.count

        if let db = try? await ensureDB(),
            let total = try? await db.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notes_kb_chunks") })
        {
            result.totalChunks = total ?? 0
        }

        chunksLoaded = false  // force reload on next search
        log(
            "NotesKnowledgeBase: indexed \(result.embeddedFiles) files (\(result.embeddedChunks) chunks), "
                + "reused \(result.reusedFiles), pruned \(result.removedStaleFiles), total \(result.totalChunks) chunks"
        )
        return result
    }

    /// Remove all indexed chunks (e.g. when the user clears the notes folder).
    func clearIndex() async {
        guard let db = try? await ensureDB() else { return }
        try? await db.write { database in
            try database.execute(sql: "DELETE FROM notes_kb_chunks")
        }
        loadedChunks = []
        chunksLoaded = false
    }

    /// Multi-query search with max-cosine score fusion across queries. Both sides are
    /// normalized, so cosine similarity is a single vDSP dot product per chunk.
    func search(queries: [String], topK: Int = 3) async -> [NotesKBHit] {
        let validQueries = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !validQueries.isEmpty else { return [] }

        await loadChunksIfNeeded()
        guard !loadedChunks.isEmpty else { return [] }

        let queryEmbeddings: [[Float]]
        do {
            queryEmbeddings = try await EmbeddingService.shared.embedBatch(
                texts: validQueries, taskType: "RETRIEVAL_QUERY")
        } catch {
            log("NotesKnowledgeBase: query embed failed: \(error)")
            return []
        }

        var bestScores: [Int: Float] = [:]
        for queryEmb in queryEmbeddings {
            for i in 0..<loadedChunks.count {
                let sim = Self.dotProduct(queryEmb, loadedChunks[i].embedding)
                if sim > Self.minSimilarity {
                    bestScores[i] = max(bestScores[i] ?? 0, sim)
                }
            }
        }

        let top = bestScores.sorted { $0.value > $1.value }.prefix(Self.maxCandidates).prefix(topK)
        return top.map { index, score in
            let chunk = loadedChunks[index]
            return NotesKBHit(
                chunkText: chunk.chunkText,
                relativePath: chunk.relativePath,
                headerContext: chunk.headerContext,
                documentTitle: chunk.documentTitle,
                score: score,
                contextBefore: siblingText(of: chunk, delta: -1),
                contextAfter: siblingText(of: chunk, delta: +1)
            )
        }
    }

    // MARK: - Debug (omi-ctl)

    func debugIndex() async -> [String: String] {
        let r = await index()
        return [
            "scanned_files": String(r.scannedFiles),
            "embedded_files": String(r.embeddedFiles),
            "embedded_chunks": String(r.embeddedChunks),
            "reused_files": String(r.reusedFiles),
            "pruned_files": String(r.removedStaleFiles),
            "total_chunks": String(r.totalChunks),
            "error": r.error ?? "",
        ]
    }

    func debugSearch(query: String) async -> [String: String] {
        let hits = await search(queries: [query], topK: 3)
        var out: [String: String] = ["hits": String(hits.count)]
        for (i, hit) in hits.enumerated() {
            out["hit_\(i)"] = "\(hit.breadcrumb) (score \(String(format: "%.3f", hit.score)))"
            out["hit_\(i)_text"] = String(hit.chunkText.prefix(160))
        }
        return out
    }

    // MARK: - In-memory chunk cache

    private func loadChunksIfNeeded() async {
        guard !chunksLoaded else { return }
        guard let db = try? await ensureDB() else { return }
        do {
            let rows = try await db.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, relativePath, headerContext, documentTitle, chunkIndex, chunkText, embedding
                        FROM notes_kb_chunks ORDER BY id DESC LIMIT ?
                        """, arguments: [Self.maxLoadedChunks])
            }
            loadedChunks = rows.compactMap { row in
                guard let embedding = Self.dataToFloats(row["embedding"]) else { return nil }
                return LoadedChunk(
                    id: row["id"], relativePath: row["relativePath"], headerContext: row["headerContext"],
                    documentTitle: row["documentTitle"], chunkIndex: row["chunkIndex"],
                    chunkText: row["chunkText"], embedding: embedding)
            }
            chunksLoaded = true
        } catch {
            log("NotesKnowledgeBase: failed to load chunks: \(error)")
        }
    }

    private func siblingText(of chunk: LoadedChunk, delta: Int) -> String? {
        let wanted = chunk.chunkIndex + delta
        guard wanted >= 0 else { return nil }
        return loadedChunks.first { $0.relativePath == chunk.relativePath && $0.chunkIndex == wanted }?.chunkText
    }

    // MARK: - File scanning & chunking (pure, nonisolated)

    private struct ScannedFile {
        let cacheKey: String  // "relativePath:sha256"
        let relativePath: String
        let documentTitle: String
        let chunks: [(text: String, header: String)]
    }

    private nonisolated static func scanFiles(in folderURL: URL) -> [ScannedFile] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }

        var files: [ScannedFile] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "md" || ext == "txt" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let relativePath =
                fileURL.path.hasPrefix(folderURL.path)
                ? String(fileURL.path.dropFirst(folderURL.path.count).drop(while: { $0 == "/" }))
                : fileURL.lastPathComponent
            let title =
                extractDocumentTitle(from: content)
                ?? fileURL.deletingPathExtension().lastPathComponent
            files.append(
                ScannedFile(
                    cacheKey: "\(relativePath):\(sha256(content))",
                    relativePath: relativePath,
                    documentTitle: title,
                    chunks: chunkMarkdown(content)))
        }
        return files
    }

    /// First H1 heading, or nil.
    private nonisolated static func extractDocumentTitle(from content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Splits markdown into chunks aware of the header hierarchy: sections under
    /// `targetMinWords` merge with neighbors, sections over `targetMaxWords` split
    /// with 20% overlap. Ported from OpenOats' chunkMarkdownStatic.
    nonisolated static func chunkMarkdown(_ text: String) -> [(text: String, header: String)] {
        let lines = text.components(separatedBy: .newlines)

        struct Section {
            var headers: [String]  // hierarchy stack
            var lines: [String]
        }

        var sections: [Section] = []
        var current = Section(headers: [], lines: [])

        for line in lines {
            if line.hasPrefix("#") {
                if !current.lines.isEmpty {
                    sections.append(current)
                }
                let trimmed = line.drop(while: { $0 == "#" })
                let level = line.count - trimmed.count
                let headerText = String(trimmed).trimmingCharacters(in: .whitespaces)

                // Keep headers at higher levels, replace at the current level.
                var newHeaders = current.headers
                if level <= newHeaders.count {
                    newHeaders = Array(newHeaders.prefix(level - 1))
                }
                newHeaders.append(headerText)
                current = Section(headers: newHeaders, lines: [])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.isEmpty {
            sections.append(current)
        }

        var result: [(text: String, header: String)] = []
        var pendingText = ""
        var pendingHeader = ""

        for section in sections {
            let sectionText = section.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionText.isEmpty else { continue }

            let breadcrumb = section.headers.joined(separator: " > ")
            let wordCount = sectionText.split(separator: " ").count

            if wordCount < targetMinWords {
                if pendingText.isEmpty {
                    pendingText = sectionText
                    pendingHeader = breadcrumb
                } else {
                    pendingText += "\n\n" + sectionText
                    if !breadcrumb.isEmpty { pendingHeader = breadcrumb }
                }
                if pendingText.split(separator: " ").count >= targetMinWords {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }
            } else if wordCount > targetMaxWords {
                if !pendingText.isEmpty {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }
                let words = sectionText.split(separator: " ", omittingEmptySubsequences: true)
                let overlap = targetMaxWords / 5
                var start = 0
                while start < words.count {
                    let end = min(start + targetMaxWords, words.count)
                    result.append((text: words[start..<end].joined(separator: " "), header: breadcrumb))
                    start += targetMaxWords - overlap
                }
            } else {
                if !pendingText.isEmpty {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }
                result.append((text: sectionText, header: breadcrumb))
            }
        }
        if !pendingText.isEmpty {
            result.append((text: pendingText, header: pendingHeader))
        }

        // No headers / short doc: chunk the whole text.
        if result.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let words = text.split(separator: " ", omittingEmptySubsequences: true)
            if words.count <= targetMaxWords {
                result.append((text: text.trimmingCharacters(in: .whitespacesAndNewlines), header: ""))
            } else {
                let overlap = targetMaxWords / 5
                var start = 0
                while start < words.count {
                    let end = min(start + targetMaxWords, words.count)
                    result.append((text: words[start..<end].joined(separator: " "), header: ""))
                    start += targetMaxWords - overlap
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Any change to the embedding provider/model invalidates all stored vectors.
    private nonisolated static func embeddingConfigFingerprint() -> String {
        "gemini|\(EmbeddingService.modelName)|n1"
    }

    private nonisolated static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    private nonisolated static func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private nonisolated static func dataToFloats(_ data: Data?) -> [Float]? {
        guard let data, data.count % MemoryLayout<Float>.size == 0, !data.isEmpty else { return nil }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats
    }
}

enum NotesKBError: Error {
    case databaseNotInitialized
}
