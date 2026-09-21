import Foundation
import Testing

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

import RPCore
import RPEngine
@testable import RPUI

/// The Turn 3 tool rail (docs/design/SPEC.md §"Turn 3 — expanded toolset rail",
/// screens 3a-3f), **restructured into two levels on 2026-09-18**.
///
/// What is checkable without a window: the nine top-level entries in the
/// shipped order, each parent's children in theirs, and SPEC's wiring table —
/// which leaves open a real panel, which are locked, and that no item points at
/// a section key the panel cannot resolve. The pill/dimming is looked at on a
/// device.
///
/// The membership is **not** the canvas's nineteen: two members out, two in, one
/// renamed.
///
/// * out — "Xoá vật thể", cut from scope entirely on 2026-09-11
///   (`docs/design/SPEC.md` §Turn 3 "Cut from scope"), not locked, so
///   ``RailLayout`` never had a descriptor for it;
/// * out — "Bọng mắt", **deleted** on 2026-09-18: it was a second door into the
///   "Mắt" panel with the same `eye` glyph and nothing to tell the two apart,
///   which the user reported as wrong in itself;
/// * in — "Khoá nền" (docs/PLAN.md §6.1, docs/ADR-0018), shipping **locked**:
///   the engine behind it is finished but `RPEngineFeatureFlags.backgroundLock`
///   stays off until someone measures `VNGeneratePersonSegmentationRequest` on a
///   real iPhone;
/// * in — "Cọ mask" (docs/PLAN.md §6.1, docs/ADR-0019), last, whose lock follows
///   `RPEngineFeatureFlags.manualMask` rather than being fixed. Every assertion
///   below that depends on that bit sets it explicitly and holds
///   ``RPUIMaskFlagLock`` while it does — the flag store is process-global and
///   `ManualMaskBrushWiringTests` drives the same bit;
/// * renamed — the old top-level "Mặt" leaf is the child "Hình dáng mặt", so
///   that the parent and one of its children are not both called "Mặt". Its
///   panel and its fifteen sliders did not change.
@Suite("Tool rail structure")
struct RailLayoutTests {

    /// The nine scrolling top-level entries. Màu is not here — it is pinned
    /// outside the scroll view, at the trailing end (see
    /// ``colorItemIsPinnedAndSeparate``).
    private static let expectedTopLevel = [
        "Mặt", "Da", "Mẫu", "Tự động", "Trang điểm", "Cơ thể", "Tóc", "Khoá nền",
        "Cọ mask",
    ]

    /// The three parents and their children, in the shipped order.
    ///
    /// **"Da" is a parent of its own, not a child of "Mặt"** (user's correction,
    /// 2026-09-18): skin is a whole-body concept, and "Sửa da" — the switch that
    /// takes the two skin panels off the face-only mask — is its child rather
    /// than a top-level odd one out.
    private static let expectedChildren: [String: [String]] = [
        "Mặt": [
            "Hình dáng mặt", "Mắt", "Răng", "Đầu", "Tạo khối", "Căng mọng", "Mụn",
        ],
        "Da": ["Mịn da", "Kiềm dầu", "Sửa da"],
        "Cơ thể": ["Thu gọn", "Săn chắc"],
    ]

    /// The canvas's original nineteen, kept so the restructuring is checkably a
    /// *regrouping* of a known set rather than an invention: every label below
    /// is still somewhere in the tree except the two documented removals, plus
    /// the one rename and the one addition.
    private static let canvasLabels = [
        "Mẫu", "Răng", "Tự động", "Trang điểm", "Mặt", "Thu gọn", "Cơ thể",
        "Mịn da", "Sửa da", "Săn chắc", "Căng mọng", "Mụn", "Đầu", "Tạo khối",
        "Kiềm dầu", "Mắt", "Bọng mắt", "Tóc", "Xoá vật thể",
    ]

    /// The leaves with a working section behind them, per SPEC's wiring table.
    ///
    /// "Tạo khối" joined on 2026-09-21 (docs/ADR-0020). It is **active** even
    /// though `RPEngineFeatureFlags.contourSliders` is off: the flag disables the
    /// three rows inside the panel with a reason (`PanelFeatureGate`), it does
    /// not lock the rail item — see ``contourOpensAPanelThatSaysTheFlagIsOff``.
    /// "Sửa da" joined the same day (docs/ADR-0021 §UI) on the same terms:
    /// `RPEngineFeatureFlags.bodySkinSync` is off and disables the one switch
    /// inside the panel with a reason, rather than locking the item.
    private static let activeLabels: Set<String> = [
        "Hình dáng mặt", "Mịn da", "Kiềm dầu", "Mắt", "Răng", "Tạo khối", "Sửa da",
    ]

    /// The one item that opens a **screen** instead of a slider group: "Mẫu" was
    /// unlocked in Phase 3 as the preset library (docs/PLAN.md §Phase 3, *"dùng
    /// lại UI rail 'Mẫu' đã khoá … làm màn preset"*). It is unlocked but has no
    /// `sectionKey`, which is why the two rules below are stated separately.
    private static let screenLabels: Set<String> = ["Mẫu"]

