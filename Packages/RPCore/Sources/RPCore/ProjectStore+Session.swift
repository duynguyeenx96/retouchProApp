import Foundation

/// The "project = session" files (docs/ADR-0025): each shot's brush strokes and
/// undo/redo history, and the project's `session.json`.
///
/// Rules shared by all three:
///
/// * **Written through ``AtomicFileWriter``** — a crash mid-write leaves the
///   previous file, never half of one.
/// * **Versioned** — each file carries a `formatVersion`; a file from a newer
///   build throws ``ProjectStoreError/unsupportedFormatVersion(found:supported:)``
///   rather than being half-understood.
/// * **Absent is normal** — an untouched shot has no strokes and no history, a
///   project nobody has left yet has no session. Loading an absent file returns
///   the empty value, not an error.
/// * **Optional to the document opening.** The loaders throw on a corrupt or
///   future file; callers (``EditorModel`` in RPUI) catch that and carry on with
///   the empty value, so a damaged side file never stops a project from opening.
extension ProjectStore {

    // MARK: - Brush strokes — edits/<shot id>.strokes.json

    public func manualMaskStrokesURL(for shotID: ShotID) -> URL {
        editsURL.appendingPathComponent(
            "\(shotID.rawValue)\(ProjectBundle.manualMaskStrokesSuffix)")
    }

    /// The shot's brush strokes, oldest first; `[]` when the file is absent.
    public func loadManualMaskStrokes(
        for shotID: ShotID, fileManager: FileManager = .default
    ) throws -> [ManualMaskStroke] {
        let url = manualMaskStrokesURL(for: shotID)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try RPJSON.decoder.decode(
            ManualMaskStrokeDocument.self, from: try Data(contentsOf: url)
        ).strokes
    }

    /// Writes the strokes atomically, or **deletes the file** when there are
    /// none — "no file" and "nothing painted" are the same state, the same rule
    /// `edits/<id>.json` follows for an untouched shot.
    public func saveManualMaskStrokes(
        _ strokes: [ManualMaskStroke], for shotID: ShotID, fileManager: FileManager = .default
    ) throws {
        let url = manualMaskStrokesURL(for: shotID)
        guard !strokes.isEmpty else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: editsURL, withIntermediateDirectories: true)
        try writer.write(
            try RPJSON.compactEncoder.encode(ManualMaskStrokeDocument(strokes: strokes)), to: url)
    }

    // MARK: - Undo history — history/<shot id>.json

    public var historyURL: URL {
        bundleURL.appendingPathComponent(ProjectBundle.historyDirectory)
    }

    public func historyURL(for shotID: ShotID) -> URL {
        historyURL.appendingPathComponent("\(shotID.rawValue).json")
    }

    /// The shot's history; empty when the file is absent.
    public func loadShotHistory(
        for shotID: ShotID, fileManager: FileManager = .default
    ) throws -> ShotHistory {
        let url = historyURL(for: shotID)
        guard fileManager.fileExists(atPath: url.path) else { return ShotHistory() }
        return try RPJSON.decoder.decode(ShotHistory.self, from: try Data(contentsOf: url))
    }

    /// Writes the history atomically, deleting the file when it is empty.
    public func saveShotHistory(
        _ history: ShotHistory, for shotID: ShotID, fileManager: FileManager = .default
    ) throws {
        let url = historyURL(for: shotID)
        guard !history.isEmpty else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: historyURL, withIntermediateDirectories: true)
        try writer.write(try RPJSON.compactEncoder.encode(history), to: url)
    }

    /// Writes a **non-open** shot's document and records the change as one undo
    /// step in that shot's history — for batch writes (paste settings, a preset
    /// applied to every shot) that bypass the open shot's in-memory history.
    ///
    /// Without the step, a later undo on that shot would restore whatever came
    /// before the batch write and silently throw the batch away with it. An
    /// unreadable history is replaced rather than failing the write: the edit
    /// is what the user asked for.
    ///
    /// **History first, document second** (the rule `EditorModel`'s write
    /// queue follows too): if the process dies between the two writes, disk
    /// holds an undo step for an edit that never landed — undoing it restores
    /// the state that is already there — rather than an edit nothing can undo.
    public func saveEditStateRecordingHistory(
        _ state: EditState, replacing previous: EditState, for shotID: ShotID,
        fileManager: FileManager = .default
    ) throws {
        var history = (try? loadShotHistory(for: shotID, fileManager: fileManager)) ?? ShotHistory()
        history.record(.edit(previous))
        try saveShotHistory(history, for: shotID, fileManager: fileManager)
        try saveEditState(state, for: shotID, fileManager: fileManager)
    }

    // MARK: - Session position — session.json

    public var sessionPositionURL: URL {
        bundleURL.appendingPathComponent(ProjectBundle.sessionFileName)
    }

    /// Where the user left off, or `nil` when the project has never been left.
    public func loadSessionPosition(fileManager: FileManager = .default) throws -> SessionPosition? {
        guard fileManager.fileExists(atPath: sessionPositionURL.path) else { return nil }
        return try RPJSON.decoder.decode(
            SessionPosition.self, from: try Data(contentsOf: sessionPositionURL))
    }

    public func saveSessionPosition(_ position: SessionPosition) throws {
        try writer.writeJSON(position, to: sessionPositionURL)
    }

    // MARK: - Removal

    /// Drops a removed shot's strokes and history. `try?` inside because
    /// failing to delete a side file must not abort the removal the user asked
    /// for (the same rule ``removeShot(id:from:fileManager:)`` applies to masks).
    func deleteSessionFiles(for shotID: ShotID, fileManager: FileManager = .default) {
        for url in [manualMaskStrokesURL(for: shotID), historyURL(for: shotID)]
        where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
