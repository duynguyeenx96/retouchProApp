import Foundation

/// Why a slider group cannot do anything right now — the whole of it, as a pure
/// function.
///
/// ## What this is
/// It used to live inside `GroupSliderList.blockedReason`, a computed property in
/// a SwiftUI view body, where the only way to test it was to build a view. It is
/// lifted out unchanged in behaviour and extended by one case (see
/// ``SliderSectionDescriptor/notifiesFromNodeNamed``), because the rule it
/// encodes is now cross-cutting rather than one group's detail:
///
/// > **A detection-dependent feature that cannot detect what it needs says so.**
/// > It never silently does nothing.
///
/// Since 2026-09-21 it carries one more case of the same rule, where the thing
/// missing is not a detection but a switch: a group whose engine flag is off in
/// this build (``SliderSectionDescriptor/gatedBy``, "Tạo khối" today) says that,
/// instead of offering three live-looking sliders whose values no kernel reads.
///
/// ## The shape of the message, which is not negotiable per group
/// One sentence, Vietnamese, **live-computed on every render** — not one-shot,
/// not dismissible, not a toast. It is a standing fact about the group ("this
/// cannot work on this photo right now"), so it must disappear on its own the
/// moment it stops being true (a face is found, a slider goes back to 0, the
/// user opens another shot). The one-shot `errorBanner` in `EditorView` is for
/// the opposite kind of thing — an import that failed once — and reusing it here
/// would leave a stale sentence on screen.
///
/// The caller renders the returned string as
/// `Label(reason, systemImage: "info.circle")` in `RPTheme.textTertiary` and
/// passes `isEnabled: reason == nil` to every slider row in the group.
enum GroupAvailability {

    /// The live GPU preview, as much of it as this decision needs. A separate
    /// type so the rule can be tested without a Metal device — `LivePreviewController`
    /// cannot be constructed on a machine without one.
    enum PreviewState: Equatable, Sendable {
        /// No `LivePreviewController` at all: no Metal device, or the graph
        /// refused to build.
        case absent
        /// There is one, but it has no picture on the GPU yet.
        case notReady
        /// Rendering. `faceAnalysisRan` distinguishes "we looked and there is no
        /// face in this photo" from "we never got to look" (the Core ML models
        /// are missing), which are different problems with different fixes.
        case ready(faceAnalysisRan: Bool)
    }

    /// - Parameters:
    ///   - detectedFaceCount: faces found in the open shot.
    ///   - notices: `RenderReport.notices` from the most recent render, i.e.
    ///     `LivePreviewController.detectionNotices`.
    /// - Returns: the sentence to show, or `nil` when the group is fine.
    static func blockedReason(
        section: SliderSectionDescriptor,
        detectedFaceCount: Int,
        preview: PreviewState,
        notices: [String: String]
    ) -> String? {
        if section.isLocked { return "\(section.phase) · chưa khả dụng" }

        // 0. The build, before anything about *this photo*. A group whose engine
        //    flag is off cannot work on any picture, so asking about the face
        //    first would answer a question the user cannot act on ("import
        //    another photo") for a problem that is not about the photo.
        //    `RPEngineFeatureFlags` is read here, at render time, for the reason
        //    `PanelFeatureGate` gives: the flags are a process global the app
        //    sets at launch.
        if let gate = section.gatedBy, !gate.isOn { return gate.offReason }

        // 1. The face, first and unchanged. It stays ahead of the node notices
        //    because it is the more fundamental answer: with no face there is
        //    nothing for a hair trace or a per-face skin mask to have failed *at*,
        //    and "Không nhận diện được khuôn mặt trong ảnh này" tells the user
        //    more than "Không phát hiện được viền tóc" would.
        if section.needsFace, detectedFaceCount == 0 {
            switch preview {
            case .absent:
                return "Máy này không có preview GPU."
            case .notReady:
                return "Preview GPU chưa sẵn sàng."
            case .ready(let faceAnalysisRan):
                return faceAnalysisRan
                    ? "Không nhận diện được khuôn mặt trong ảnh này."
                    : "Chưa chạy được phân tích khuôn mặt — nhóm này cần model Core ML."
            }
        }

        // 2. Then whatever this group's render node could not find. A group that
        //    names no node — every group that shipped before Phase 6 — reaches
        //    `nil` here exactly as it did before this method existed.
        if let node = section.notifiesFromNodeNamed, let notice = notices[node] {
            return notice
        }
        return nil
    }

    /// Reads the controller's state into ``PreviewState``. The mapping the view
    /// would otherwise do inline, kept here so both halves of the rule live in
    /// one file.
    @MainActor
    static func previewState(of live: LivePreviewController?) -> PreviewState {
        guard let live else { return .absent }
        guard live.isReady else { return .notReady }
        return .ready(faceAnalysisRan: live.faceAnalysisRan)
    }
}
