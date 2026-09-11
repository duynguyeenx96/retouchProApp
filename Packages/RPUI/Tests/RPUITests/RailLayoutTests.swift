import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// The Turn 3 tool rail (docs/design/SPEC.md §"Turn 3 — expanded toolset rail",
/// screens 3a-3f).
///
/// What is checkable without a window: the eighteen labels in the shipped
/// order, and SPEC's wiring table — which six items open a real panel, which
/// twelve are locked, and that no item points at a section key the panel
/// cannot resolve. The pill/dimming is looked at on a device.
///
/// Eighteen, not the canvas's nineteen: "Xoá vật thể" was cut from scope
/// entirely on 2026-09-11 (`docs/design/SPEC.md` §Turn 3 "Cut from scope"),
/// not locked — so ``RailLayout/items`` never had a descriptor for it to begin
/// with, and the "pure permutation of the canvas" test below accounts for the
/// one dropped member instead of asserting a 1:1 set match.
@Suite("Tool rail structure")
struct RailLayoutTests {

    /// The shipped order: the user's first three steps (Mặt → Mắt → Mịn da),
    /// then the design canvas's `RAIL` const with those three removed and
    /// "Xoá vật thể" cut, in its own relative order. Màu is not here — it is
    /// pinned outside the scrolling eighteen, at the trailing end (see
    /// ``colorItemIsPinnedAndSeparate``).
    private static let expectedLabels = [
        "Mặt", "Mắt", "Mịn da",
        "Mẫu", "Răng", "Tự động", "Trang điểm", "Thu gọn", "Cơ thể",
        "Sửa da", "Săn chắc", "Căng mọng", "Mụn", "Đầu", "Tạo khối",
        "Kiềm dầu", "Bọng mắt", "Tóc",
    ]

    /// The canvas's original nineteen, kept so the reorder is checkably a
    /// *pure permutation minus the one cut member* — not one silently added or
    /// dropped beyond the documented "Xoá vật thể" removal.
    private static let canvasLabels = [
        "Mẫu", "Răng", "Tự động", "Trang điểm", "Mặt", "Thu gọn", "Cơ thể",
        "Mịn da", "Sửa da", "Săn chắc", "Căng mọng", "Mụn", "Đầu", "Tạo khối",
        "Kiềm dầu", "Mắt", "Bọng mắt", "Tóc", "Xoá vật thể",
    ]

    /// The six with a working section behind them, per SPEC's wiring table.
    private static let activeLabels: Set<String> = [
        "Mặt", "Mắt", "Bọng mắt", "Răng", "Mịn da", "Kiềm dầu",
    ]

    @Test("Eighteen items, workflow order: Mặt → Mắt → Mịn da lead")
    func labelsAndOrder() {
        #expect(RailLayout.items.count == 18)
        #expect(RailLayout.items.map(\.label) == Self.expectedLabels)
        #expect(RailLayout.items.prefix(3).map(\.label) == ["Mặt", "Mắt", "Mịn da"])
    }

    /// The reorder moved rows and dropped exactly one documented member
    /// ("Xoá vật thể", cut from scope 2026-09-11); nothing else was added,
    /// dropped, or re-keyed. Ids are what the views use for identity, so they
    /// are checked too.
    @Test("The order is a pure permutation of the canvas's nineteen, minus the one cut item")
    func orderIsAPermutationOfTheCanvas() {
        #expect(Set(RailLayout.items.map(\.label)) == Set(Self.canvasLabels).subtracting(["Xoá vật thể"]))
        #expect(
            Set(RailLayout.items.map(\.id)) == [
                "templates", "teeth", "auto", "makeup", "face", "slim", "body", "smooth",
                "skinFix", "firm", "plump", "acne", "head", "contour", "shine", "eyes",
                "eyeBags", "hair",
            ])