    /// Every label in the tree, parents included.
    private static var everyLabel: [String] {
        RailLayout.items.flatMap { [$0.label] + ($0.children?.map(\.label) ?? []) }
    }

    /// Runs `body` with `RPEngineFeatureFlags.manualMask` pinned, holding the
    /// same gate `ManualMaskBrushWiringTests` holds.
    ///
    /// "Cọ mask" is the first rail item whose lock is **not** a constant: it
    /// follows a process-global bit the app sets at launch and another suite
    /// flips around its own cases. Asserting a locked-item list without pinning
    /// that bit is a test that passes or fails depending on which suite the
    /// runner happened to schedule first — which is exactly the failure
    /// `RPUIMaskFlagLock` was written for.
    @MainActor
    static func withManualMask(_ isOn: Bool, _ body: @escaping () -> Void) async throws {
        try await RPUIMaskFlagLock.exclusive {
            let previous = RPEngineFeatureFlags.manualMask
            RPEngineFeatureFlags.manualMask = isOn
            defer { RPEngineFeatureFlags.manualMask = previous }
            body()
        }
    }

    @Test("Nine top-level entries, Mặt first and Cọ mask last")
    func topLevelOrder() {
        #expect(RailLayout.items.count == 9)
        #expect(RailLayout.items.map(\.label) == Self.expectedTopLevel)
        #expect(RailLayout.items.first?.label == "Mặt")
        #expect(RailLayout.items.last?.label == "Cọ mask")
    }

    /// The hierarchy itself: exactly three parents, their children in order, and
    /// no third level (the canvas's per-tool grid is locked per SPEC — this is
    /// body part → sub-feature, and stops there). "Cọ mask" is not a body part's
    /// sub-feature — it stays one of the top-level leaves.
    @Test("Mặt, Da and Cơ thể are the only parents, with the children the decision names")
    func hierarchy() {
        let parents = RailLayout.items.filter(\.isParent)
        #expect(parents.map(\.label) == ["Mặt", "Da", "Cơ thể"])
        for parent in parents {
            #expect(parent.children?.map(\.label) == Self.expectedChildren[parent.label])
            // A parent is a grouping, not a destination: no panel and no screen
            // of its own.
            #expect(parent.sectionKey == nil)
            #expect(parent.presentation == nil)
            // …and exactly one level deep.
            #expect(parent.children?.allSatisfy { !$0.isParent } == true)
        }
        #expect(RailLayout.items.filter { !$0.isParent }.count == 6)
        #expect(!RailLayout.colorItem.isParent)

        // The correction itself, stated as a claim: the skin panels hang off
        // "Da", not off "Mặt", and "Sửa da" is inside that group rather than
        // floating at the top level.
        let face = RailLayout.items.first { $0.id == "faceGroup" }
        let skin = RailLayout.items.first { $0.id == "skinGroup" }
        #expect(face?.children?.contains { $0.id == "smooth" } == false)
        #expect(skin?.opensPanel(SliderPanelLayout.PanelKey.smooth) == true)
        #expect(skin?.opensPanel(SliderPanelLayout.PanelKey.shine) == true)
        #expect(skin?.children?.map(\.id) == ["smooth", "shine", "skinFix"])
        #expect(!RailLayout.items.contains { $0.id == "skinFix" })
    }

    /// "Bọng mắt" was deleted, not repointed: one door into the eye panel.
    @Test("No label appears twice, and Bọng mắt is gone entirely")
    func oneDoorPerThing() {
        #expect(!Self.everyLabel.contains("Bọng mắt"))
        #expect(Set(Self.everyLabel).count == Self.everyLabel.count)
        // …and no two *leaves* open the same panel, which is the general form of
        // the same rule and the thing three rounds of feedback were about.
        let panelKeys = RailLayout.leafItems.compactMap(\.sectionKey)
        #expect(Set(panelKeys).count == panelKeys.count)
        // …nor carry the same icon.
        let icons = RailLayout.leafItems.map(\.systemImage)
        #expect(Set(icons).count == icons.count)
    }

