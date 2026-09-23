import CoreGraphics
import Foundation
import RPCore

/// "A project is a session" (docs/ADR-0025): the open shot, the batch
/// selection, the canvas zoom/pan and the tab are kept in the project's
/// `session.json`, so reopening the project lands where the user left it.
///
/// ## When it is written
///
/// **Debounced**, ``sessionSaveDelay`` after the last change: a pinch or a
/// scroll-zoom mutates ``viewport`` every frame, and a file write (with its two
/// `fsync`s) per frame is exactly what must not happen. A burst of changes
/// produces one write, after it settles. ``saveSessionPositionNow()`` writes
/// synchronously for the moments there is no "later" — the app terminating or
/// going to the background.
///
/// ## What it is not
///
/// Not an undo point and not part of any shot's document: it says where the
/// user was looking, never what the photo looks like.
extension EditorModel {
    /// How long the position has to stay still before it is written.
    public static let sessionSaveDelay: Duration = .milliseconds(600)

    /// The view reports the tab it is showing; written with the rest.
    public func noteTab(_ tab: EditorChrome.Tab) {
        guard sessionTab != tab else { return }
        sessionTab = tab
        scheduleSessionPositionSave()
    }

    /// What `session.json` would say right now.
    public var currentSessionPosition: SessionPosition {
        SessionPosition(
            activeShotID: selection.activeShotID,
            selectedShotIDs: Array(selection.selectedShotIDs),
            tab: sessionTab?.rawValue,
            viewport: SessionPosition.Viewport(viewport))
    }

    /// Reads `session.json` and applies it: selection first (ids that are no
    /// longer in the project are dropped), then the viewport and the tab.
    ///
    /// A missing file is a project opened for the first time; an unreadable
    /// one is logged and ignored — the project opens where a fresh open would.
    func restoreSessionPosition() async {
        let store = self.store
        let loaded = await Task.detached { Result { try store.loadSessionPosition() } }.value
        let position: SessionPosition
        switch loaded {
        case .success(let value?): position = value
        case .success(nil): return
        case .failure(let error):
            Self.log.error(
                "session.json unreadable, opening fresh: \(String(describing: error), privacy: .public)")
            return
        }
        isRestoringSession = true
        defer { isRestoringSession = false }
        var restored = selection
        restored.restore(
            activeShotID: position.activeShotID,
            selectedShotIDs: Set(position.selectedShotIDs),
            in: project.shots)
        selection = restored
        if let stored = position.viewport, restored.activeShotID == position.activeShotID {
            viewport = CanvasViewport(stored)
        }
        if let raw = position.tab, let tab = EditorChrome.Tab(rawValue: raw) {
            restoredTab = tab
            sessionTab = tab
        }
    }

    /// Starts (or extends) the debounce. Cheap enough to call per frame: it
    /// stamps a time and, only if no write is pending, starts one task.
    func scheduleSessionPositionSave() {
        guard !isRestoringSession else { return }
        lastSessionChange = .now
        guard sessionSaveTask == nil else { return }
        sessionSaveTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.sessionSaveDelay)
                guard let self else { return }
                if Task.isCancelled { return }
                if let last = self.lastSessionChange, ContinuousClock.now - last < Self.sessionSaveDelay {
                    continue
                }
                self.sessionSaveTask = nil
                await self.writeSessionPosition()
                return
            }
        }
    }

    /// Writes now if a write is pending — for tests and for leaving the editor.
    public func flushSessionPosition() async {
        guard sessionSaveTask != nil else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        await writeSessionPosition()
    }

    /// Synchronous write, for app termination / backgrounding, where an async
    /// write might never run. Small file, one atomic write.
    public func saveSessionPositionNow() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        do {
            try store.saveSessionPosition(currentSessionPosition)
        } catch {
            Self.log.error(
                "session.json write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func writeSessionPosition() async {
        let store = self.store
        let position = currentSessionPosition
        let result = await Task.detached { Result { try store.saveSessionPosition(position) } }.value
        if case .failure(let error) = result {
            Self.log.error(
                "session.json write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension SessionPosition.Viewport {
    init(_ viewport: CanvasViewport) {
        self.init(
            zoom: Double(viewport.zoom), offsetX: Double(viewport.offset.width),
            offsetY: Double(viewport.offset.height), fitsWindow: viewport.isFittingToWindow)
    }
}

extension CanvasViewport {
    /// A stored viewport; the zoom is clamped to today's range.
    init(_ stored: SessionPosition.Viewport) {
        self.init(
            zoom: CGFloat(stored.zoom),
            offset: CGSize(width: stored.offsetX, height: stored.offsetY),
            isFittingToWindow: stored.fitsWindow)
    }
}