        // The fifteen that did not lead and were not cut keep the canvas's
        // relative order.
        let moved: Set<String> = ["Mặt", "Mắt", "Mịn da"]
        let dropped: Set<String> = ["Xoá vật thể"]
        #expect(
            RailLayout.items.map(\.label).filter { !moved.contains($0) }
                == Self.canvasLabels.filter { !moved.contains($0) && !dropped.contains($0) })
    }

    @Test("Every item has a stable unique id and an icon")
    func descriptorsAreComplete() {
        #expect(Set(RailLayout.items.map(\.id)).count == RailLayout.items.count)
        for item in RailLayout.items {
            #expect(!item.id.isEmpty)
            #expect(!item.label.isEmpty)
            #expect(!item.systemImage.isEmpty, "\(item.id)")
        }
    }

    /// A rail item may not invent a namespace: every non-nil key has to be one
    /// the panel can resolve, or tapping it would silently do nothing.
    @Test("Every non-nil sectionKey resolves to a real slider section")
    func sectionKeysResolve() {
        for item in RailLayout.items {
            guard let key = item.sectionKey else { continue }
            #expect(EditState.SectionKey.all.contains(key), "\(item.id)")
            #expect(SliderPanelLayout.section(forKey: key)?.key == key, "\(item.id)")
        }
    }

    /// SPEC: Mặt → Face panel, Mắt/Bọng mắt/Răng → the one Mắt & Răng panel,
    /// Mịn da/Kiềm dầu → the one Da panel. Several items sharing a section is
    /// the point, not a mistake.
    @Test("The six active items point at the sections the wiring table names")
    func wiringTable() {
        let byLabel = Dictionary(uniqueKeysWithValues: RailLayout.items.map { ($0.label, $0) })
        #expect(byLabel["Mặt"]?.sectionKey == EditState.SectionKey.face)
        #expect(byLabel["Mắt"]?.sectionKey == EditState.SectionKey.eyesTeeth)
        #expect(byLabel["Bọng mắt"]?.sectionKey == EditState.SectionKey.eyesTeeth)
        #expect(byLabel["Răng"]?.sectionKey == EditState.SectionKey.eyesTeeth)
        #expect(byLabel["Mịn da"]?.sectionKey == EditState.SectionKey.skin)
        #expect(byLabel["Kiềm dầu"]?.sectionKey == EditState.SectionKey.skin)

        for item in RailLayout.items where Self.activeLabels.contains(item.label) {
            #expect(!item.isLocked, "\(item.label) should open a working panel")
        }
        // The pinned Màu chip is an active item too, and comes last — it is
        // drawn after the scrolling eighteen in both shells, because colour is
        // the user's last step.
        #expect(RailLayout.activeItems.map(\.label) == Self.expectedLabels.filter {
            Self.activeLabels.contains($0)
        } + ["Màu"])
    }

    /// Twelve locked: ten with no section at all, plus Trang điểm and Tóc
    /// whose sections exist but are themselves Phase 5. ("Xoá vật thể" is not
    /// among these — it was cut from scope entirely, not locked.)
    @Test("The other twelve items are locked, for the two different reasons")
    func lockedItems() {
        let locked = RailLayout.items.filter(\.isLocked)
        #expect(locked.count == 12)
        #expect(
            locked.map(\.label) == [
                "Mẫu", "Tự động", "Trang điểm", "Thu gọn", "Cơ thể", "Sửa da", "Săn chắc",
                "Căng mọng", "Mụn", "Đầu", "Tạo khối", "Tóc",
            ])

        // No section behind it at all: ten of the twelve.
        let unbacked = locked.filter { $0.sectionKey == nil }
        #expect(unbacked.count == 10)
        for item in unbacked { #expect(item.lockedHint == "chưa khả dụng", "\(item.id)") }

        // The two Phase 5 groups keep the panel's own wording.
        let phaseFive = locked.filter { $0.sectionKey != nil }
        #expect(phaseFive.map(\.sectionKey) == [
            EditState.SectionKey.makeup, EditState.SectionKey.hair,
        ])
        for item in phaseFive { #expect(item.lockedHint == "Phase 5 · chưa khả dụng") }
    }

    /// An item's icon must be the icon of the panel it opens, so the rail and
    /// the panel header do not disagree about what the tool is.
    @Test("An item that opens a section borrows that section's SF Symbol")
    func iconsMatchTheirSection() {
        for item in RailLayout.items {
            guard let key = item.sectionKey,
                let section = SliderPanelLayout.section(forKey: key)
            else { continue }
            #expect(item.systemImage == section.systemImage, "\(item.id)")
        }
    }

    /// SPEC: *"tap does nothing … must not crash/switch"*. A locked item leaves
    /// the panel where it was; an active one moves it, including when two items
    /// share the destination.
    @MainActor
    @Test("Tapping a rail item moves the panel only when something is behind it")
    func selectingFromTheRail() throws {
        let chrome = EditorChrome()
        let byLabel = Dictionary(uniqueKeysWithValues: RailLayout.items.map { ($0.label, $0) })
        chrome.activeGroupKey = EditState.SectionKey.skin

        for label in ["Mẫu", "Tự động", "Thu gọn", "Trang điểm", "Tóc"] {
            chrome.selectRailItem(try #require(byLabel[label]))
            #expect(chrome.activeGroupKey == EditState.SectionKey.skin, "\(label) switched the panel")
        }

        chrome.selectRailItem(try #require(byLabel["Bọng mắt"]))
        #expect(chrome.activeGroupKey == EditState.SectionKey.eyesTeeth)
        // …and "Mắt" and "Răng" now highlight with it, which is what the views
        // draw off `item.sectionKey == chrome.activeGroupKey`.
        #expect(byLabel["Mắt"]?.sectionKey == chrome.activeGroupKey)
        #expect(byLabel["Răng"]?.sectionKey == chrome.activeGroupKey)

        chrome.selectRailItem(try #require(byLabel["Mặt"]))
        #expect(chrome.activeGroupKey == EditState.SectionKey.face)
    }

    // MARK: - The pinned "Màu" affordance

    /// The regression this exists for: the eighteen-item rail replaced a
    /// six-group tab row, and the canvas's `RAIL` const has no colour entry — so
    /// for one commit the eighteen working Color sliders had **no** way in.
    /// `docs/design/SPEC.md` §"macOS panel (3f) structural note" asks for it as
    /// an always-visible top-level tab alongside the rail.
    @Test("Màu is a pinned rail item, last, not one of the scrolling eighteen")
    func colorItemIsPinnedAndSeparate() throws {
        #expect(!RailLayout.items.contains { $0.sectionKey == EditState.SectionKey.color })
        #expect(RailLayout.colorItem.sectionKey == EditState.SectionKey.color)
        #expect(!RailLayout.colorItem.isLocked)
        #expect(RailLayout.allItems.count == RailLayout.items.count + 1)
        // Last, not first: colour is the final step of the user's workflow. It
        // is still *pinned* (outside the scroll view in both shells), which is
        // what keeps the Color panel from being scrollable out of reach.
        #expect(RailLayout.allItems.last?.id == RailLayout.colorItem.id)
        #expect(Set(RailLayout.allItems.map(\.id)).count == RailLayout.allItems.count)

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
        chrome.activeGroupKey = EditState.SectionKey.skin

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

    /// The general form of the same rule: no working slider group may be
    /// orphaned by the rail. Today that is Da / Mặt / Mắt & Răng from the
    /// eighteen and Màu from the pinned chip; a seventh working group added in a
    /// later phase fails here until it gets an affordance.
    @Test("Every unlocked slider section is reachable from the rail")
    func noWorkingSectionIsOrphaned() {
        let working = Set(SliderPanelLayout.sections.filter { !$0.isLocked }.map(\.key))
        #expect(working.count == 4)
        #expect(RailLayout.reachableSectionKeys == working)
    }
}