    /// The restructuring regrouped a known set: every canvas member is still
    /// somewhere in the tree except the two documented removals, with "Mặt"
    /// surviving as the parent label, its old panel now called "Hình dáng mặt",
    /// and labels the canvas never had — the "Da" group header, "Khoá nền" and
    /// "Cọ mask".
    @Test("The tree is the canvas's membership, minus two, plus three, with one renamed")
    func membershipAgainstTheCanvas() {
        #expect(
            Set(Self.everyLabel)
                == Set(Self.canvasLabels)
                .subtracting(["Xoá vật thể", "Bọng mắt"])
                .union(["Hình dáng mặt", "Da", "Khoá nền", "Cọ mask"]))
        #expect(
            Set(RailLayout.leafItems.map(\.id)) == [
                "face", "smooth", "shine", "eyes", "teeth", "head", "contour", "plump",
                "acne", "templates", "auto", "makeup", "slim", "firm", "skinFix", "hair",
                "backgroundLock", "manualMask", "color",
            ])
        #expect(
            Set(RailLayout.items.map(\.id)).isSuperset(of: ["faceGroup", "skinGroup", "body"]))
    }

    @Test("Every item has a stable unique id and an icon")
    func descriptorsAreComplete() {
        let everyItem = RailLayout.items.flatMap { [$0] + ($0.children ?? []) }
        #expect(Set(everyItem.map(\.id)).count == everyItem.count)
        for item in everyItem {
            #expect(!item.id.isEmpty)
            #expect(!item.label.isEmpty)
            #expect(!item.systemImage.isEmpty, "\(item.id)")
        }
        // 19 tappable leaves: 6 top-level ones, 7 under Mặt, 3 under Da, 2 under
        // Cơ thể, and the pinned Màu chip.
        #expect(RailLayout.leafItems.count == 19)
        #expect(RailLayout.leafItems.last?.id == "color")
    }

    /// A rail item may not invent a panel: every non-nil key has to be one the
    /// panel layout can resolve, or tapping it would silently do nothing — and
    /// whatever panel it lands on has to write a namespace RPCore declares.
    ///
    /// `SectionKey.all` is the slider namespaces; `mask` is declared beside them
    /// and deliberately kept out of that list (it holds switches, not sliders),
    /// so "Sửa da" is allowed to land there and nowhere else is.
    @Test("Every non-nil sectionKey resolves to a real slider panel")
    func sectionKeysResolve() {
        let namespaces = EditState.SectionKey.all + [EditState.SectionKey.mask]
        for item in RailLayout.leafItems {
            guard let key = item.sectionKey else { continue }
            let section = SliderPanelLayout.section(forKey: key)
            #expect(section?.key == key, "\(item.id)")
            #expect(section.map { namespaces.contains($0.storageKey) } == true, "\(item.id)")
        }
        #expect(
            SliderPanelLayout.sections.filter { $0.storageKey == EditState.SectionKey.mask }
                .map(\.key) == [SliderPanelLayout.PanelKey.skinFix])
    }

    /// SPEC's wiring table, restated for the hierarchy: six working leaves —
    /// four under "Mặt", two under "Da" — each opening its own panel and
    /// nothing else's.
    ///
    /// Pinned off, so "the active items" is the list this table describes
    /// rather than one that grows a nineteenth entry when another suite happens
    /// to have the brush switched on.
    @MainActor
    @Test("The six active leaves point at the panels the wiring table names")
    func wiringTable() async throws {
        try await Self.withManualMask(false) {
        let byLabel = Dictionary(
            uniqueKeysWithValues: RailLayout.leafItems.map { ($0.label, $0) })
        #expect(byLabel["Hình dáng mặt"]?.sectionKey == EditState.SectionKey.face)
        #expect(byLabel["Mịn da"]?.sectionKey == SliderPanelLayout.PanelKey.smooth)
        #expect(byLabel["Kiềm dầu"]?.sectionKey == SliderPanelLayout.PanelKey.shine)
        #expect(byLabel["Mắt"]?.sectionKey == SliderPanelLayout.PanelKey.eyes)
        #expect(byLabel["Răng"]?.sectionKey == SliderPanelLayout.PanelKey.teeth)
        #expect(byLabel["Tạo khối"]?.sectionKey == SliderPanelLayout.PanelKey.contour)
        #expect(byLabel["Sửa da"]?.sectionKey == SliderPanelLayout.PanelKey.skinFix)

        // The user-visible half of the same fact: one slider under "Răng" and
        // one under "Kiềm dầu", three under "Mắt", seven under "Mịn da" — and
        // none of the four pairs shares a glyph.
        func panel(_ label: String) -> SliderSectionDescriptor? {
            byLabel[label].flatMap { $0.sectionKey }.flatMap(SliderPanelLayout.section(forKey:))
        }
        #expect(panel("Răng")?.parameters.map(\.label) == ["Trắng răng"])
        #expect(panel("Kiềm dầu")?.parameters.map(\.label) == ["Khử bóng dầu"])
        #expect(panel("Mắt")?.parameters.count == 3)
        #expect(panel("Mịn da")?.parameters.count == 7)
        #expect(panel("Tạo khối")?.parameters.map(\.label) == ["Gò má", "Sống mũi", "Hàm"])
        // The one panel with no slider at all: "Sửa da" is a single switch
        // (docs/ADR-0021 §UI), which is why it is not locked despite having no
        // parameters.
        #expect(panel("Sửa da")?.parameters.isEmpty == true)
        #expect(panel("Sửa da")?.toggles.map(\.key) == [BodySkinSync.key])
        #expect(panel("Sửa da")?.isLocked == false)
        #expect(byLabel["Răng"]?.systemImage != byLabel["Mắt"]?.systemImage)
        #expect(byLabel["Kiềm dầu"]?.systemImage != byLabel["Mịn da"]?.systemImage)

        for item in RailLayout.leafItems where Self.activeLabels.contains(item.label) {
            #expect(!item.isLocked, "\(item.label) should open a working panel")
        }
        // The pinned Màu chip is an active item too, and comes last — it is
        // drawn after the scrolling nine in both shells, because colour is the
        // user's last step. "Mẫu" is active as well from Phase 3, but as a
        // screen rather than a section, so it carries no key.
        #expect(
            RailLayout.activeItems.map(\.label) == RailLayout.leafItems.map(\.label).filter {
                Self.activeLabels.contains($0) || Self.screenLabels.contains($0)
            } + ["Màu"])
        #expect(RailLayout.activeItems.filter { $0.sectionKey == nil }.map(\.label) == ["Mẫu"])
        }
    }

    /// Ten locked leaves with the brush switched off, for four different
    /// reasons: seven with no section at all, Trang điểm and Tóc whose sections
    /// exist but are themselves Phase 5, "Khoá nền", which has a finished
    /// engine and is held back on purpose, and "Cọ mask", which is locked only
    /// in a build that turned `manualMask` off. ("Xoá vật thể" is not among
    /// these — it was cut from scope entirely, not locked; "Mẫu" was unlocked
    /// in Phase 3; "Bọng mắt" was deleted; **"Tạo khối" and "Sửa da" left this
    /// list on 2026-09-21** when they got panels — their own flags being off
    /// disables the controls inside those panels instead of locking the items.)
    @MainActor
    @Test("The other ten leaves are locked, for the four different reasons")
    func lockedItems() async throws {
        try await Self.withManualMask(false) {
        let locked = RailLayout.leafItems.filter(\.isLocked)
        #expect(locked.count == 10)
        #expect(
            locked.map(\.label) == [
                "Đầu", "Căng mọng", "Mụn", "Tự động",
                "Trang điểm", "Thu gọn", "Săn chắc", "Tóc", "Khoá nền", "Cọ mask",
            ])

        // No section behind it at all and no specific reason: six of the ten.
        let unbacked = locked.filter { $0.sectionKey == nil && $0.lockedReason == nil }
        #expect(unbacked.count == 6)
        for item in unbacked { #expect(item.lockedHint == "chưa khả dụng", "\(item.id)") }

        // The two Phase 5 groups keep the panel's own wording.
        let phaseFive = locked.filter { $0.sectionKey != nil && $0.lockedReason == nil }
        #expect(phaseFive.map(\.sectionKey) == [
            EditState.SectionKey.makeup, EditState.SectionKey.hair,
        ])
        for item in phaseFive { #expect(item.lockedHint == "Phase 5 · chưa khả dụng") }
        }
    }

    /// A parent is locked only when every child is — one boolean derived from
    /// the children, not a second concept. "Mặt" has three working children and
    /// "Da" two; "Cơ thể" has none.
    @Test("A parent is locked exactly when all of its children are")
    func parentLocking() throws {
        let face = try #require(RailLayout.items.first { $0.id == "faceGroup" })
        let skin = try #require(RailLayout.items.first { $0.id == "skinGroup" })
        let body = try #require(RailLayout.items.first { $0.id == "body" })

        #expect(!face.isLocked)
        #expect(face.children?.contains { !$0.isLocked } == true)
        #expect(face.lockedHint == "")

        // "Da" and all three of its children are unlocked since "Sửa da" got its
        // one-switch panel (docs/ADR-0021 §UI).
        #expect(!skin.isLocked)
        #expect(skin.children?.filter { $0.isLocked }.map(\.label) == [])
        #expect(skin.lockedHint == "")

        #expect(body.isLocked)
        #expect(body.children?.allSatisfy(\.isLocked) == true)
        #expect(body.lockedHint == "chưa khả dụng")
    }

    /// An item's icon must be the icon of the panel it opens, so the rail and
    /// the panel header do not disagree about what the tool is.
    @Test("An item that opens a section borrows that section's SF Symbol")
    func iconsMatchTheirSection() {
        for item in RailLayout.leafItems {
            guard let key = item.sectionKey,
                let section = SliderPanelLayout.section(forKey: key)
            else { continue }
            #expect(item.systemImage == section.systemImage, "\(item.id)")
        }
    }

    /// SPEC: *"tap does nothing … must not crash/switch"*. A locked item leaves
    /// the panel where it was; an active one moves it.
    @MainActor
    @Test("Tapping a rail item moves the panel only when something is behind it")
    func selectingFromTheRail() throws {
        let chrome = EditorChrome()
        let byLabel = Dictionary(
            uniqueKeysWithValues: RailLayout.leafItems.map { ($0.label, $0) })
        chrome.activeGroupKey = SliderPanelLayout.PanelKey.smooth

        for label in ["Tự động", "Thu gọn", "Trang điểm", "Tóc", "Khoá nền", "Mụn"] {
            chrome.selectRailItem(try #require(byLabel[label]))
            #expect(
                chrome.activeGroupKey == SliderPanelLayout.PanelKey.smooth,
                "\(label) switched the panel")
            #expect(chrome.presetLibrary == nil, "\(label) opened a screen")
        }

        // Each working leaf opens its own panel, and no other leaf lights up
        // with it — the point of the whole restructuring.
        chrome.selectRailItem(try #require(byLabel["Mắt"]))
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.eyes)
        #expect(chrome.activeSection.parameters.count == 3)
        #expect(
            RailLayout.leafItems.filter { $0.opensPanel(chrome.activeGroupKey) }.map(\.label)
                == ["Mắt"])

        chrome.selectRailItem(try #require(byLabel["Răng"]))
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.teeth)
        #expect(chrome.activeSection.parameters.map(\.label) == ["Trắng răng"])

        chrome.selectRailItem(try #require(byLabel["Kiềm dầu"]))
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.shine)
        #expect(chrome.activeSection.parameters.map(\.label) == ["Khử bóng dầu"])
        #expect(
            RailLayout.leafItems.filter { $0.opensPanel(chrome.activeGroupKey) }.map(\.label)
                == ["Kiềm dầu"])

        chrome.selectRailItem(try #require(byLabel["Hình dáng mặt"]))
        #expect(chrome.activeGroupKey == EditState.SectionKey.face)
    }

    /// Tapping a **parent** opens its first working child and puts that group's
    /// strip on screen; the parent itself highlights the whole time. A fully
    /// locked parent does nothing at all.
    @MainActor
    @Test("Tapping a parent opens its first working child")
    func selectingAParent() throws {
        let chrome = EditorChrome()
        let face = try #require(RailLayout.items.first { $0.id == "faceGroup" })
        let skin = try #require(RailLayout.items.first { $0.id == "skinGroup" })
        let body = try #require(RailLayout.items.first { $0.id == "body" })
        chrome.activeGroupKey = EditState.SectionKey.color

        chrome.selectRailItem(face)
        #expect(chrome.activeGroupKey == EditState.SectionKey.face)
        #expect(face.defaultChild?.label == "Hình dáng mặt")
        // The rail's highlight rule, one level deeper: the parent is active for
        // any of its children's panels — and only its own.
        #expect(face.opensPanel(chrome.activeGroupKey))
        #expect(!skin.opensPanel(chrome.activeGroupKey))
        #expect(!body.opensPanel(chrome.activeGroupKey))
        // …and the panel now knows which strip to draw.
        #expect(chrome.activeRailParent?.id == "faceGroup")

        // Still the parent's strip after moving to a sibling.
        chrome.selectGroup(SliderPanelLayout.PanelKey.teeth)
        #expect(chrome.activeRailParent?.id == "faceGroup")
        #expect(face.opensPanel(chrome.activeGroupKey))

        // The second parent opens "Mịn da" and hands the strip over.
        chrome.selectRailItem(skin)
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.smooth)
        #expect(skin.defaultChild?.label == "Mịn da")
        #expect(chrome.activeRailParent?.id == "skinGroup")
        #expect(!face.opensPanel(chrome.activeGroupKey))

        // A fully locked parent is inert, and a top-level leaf's panel has no
        // strip at all.
        chrome.selectRailItem(body)
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.smooth)
        chrome.selectRailItem(RailLayout.colorItem)
        #expect(chrome.activeRailParent == nil)
    }

    // MARK: - "Khoá nền" — structurally ready, deliberately locked

    /// docs/PLAN.md §6.1 / docs/ADR-0018. The rail entry exists so that turning
    /// the feature on later is a flag flip plus a control rather than a UI
    /// project — but it must **not** be usable today, because
    /// `RPEngineFeatureFlags.backgroundLock` is off and the ADR's blocker (no
    /// `VNGeneratePersonSegmentationRequest` measurement on an A-series chip, and
    /// therefore no defensible `qualityLevel`) is still open.
    ///
    /// The three claims that matter, in the order they would break: it is there,
    /// it is locked, and it says why it is locked in words a user can act on.
    @MainActor
    @Test("Khoá nền ships as a locked rail item with an honest reason")
    func backgroundLockShipsLocked() throws {
        let item = try #require(RailLayout.items.first { $0.id == "backgroundLock" })
        #expect(item.label == "Khoá nền")
        #expect(!item.systemImage.isEmpty)

        // Locked, and locked the way the rail already expresses "locked": no
        // section, no screen, no children. Not a working toggle behind a
        // disabled style.
        #expect(item.sectionKey == nil)
        #expect(item.presentation == nil)
        #expect(item.children == nil)
        #expect(item.isLocked)
        #expect(!RailLayout.activeItems.contains { $0.id == item.id })

        // …and the hint is the specific reason, not the generic placeholder the
        // not-started tools get.
        #expect(item.lockedHint == "Phase 6.1 · cần đo trên iPhone thật trước")
        #expect(item.lockedHint != "chưa khả dụng")
        #expect(item.lockedReason == item.lockedHint)

        // Tapping it is inert: the panel does not move and no screen opens.
        let chrome = EditorChrome()
        chrome.activeGroupKey = SliderPanelLayout.PanelKey.smooth
        chrome.selectRailItem(item)
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.smooth)
        #expect(chrome.presetLibrary == nil)
    }

    // MARK: - "Tạo khối" — a wired panel behind a flag that is still off

    /// docs/ADR-0020 / docs/PLAN.md §6.2, wired 2026-09-21. The engine shipped
    /// with "no UI — nothing in RPUI exposes the three keys"; this is that UI,
    /// and the question it has to answer is what a rail item does when the
    /// panel behind it is real but `RPEngineFeatureFlags.contourSliders` is off.
    ///
    /// The answer, and the three claims in the order they would break: the item
    /// opens the panel (it is **not** locked — a locked item with a three-slider
    /// panel behind it is the orphan `noWorkingSectionIsOrphaned` forbids), the
    /// panel carries the ADR's three keys under the plan's Vietnamese labels,
    /// and while the flag is off the group is disabled with a sentence that says
    /// so rather than three controls that write JSON no kernel reads.
    @MainActor
    @Test("Tạo khối opens a real panel that says the flag is off")
    func contourOpensAPanelThatSaysTheFlagIsOff() throws {
        let item = try #require(RailLayout.leafItems.first { $0.id == "contour" })
        #expect(item.label == "Tạo khối")
        #expect(item.sectionKey == SliderPanelLayout.PanelKey.contour)
        #expect(!item.isLocked)
        #expect(item.lockedReason == nil)
        #expect(RailLayout.activeItems.contains { $0.id == item.id })

        let panel = try #require(SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.contour))
        #expect(item.systemImage == panel.systemImage)
        #expect(panel.parameters.map(\.key) == ContourSliders.Key.all)
        #expect(panel.parameters.map(\.label) == ["Gò má", "Sống mũi", "Hàm"])
        #expect(panel.storageKey == EditState.SectionKey.face)
        #expect(panel.gatedBy == .contourSliders)
        // No notice node: contour is pure landmark geometry, so there is nothing
        // it can fail to *detect* (docs/PLAN.md §6.2 / the Phase 6 plan's item 2).
        #expect(panel.notifiesFromNodeNamed == nil)

        // Tapping it really moves the panel, with the child strip of "Mặt".
        let chrome = EditorChrome()
        chrome.activeGroupKey = SliderPanelLayout.PanelKey.smooth
        chrome.selectRailItem(item)
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.contour)
        #expect(chrome.activeSection.parameters.count == 3)
        #expect(chrome.activeRailParent?.id == "faceGroup")

        // The flag, both ways. With it off the group is blocked by the build —
        // ahead of the "no face" answer, because no photo would help; with it on
        // the only thing left in the way is the ordinary face check.
        let previous = RPEngineFeatureFlags.contourSliders
        defer { RPEngineFeatureFlags.contourSliders = previous }

        RPEngineFeatureFlags.contourSliders = false
        let blocked = GroupAvailability.blockedReason(
            section: panel, detectedFaceCount: 1, preview: .ready(faceAnalysisRan: true),
            notices: [:])
        #expect(blocked == PanelFeatureGate.contourSliders.offReason)
        #expect(blocked?.contains("Tạo khối") == true)
        #expect(blocked != "chưa khả dụng")

        RPEngineFeatureFlags.contourSliders = true
        #expect(
            GroupAvailability.blockedReason(
                section: panel, detectedFaceCount: 1, preview: .ready(faceAnalysisRan: true),
                notices: [:]) == nil)
        #expect(
            GroupAvailability.blockedReason(
                section: panel, detectedFaceCount: 0, preview: .ready(faceAnalysisRan: true),
                notices: [:]) == "Không nhận diện được khuôn mặt trong ảnh này.")
    }

    /// "Sửa da" (docs/ADR-0021 §UI) — the same shape as "Tạo khối" above, with
    /// the two things that are different about it:
    ///
    /// * its control is a **switch**, so the panel has no parameters at all and
    ///   is still not locked;
    /// * it **does** name a node, because unlike contour it depends on a
    ///   detection that really fails: the whole-body skin classifier returns
    ///   nothing for the deepest skin tone (ADR-0021 §5, unfixed). The whole
    ///   reason the toggle may ship is that this failure is spoken aloud, so the
    ///   order of the three answers — build, face, node — is pinned here.
    @MainActor
    @Test("Sửa da opens a one-switch panel that says the flag is off, then says what is missing")
    func skinFixOpensAPanelThatNamesItsDetection() throws {
        let item = try #require(RailLayout.leafItems.first { $0.id == "skinFix" })
        #expect(item.label == "Sửa da")
        #expect(item.sectionKey == SliderPanelLayout.PanelKey.skinFix)
        #expect(!item.isLocked)
        #expect(item.lockedReason == nil)
        #expect(RailLayout.activeItems.contains { $0.id == item.id })

        let panel = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.skinFix))
        #expect(item.systemImage == panel.systemImage)
        #expect(panel.parameters.isEmpty)
        #expect(panel.toggles.map(\.key) == [BodySkinSync.key])
        #expect(panel.toggles.first?.label == "Đồng bộ da toàn thân")
        // The copy does not promise it always works — ADR-0021's gap, in the
        // control's own words.
        #expect(panel.toggles.first?.detail.contains("tông da rất đậm") == true)
        #expect(panel.storageKey == EditState.SectionKey.mask)
        #expect(panel.gatedBy == .bodySkinSync)
        #expect(panel.notifiesFromNodeNamed == "skin")
        #expect(!panel.isLocked)

        // Tapping it moves the panel, with the child strip of "Da".
        let chrome = EditorChrome()
        chrome.activeGroupKey = SliderPanelLayout.PanelKey.smooth
        chrome.selectRailItem(item)
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.skinFix)
        #expect(chrome.activeSection.toggles.count == 1)
        #expect(chrome.activeRailParent?.id == "skinGroup")

        let previous = RPEngineFeatureFlags.bodySkinSync
        defer { RPEngineFeatureFlags.bodySkinSync = previous }
        let notice = ["skin": "Không phát hiện được da."]

        // 1. The build first: with the flag off, a "no skin" notice from a stale
        //    render must not be what the user reads, because the honest answer
        //    is that this build does not run the classifier at all.
        RPEngineFeatureFlags.bodySkinSync = false
        let gated = GroupAvailability.blockedReason(
            section: panel, detectedFaceCount: 1, preview: .ready(faceAnalysisRan: true),
            notices: notice)
        #expect(gated == PanelFeatureGate.bodySkinSync.offReason)
        #expect(gated?.contains("Sửa da") == true)
        #expect(gated != "chưa khả dụng")

        RPEngineFeatureFlags.bodySkinSync = true
        // 2. Then the face — with none, there is no skin group to widen.
        #expect(
            GroupAvailability.blockedReason(
                section: panel, detectedFaceCount: 0, preview: .ready(faceAnalysisRan: true),
                notices: notice) == "Không nhận diện được khuôn mặt trong ảnh này.")
        // 3. Then the node: this is the sentence that makes the deep-tone
        //    failure visible instead of silent.
        #expect(
            GroupAvailability.blockedReason(
                section: panel, detectedFaceCount: 1, preview: .ready(faceAnalysisRan: true),
                notices: notice) == "Không phát hiện được da.")
        // …and a healthy render says nothing at all.
        #expect(
            GroupAvailability.blockedReason(
                section: panel, detectedFaceCount: 1, preview: .ready(faceAnalysisRan: true),
                notices: [:]) == nil)
        // The notice is scoped to this panel: the seven face-smoothing sliders
        // keep working when only the *body* classifier came back empty.
        let smooth = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.smooth))
        #expect(smooth.notifiesFromNodeNamed == nil)
        #expect(
            GroupAvailability.blockedReason(
                section: smooth, detectedFaceCount: 1, preview: .ready(faceAnalysisRan: true),
                notices: notice) == nil)
    }

    /// The gate is scoped to the panels that need it, so it did not become a
    /// second, quieter way of marking a group unavailable.
    @Test("gatedBy is set on exactly the two panels whose engine flag is off")
    func panelGateIsScoped() {
        #expect(
            SliderPanelLayout.sections.filter { $0.gatedBy != nil }.map(\.key)
                == [SliderPanelLayout.PanelKey.skinFix, SliderPanelLayout.PanelKey.contour])
    }

    /// The override is scoped to the two items that need it — a built feature
    /// held back for a measurement, and a built feature a build can switch off —
    /// so this did not quietly become a second place where lock hints are
    /// written for everything else.
    @Test("lockedReason is set on exactly the two items that have a specific reason")
    func lockedReasonIsScoped() {
        #expect(
            RailLayout.leafItems.filter { $0.lockedReason != nil }.map(\.id)
                == ["backgroundLock", "manualMask"])
    }

    // MARK: - "Mẫu" — the one item that opens a screen

    /// Phase 3 unlocked "Mẫu" as the preset library. Tapping it must open the
    /// library **without**
    /// moving the slider panel: closing the library has to put the user back on
    /// the group they were editing.
    @MainActor
    @Test("Tapping Mẫu opens the preset library and leaves the slider panel alone")
    func tappingTemplatesOpensThePresetLibrary() throws {
        let byLabel = Dictionary(
            uniqueKeysWithValues: RailLayout.leafItems.map { ($0.label, $0) })
        let templates = try #require(byLabel["Mẫu"])

        #expect(templates.presentation == .presetLibrary(.templates))
        #expect(templates.sectionKey == nil)
        #expect(!templates.isLocked)
        // Two presentations now: the library, and the brush mode (§6.1). They
        // are the two rail entries that are not a slider group.
        #expect(
            RailLayout.leafItems.filter { $0.presentation != nil }.map(\.id)
                == ["templates", "manualMask"])

        let chrome = EditorChrome()
        chrome.activeGroupKey = EditState.SectionKey.face
        chrome.selectRailItem(templates)

        #expect(chrome.presetLibrary == .templates)
        #expect(chrome.activeGroupKey == EditState.SectionKey.face)
    }

    /// The Looks picker is the same screen with a different kind, and it is only
    /// reachable from inside the library — the canvas's rail has no Looks entry.
    @Test("The two picker kinds differ only in which sections they carry")
    func libraryKinds() {
        #expect(PresetLibraryKind.templates.sectionNames == Set(EditState.SectionKey.all))
        #expect(PresetLibraryKind.looks.sectionNames == [EditState.SectionKey.color])
        #expect(PresetLibraryKind.allCases.map(\.title) == ["Mẫu", "Looks"])
    }

    /// The 2026-09-11 decision: the mockup's "Cho bạn" ships as "Nổi bật".
    @Test("The featured tab is not labelled 'Cho bạn'")
    func tabsAreRenamed() {
        #expect(PresetLibraryTab.allCases.map(\.title) == ["Nổi bật", "Của tôi", "Yêu thích"])
        #expect(!PresetLibraryTab.allCases.map(\.title).contains("Cho bạn"))
    }

    // MARK: - The pinned "Màu" affordance

    /// The regression this exists for: the long tool rail replaced a six-group
    /// tab row, and the canvas's `RAIL` const has no colour entry — so for one
    /// commit the eighteen working Color sliders had **no** way in.
    /// `docs/design/SPEC.md` §"macOS panel (3f) structural note" asks for it as
    /// an always-visible top-level tab alongside the rail.
    @Test("Màu is a pinned rail item, last, not one of the scrolling nine")
    func colorItemIsPinnedAndSeparate() throws {
        #expect(!RailLayout.items.contains { $0.opensPanel(EditState.SectionKey.color) })
        #expect(RailLayout.colorItem.sectionKey == EditState.SectionKey.color)
        #expect(!RailLayout.colorItem.isLocked)
        #expect(RailLayout.allItems.count == RailLayout.items.count + 1)
        // Last, not first: colour is the final step of the user's workflow. It
        // is still *pinned* (outside the scroll view in both shells), which is
        // what keeps the Color panel from being scrollable out of reach.
        #expect(RailLayout.allItems.last?.id == RailLayout.colorItem.id)
        #expect(Set(RailLayout.leafItems.map(\.id)).count == RailLayout.leafItems.count)

        // Label and icon are the section's own, not a second copy that can drift
        // from the panel the chip opens.
        let section = try #require(
            SliderPanelLayout.section(forKey: EditState.SectionKey.color))
        #expect(RailLayout.colorItem.label == section.title)
        #expect(RailLayout.colorItem.systemImage == section.systemImage)
        #expect(section.parameters.count == 18)
    }

    /// The actual reachability claim, through the same call the two views make.
    @MainActor
    @Test("Tapping the pinned Màu item lands on the Color panel")
    func tappingColorOpensTheColorPanel() {
        let chrome = EditorChrome()
        chrome.activeGroupKey = SliderPanelLayout.PanelKey.smooth

        chrome.selectRailItem(RailLayout.colorItem)
        #expect(chrome.activeGroupKey == EditState.SectionKey.color)
        #expect(chrome.activeSection.key == EditState.SectionKey.color)
        #expect(chrome.activeSection.parameters.count == 18)

        // …and it survives a trip through another rail item and back, i.e. it is
        // not a one-way door.
        chrome.selectGroup(EditState.SectionKey.face)
        #expect(chrome.activeGroupKey == EditState.SectionKey.face)
        chrome.selectRailItem(RailLayout.colorItem)
        #expect(chrome.activeGroupKey == EditState.SectionKey.color)
    }

    /// The general form of the same rule: no working slider panel may be
    /// orphaned by the rail. Today that is Mịn da / Kiềm dầu / Sửa da /
    /// Hình dáng mặt / Tạo khối / Mắt / Răng from the tree and Màu from the
    /// pinned chip; a ninth working panel added in a later phase fails here
    /// until it gets an affordance.
    ///
    /// This is the rule that decides how a flag-gated panel ships: locking the
    /// "Tạo khối" rail item while its panel carries three real sliders would
    /// leave exactly the orphan this test exists to catch.
    @Test("Every unlocked slider panel is reachable from the rail")
    func noWorkingSectionIsOrphaned() {
        let working = Set(SliderPanelLayout.sections.filter { !$0.isLocked }.map(\.key))
        #expect(working.count == 8)
        #expect(RailLayout.reachableSectionKeys == working)
    }

    /// Every icon the rail and the panel headers name has to exist in the OS's
    /// SF Symbols catalogue — an unknown name draws nothing at all, and the two
    /// splits introduced new ones (`mouth` for Răng, `humidity` for Kiềm dầu,
    /// `face.dashed` for the "Mặt" parent). This runs on both the macOS and the
    /// iOS Simulator destinations, so it checks the iOS 18 catalogue too.
    @Test("Every rail and panel SF Symbol resolves on this platform")
    func everySymbolExists() {
        var names = Set(RailLayout.leafItems.map(\.systemImage))
        names.formUnion(RailLayout.items.map(\.systemImage))
        names.formUnion(SliderPanelLayout.sections.map(\.systemImage))
        for name in names.sorted() {
            #if canImport(UIKit)
                #expect(UIImage(systemName: name) != nil, "\(name)")
            #elseif canImport(AppKit)
                #expect(
                    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(name)")
            #endif
        }
    }
}
