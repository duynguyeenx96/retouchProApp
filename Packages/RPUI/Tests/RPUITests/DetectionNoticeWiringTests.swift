import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// "Detection failed, tell the user" — the UI half.
///
/// The engine half (`RPEngineTests/DetectionNoticeTests`) says a node can report
/// what its detection could not find. This says the sentence actually reaches the
/// panel, through `LivePreviewController.detectionNotices` and
/// `SliderSectionDescriptor.notifiesFromNodeNamed`, and lands in the *same* line
/// that already says "no face detected" rather than in a second, competing
/// mechanism.
///
/// The section descriptors here are built **by hand**, not read from
/// `SliderPanelLayout.sections`. No shipped group names a node yet — wiring the
/// "Sửa da" and "Đầu" panels is a separate task — so testing through the real
/// table would either test nothing or force this task to add panels it was not
/// asked for.
@Suite("Detection notice wiring")
@MainActor
struct DetectionNoticeWiringTests {

    /// A working (unlocked) group, optionally face-dependent, optionally naming a
    /// render node.
    static func section(
        needsFace: Bool = false, node: String? = nil, locked: Bool = false
    ) -> SliderSectionDescriptor {
        SliderSectionDescriptor(
            key: "demo", title: "Demo", panelTitle: "Demo", sectionCaption: "Demo",
            systemImage: "circle", phase: "Phase 6",
            parameters: locked
                ? []
                : [SliderParameter(key: "x", label: "X", direction: "tăng dần")],
            plannedParameters: ["X"],
            needsFace: needsFace,
            notifiesFromNodeNamed: node)
    }

    static let ready = GroupAvailability.PreviewState.ready(faceAnalysisRan: true)

    // MARK: - The new field

    @Test("A named node's notice becomes the group's blocked reason")
    func aNoticeBlocksTheGroup() {
        let section = Self.section(node: "skin")
        let reason = GroupAvailability.blockedReason(
            section: section, detectedFaceCount: 1, preview: Self.ready,
            notices: ["skin": "Không phát hiện được da."])
        #expect(reason == "Không phát hiện được da.")

        // No notice from that node: the group works, and the sliders are enabled
        // (`isEnabled: blockedReason == nil` in `GroupSliderList`).
        #expect(
            GroupAvailability.blockedReason(
                section: section, detectedFaceCount: 1, preview: Self.ready, notices: [:]) == nil)
        // A notice from a *different* node is not this group's business.
        #expect(
            GroupAvailability.blockedReason(
                section: section, detectedFaceCount: 1, preview: Self.ready,
                notices: ["warp": "Không phát hiện được viền tóc."]) == nil)
    }

    /// The other half of the same rule: "Cọ mask thủ công" (user input) and "Tạo
    /// khối" (pure landmark geometry) have nothing to detect, so they name no
    /// node and no notice can reach them — not even one their render node
    /// happened to emit.
    @Test("A group that names no node is never blocked by a notice")
    func aGroupWithNoNodeIgnoresNotices() {
        #expect(
            GroupAvailability.blockedReason(
                section: Self.section(), detectedFaceCount: 1, preview: Self.ready,
                notices: ["skin": "Không phát hiện được da.", "warp": "…"]) == nil)
    }

    /// Order matters: with no face at all, "there is no face in this photo" is
    /// both truer and more actionable than "no hairline found".
    @Test("The face check still comes first")
    func theFaceCheckWins() {
        let reason = GroupAvailability.blockedReason(
            section: Self.section(needsFace: true, node: "warp"), detectedFaceCount: 0,
            preview: Self.ready, notices: ["warp": "Không phát hiện được viền tóc."])
        #expect(reason == "Không nhận diện được khuôn mặt trong ảnh này.")

        // …and with a face, the node's notice comes through.
        #expect(
            GroupAvailability.blockedReason(
                section: Self.section(needsFace: true, node: "warp"), detectedFaceCount: 1,
                preview: Self.ready, notices: ["warp": "Không phát hiện được viền tóc."])
                == "Không phát hiện được viền tóc.")
    }

    @Test("A locked group still says it is locked, notice or not")
    func lockedWins() {
        #expect(
            GroupAvailability.blockedReason(
                section: Self.section(node: "skin", locked: true), detectedFaceCount: 1,
                preview: Self.ready, notices: ["skin": "Không phát hiện được da."])
                == "Phase 6 · chưa khả dụng")
    }

    // MARK: - The pre-existing behaviour, unchanged

    /// `blockedReason` moved out of the view body verbatim; these are the four
    /// answers it gave before, so the move cannot have changed what the Da / Mặt
    /// / Mắt & Răng groups say today.
    @Test("The no-face reasons are the same four sentences as before")
    func theFaceReasonsAreUnchanged() {
        let section = Self.section(needsFace: true)
        #expect(
            GroupAvailability.blockedReason(
                section: section, detectedFaceCount: 0, preview: .absent, notices: [:])
                == "Máy này không có preview GPU.")
        #expect(
            GroupAvailability.blockedReason(
                section: section, detectedFaceCount: 0, preview: .notReady, notices: [:])
                == "Preview GPU chưa sẵn sàng.")
        #expect(
            GroupAvailability.blockedReason(
                section: section, detectedFaceCount: 0,
                preview: .ready(faceAnalysisRan: false), notices: [:])
                == "Chưa chạy được phân tích khuôn mặt — nhóm này cần model Core ML.")
        #expect(
            GroupAvailability.blockedReason(
                section: section, detectedFaceCount: 0,
                preview: .ready(faceAnalysisRan: true), notices: [:])
                == "Không nhận diện được khuôn mặt trong ảnh này.")
        // With a face, nothing is said at all.
        #expect(
            GroupAvailability.blockedReason(
                section: section, detectedFaceCount: 2, preview: Self.ready, notices: [:]) == nil)
        // A group that needs no face says nothing even without one ("Màu").
        #expect(
            GroupAvailability.blockedReason(
                section: Self.section(), detectedFaceCount: 0, preview: .absent, notices: [:])
                == nil)
    }

    /// As of today no shipped group names a node: the six in the panel are Da,
    /// Mặt, Mắt & Răng, Màu, Trang điểm, Tóc, and the only detection any of them
    /// depends on is the face, which `needsFace` already covers.
    ///
    /// **When the "Sửa da" and "Đầu" panels are wired** (the next task), they set
    /// `notifiesFromNodeNamed: "skin"` / `"warp"` and this expectation changes to
    /// name them. That is the one-line hook-up this whole mechanism exists to
    /// make possible; a failure here means someone wired a panel, which is fine.
    @Test("No shipped section names a render node yet")
    func theShippedTableIsUnchanged() {
        #expect(SliderPanelLayout.sections.allSatisfy { $0.notifiesFromNodeNamed == nil })
    }

    // MARK: - LivePreviewController

    @Test("The last render's notices surface on the controller")
    func noticesSurfaceAfterARender() throws {
        guard let context = MetalContext.shared else { return }
        let controller = LivePreviewController(renderer: try LivePreviewRenderer(context: context))
        #expect(controller.detectionNotices.isEmpty)

        var report = RenderReport(nodes: ["skin"])
        report.notices = ["skin": "Không phát hiện được da."]
        controller.recordFrame(milliseconds: 1.5, report: report)
        #expect(controller.detectionNotices == ["skin": "Không phát hiện được da."])
        #expect(controller.lastNodes == ["skin"])

        // It is a live fact, not an event: the next healthy frame clears it.
        controller.recordFrame(milliseconds: 1.5, report: RenderReport(nodes: ["skin"]))
        #expect(controller.detectionNotices.isEmpty)
    }

    /// The previous shot's notices must not be shown against the next shot, and
    /// closing the editor forgets them.
    @Test("Opening or closing a shot drops the previous shot's notices")
    func noticesDoNotOutliveTheShot() async throws {
        guard let context = MetalContext.shared else { return }
        let controller = LivePreviewController(renderer: try LivePreviewRenderer(context: context))
        let url = try TempProject.writePNG(
            at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpui-notice-\(UUID().uuidString).png"),
            size: 128)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try ImageDecoder.decode(contentsOf: url, maxPixelSize: 2048)

        var report = RenderReport(nodes: [])
        report.notices = ["warp": "Không phát hiện được viền tóc."]
        controller.recordFrame(milliseconds: 1, report: report)
        #expect(!controller.detectionNotices.isEmpty)

        await controller.open(decoded, contentHash: "notice-shot", editState: EditState())
        #expect(controller.detectionNotices.isEmpty, "a notice outlived the shot it was about")

        controller.recordFrame(milliseconds: 1, report: report)
        controller.close()
        #expect(controller.detectionNotices.isEmpty)
    }
}
