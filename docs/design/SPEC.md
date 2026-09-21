# RetouchPro UI Design Spec (from Claude Design canvas)

Source: `claude.ai/design/p/60d411fe-7fe5-43ed-a8fe-2a1d6e4314d1` ("RetouchProApp Mobile macOS Design").
Raw mockup markup mirrored at `docs/design/RetouchPro.dc.html` (exact colors/spacing/copy — treat as ground truth
for pixel values). Rendered reference screenshots: `docs/design/screenshots/*.png`. This file is the distilled
checklist coder/reviewer use instead of re-parsing the HTML each time.

**Scope note:** the mockup is app-shell/chrome only (colors, layout, copy, interaction affordances). It does not
change any Fixed Decision in `docs/PLAN.md` (Evoto-style layout, sliders 0-100 default 0, on-device only) — except
that the Màu (Color) group is now **-100…100, default 0** for 16 of its 18 sliders (`curves`/`autoDodgeBurn` stay
0-100); see `docs/ADR-0016-bidirectional-color-sliders.md`. Da/Mặt/Mắt-Răng stay 0-100 as originally specced. Its
slider taxonomy already matches the Phase 2 RenderGraph groups exactly (see mapping table below) — implementing
this spec is primarily an RPUI wiring/visual task, not a new-feature task.

## Palette / type
- Canvas background (both platforms, dark): `#0c0d0f`; chrome/panels `#141518` / `#111214` / `#17191d` (sheet) / `#191b1f` (dialog).
- Accent (mint): `#7de3c3` foreground-on-accent text `#06231c`. Used for: primary buttons, active tab underline/rail icon, active slider fill+thumb-track, active value color, "Sau/After" badge.
- Text: primary `#f2f4f7`, secondary `#9aa1ab` / `#8b929c`, tertiary/meta `#6e757f`, slider row label `#d6dae0`.
- Star rating color: `#e8c46a`.
- Fonts: UI text "Be Vietnam Pro" (400/500/600/700), monospace bits (clock, filenames, EXIF, percentages, "on-device · Metal") "JetBrains Mono". Fall back to SF Pro / SF Mono on-platform — do not bundle web fonts, use system fonts with matching weight.
- Borders/dividers: `rgba(255,255,255,.06-.09)` hairlines on dark chrome.
- Corner radii: cards/thumbnails 4-8px, sheets/panels 12-16px, pills/buttons 999px (full) or 7-10px, phone frame 42-52px.

## Slider group → engine key mapping (already built in RPEngine — this is a naming/order contract, not new math)
| Design label (group) | Design slider labels (order) | RPEngine group / keys |
|---|---|---|
| Da | Mịn da, Giữ texture, Đều màu da, Khử đỏ, Khử bóng dầu, Sáng da, Quầng thâm, Nếp nhăn | Skin (8 keys, `SkinSliders.Key.all` order) — one engine group and one `EditState` namespace, but **two UI panels** since 2026-09-18: "Mịn da" (the 7 others) and "Kiềm dầu" (Khử bóng dầu). See §Turn 3's rail-hierarchy note. |
| Mặt | Bóp mặt, Gò má, Hàm, Cằm, Trán, Thái dương, Sống mũi, Cánh mũi, Đầu mũi, To mắt, Khoảng cách mắt, Nghiêng mắt, Rộng miệng, Cao miệng, Môi đầy | Warp/Face (15 keys, `WarpSliders.Key.all` order) |
| Mắt & Răng | Sáng mắt, Trắng lòng trắng, Nét mắt, Trắng răng | EyesTeeth (4 keys) — one engine group and one `EditState` namespace, but **two UI panels** since 2026-09-18: "Mắt" (first 3) and "Răng" (Trắng răng). See §Turn 3's reversal note. |
| Màu | Phơi sáng, Tương phản, Vùng sáng, Vùng tối, Nhiệt độ, Sắc độ, Rực rỡ, Bão hoà, Curves, HSL·Đỏ/Cam/Vàng/Lục/Lam/Lơ/Tím/Hồng, Dodge & Burn tự động | Color (18 keys) |
| Trang điểm | (empty — Phase 5) | locked, opacity 0.38, non-clickable, section label shows "Phase 5 · chưa khả dụng" |
| Tóc | (empty — Phase 5) | locked, same treatment |

Verify design slider *count and order* against each `*Sliders.Key.all` in RPEngine exactly — if a name differs
(e.g. design says "Đầu nhũi" for nose-tip, likely a typo for "Đầu mũi"), use the corrected Vietnamese label but
keep engine key order authoritative. Do not reorder or rename engine keys to match the mockup; only the
*display label* is a UI concern.

## Screen 1a — iPhone editor (full-bleed canvas + bottom tool sheet)
- Top bar (44pt-ish row): back chevron `‹` · "Nhập" (import) icon+label · spacer · hold-to-compare eye icon (press-and-hold shows original, background highlights mint-tint while held) · "Fit" zoom pill · `···` overflow · mint "Xuất" (export) pill button.
- Canvas: full width/height black area, image fills it. Overlay (non-blocking except its own controls):
  - Top-left: face-selection pill chips (one per detected face, "Mặt 1"/"Mặt 2"...), selected chip mint-filled, others translucent dark+blur.
  - Bottom-left: "Đồng bộ" (sync) pill toggle — mint text when on.
  - Bottom-left next to it: subject-category pill ("Nữ"/"Nam"/"Trẻ em"/"Tất cả") with chevron, cycles on tap.
  - Bottom-right: before/after split-view icon toggle button (circular, translucent dark+blur).
- Bottom sheet (attached, not modal): grabber handle, scrollable slider list (~250pt tall) for the *currently selected group*, each row = label + mono value on top, custom track below (13px thumb, mint fill up to value, thumb draggable via horizontal pan — no native `Slider` chrome, matches mockup's flat-track custom style), then a fixed row of group tabs (icon + tiny label) across the bottom: Da / Mặt / Mắt & Răng / Màu / Trang điểm(locked) / Tóc(locked); home indicator bar under it. (Turn 3 replaced this six-tab row with the tool rail — flat 19 items at first, then the two-level body-part → sub-feature rail of 2026-09-18 — and on the same day "Mắt & Răng" became the panels "Mắt"/"Răng" and "Da" became "Mịn da"/"Kiềm dầu". See §Turn 3.)
- Locked groups: 38% opacity, tap does nothing (or shows "Phase 5" toast — no hard requirement, just must not crash/switch).

## Screen 1b — macOS editor (three-pane: canvas, right slider panel, far-right icon rail)
- Titlebar-height toolbar (46pt): traffic-light spacing reserved (macOS draws real ones — leave inset), vertical divider, 4 tool icons (Pan/hand, Heal/tẩy vết, Brush/cọ, Undo/hoàn tác) as a segmented icon group, spacer, "Thư viện"/"Chỉnh sửa" tab switcher (underline on active), spacer, "on-device · Metal" mono caption, mint "Xuất" button.
- Center column: before/after side-by-side (two equal panes, 2px gap), "Trước"/"Sau" badges top-left of each (Sau badge is mint-filled), face chips bottom-left of the "Sau" pane only. Below: 104pt filmstrip strip — horizontal thumbnails (68×76, 2px border, mint when selected) + right-aligned status cluster (photo count · rating stars (interactive) · zoom%).
- Right panel (326pt fixed): header = active group icon+title + "Đặt lại" (reset) button; scrollable slider list with same custom-track style as mobile but 14px thumb; footer row = disabled "Lưu preset · Phase 3" chip + "Đồng bộ" sync toggle button.
- Far-right icon rail (56pt fixed): vertical stack of the same 6 group icons as mobile's bottom tabs, active one gets mint icon + faint mint rail background pill; locked ones dimmed.

## Screen 2a — iPhone library (empty/list state)
- Header: "Thư viện" title + "Lưu trong ứng dụng · N ảnh" subtitle, search icon button, mint "+" add button.
- Filter pill row: Tất cả (active, light pill) / Đã chỉnh / RAW.
- 3-column grid of thumbnails (3:4 aspect), each with filename caption bottom-left and format tag (RAW/HEIC) top-right chip.
- Persistent import card (dashed border) pinned above home indicator when library is otherwise empty or always visible as an entry point: "Nhập ảnh để bắt đầu", format hint text, two buttons Files (mint, primary) / Photos (secondary).

## Screen 2b — iPhone export sheet (modal, presented over dimmed canvas)
- Background: current canvas dimmed (62% black scrim).
- Bottom sheet: grabber, "Xuất ảnh" title + mono "‹id› · WxH" caption, then export option rows — each row = label + 2-3 choice pills (selected pill mint-tinted bg + mint text, others neutral). Rows: Định dạng (JPEG/HEIF/TIFF), Chất lượng (80/92/100), Kích thước (Gốc/Dài 4000px/Dài 2048px), Không gian màu (sRGB/Display P3).
- Footer: size estimate + "xử lý on-device" caption, "Batch: Phase 3" note (batch export is out of scope until Phase 3 — single-image export only for now), Huỷ (cancel, secondary, flex 1) / "Xuất 1 ảnh" (primary mint, flex 2) buttons, home indicator.

## Screen 2c — macOS library tab
- Toolbar: traffic lights, spacer, Thư viện/Chỉnh sửa tab switcher (Thư viện active here), spacer, "Nhập…" secondary button, mint "Xuất" button.
- Left sidebar (212pt): "NGUỒN" section (Buổi chụp·date / Đã nhập / Nháp chưa xuất / Tất cả ảnh, each with count, active = mint tint bg), "LỌC" section (star≥3 chip mint-tinted active, RAW chip, Đã chỉnh chip — neutral until toggled), spacer, footnote card "Tethering qua cáp — Phase 4 · chưa bật" (must literally communicate tethering is not available yet).
- Center: header row (shoot title + date, mono "N ảnh · M chọn" count, interactive 5-star rating for the selection), scrollable 5-column thumbnail grid (3:4, filename+stars caption bar, format tag chip, 2px outline mint when selected).
- Right info panel (268pt): large thumbnail, filename, EXIF-style metadata rows (Định dạng/Kích thước/ISO/Khẩu độ/Tốc độ/Số mặt nhận diện — the last one is a real FaceAnalyzer output, not decorative), mint "Mở trong Chỉnh sửa" button that navigates to the Edit tab with that shot active.

## Screen 2d — macOS export dialog + progress
- Modal over blurred/dimmed library background. Dialog (520pt wide): header "Xuất N ảnh" + "on-device" mono caption; same export option rows as 2b; a folder-path row ("Thư mục" + path + chevron, opens a folder picker — NSOpenPanel choosing directories only); a progress card once export starts: "Đang xử lý <filename>" + "n / total" mono counter + thin progress bar (mint fill). Footer: Huỷ / Xuất buttons.
- This is the *batch/multi-select* export path (title says "Xuất N ảnh") — single-image export (2b-equivalent on macOS) should reuse the same dialog with N=1 and no progress card until processing starts.

## Cross-cutting interaction rules
1. **Sync toggle** ("Đồng bộ"): when on, slider edits apply to all synced/selected faces or shots (exact semantics were left open in the mockup — for a single detected face this is inert; for multi-face it should broadcast the same slider delta to all detected faces unless a specific face chip is selected, matching `perImage["selectedFace"]` already in EditState per PLAN §Phase 2 note). Do not invent new EditState fields beyond what's already there; if sync needs new state, flag it back as a scope question rather than guessing silently.
2. **Face chips**: selecting a chip narrows the render to that face only (already implemented per PLAN's "Chọn mặt" work — `RenderRequest.faces`). The mockup's chip UI is the missing piece, not the underlying mechanism.
3. **Hold-to-compare** (1a's eye icon) and the **before/after split** (1a's toggle icon, 1b's fixed dual-pane) show the original vs. edited image — reuse whatever before/after mechanism already exists in `CanvasView`/`LivePreviewController` rather than re-decoding a second time.
4. **Locked groups** (Trang điểm, Tóc) must render (dimmed, inert) — do not hide them, so the shell shows the full future taxonomy per plan.
5. **Star rating & filters** on library screens are simple metadata on `Shot`/`Project` (rating int, format tag) — not gated behind Phase 2 vision work.
6. All copy is Vietnamese, matching the mockup's exact strings where given (e.g. "Xuất ảnh", "Đặt lại", "Đồng bộ") — keep these as literal user-facing strings, not placeholders.

## Turn 3 — expanded toolset rail (screens 3a-3f, added 2026-09-10)

**Scope decision (user, 2026-09-10):** this turn adds a much bigger tool taxonomy (19-item rail vs. the
6-group taxonomy above) plus several genuinely new capabilities — manual mask brush, background lock via
segmentation, one-tap "Tự động" retouch, body/head reshape, contouring, object removal, acne removal, a
template gallery, and a curated "Looks" picker. **Directive: ship the navigation/visual shell for all of it,
wire only what already has a real engine slider behind it, and lock everything else** using the same dimmed/
inert treatment already established for Trang điểm/Tóc in Screen 1a/1b — do not build new render-graph
capability as part of this pass. See `docs/PLAN.md` new phase entry for the deferred-work list.

### The 19-item rail (icon + label, from the canvas script's `RAIL` const, in order) — SUPERSEDED 2026-09-18
> **This flat 19-item structure is history.** It is kept because the membership and the icon-fidelity rule
> below are still the source of what shipped, but the *shape* is now two levels (body part → sub-feature) —
> see the "Rail hierarchy" note two sub-sections down. Read this section as the starting point, not as the
> current rail.
Mẫu(layers) · Răng(tooth) · Tự động(spark) · Trang điểm(brush) · Mặt(face) · Thu gọn(slim) · Cơ thể(body) ·
Mịn da(drop) · Sửa da(spark) · Săn chắc(slim) · Căng mọng(drop) · Mụn(oval) · Đầu(oval) · Tạo khối(spark) ·
Kiềm dầu(drop) · Mắt(eye) · Bọng mắt(eye) · Tóc(hair) · Xoá vật thể(erase).

Render all 19 as a horizontal scroll rail on iPhone (screen 3a, bottom of tool sheet) and a vertical 64pt icon
rail on macOS (screen 3f, far right) — same icon/label pairs both places. Active item = mint icon + mint
12%-opacity pill background; inactive = `#c9ccd1`/transparent.

**Icon fidelity (decided during implementation, 2026-09-10):** for the 6 active items, the rail icon is the
underlying `SliderSectionDescriptor.systemImage` it opens, not the mockup's own hand-drawn glyph, so the rail
icon can never visually disagree with the panel it opens. SF Symbol fidelity to the mockup's custom icon set
was never a goal (the mockup's icons are hand-drawn SVG paths with no SF Symbol equivalent for most of them
anyway). The rule itself still stands; the example it used to give — "Răng" borrowing `eye` from a shared
panel — does not, see the reversal below.

> **Reversed 2026-09-18 — "Răng" is its own panel with its own icon.**
> This section previously called the shared `eye` icon *and* the shared four-slider "Mắt & Răng" panel
> "intentional and permanent, not a placeholder", and the wiring table below promised a panel
> "filtered/scrolled" to each item's keys. Two things were wrong with that. The filtering was never built —
> the panel always showed all four sliders unfiltered — and the user reported the result as a **functional
> error, not a cosmetic one**: tapping "Răng" opened Sáng mắt / Trắng lòng trắng / Nét mắt / Trắng răng and
> lit "Mắt" and "Bọng mắt" up at the same time, i.e. the app answered a question about teeth with three eye
> controls. Their correction, taken as the decision: **"Răng" shows exactly one slider, "Trắng răng"; "Mắt"
> and "Bọng mắt" are one group (same body part) with the other three.**
>
> What shipped: `SliderPanelLayout.sections` now carries **seven panels over six `EditState` namespaces** —
> "Mắt" (3 sliders, `eye`) and "Răng" (1 slider, `mouth`) both writing `EditState.SectionKey.eyesTeeth`
> through the new `SliderSectionDescriptor.storageKey`. The split is **UI-only**: the namespace,
> `EyesTeethSliders` and `EyesTeethRenderNode` still handle the four keys together, so no document, preset or
> render-graph node changed and nothing on disk migrated. `SliderPanelLayoutTests` keeps the old invariant in
> its honest form — every namespace in `EditState.SectionKey.all` has a panel, in RPCore's order — rather than
> "exactly one panel per namespace".
>
> Icon: SF Symbols on macOS 15 / iOS 18 has **no tooth glyph** (`tooth`, `teeth` and `lips` do not resolve;
> checked at build time and pinned by `RailLayoutTests.everySymbolExists`). "Răng" uses `mouth`, which is also
> where the whitening happens — the node reads the mouth *interior* mask, there is no teeth parsing class.

### Rail hierarchy — the flat rail becomes body part → sub-feature (decided 2026-09-18, second note of the day)
The "Răng" fix above was the first of three rounds of feedback on the same underlying problem, and the third
one replaced the structure rather than patching another pair. In order:

1. **"Răng" opened the eye panel** (fixed above — its own panel, its own icon).
2. **"Mắt" and "Bọng mắt" were two doors into one place.** The note above called two entries on one panel
   *correct* because they are the same body part. The user rejected that outright: there is no visible
   difference between the two entries, they light up together, and one of them is therefore pure noise —
   *"there should be exactly one icon, not two doors into the same content."*
3. **"Mịn da" and "Kiềm dầu" were the same bug as (1), unfixed** — same `sparkles` glyph, same unfiltered
   eight-slider panel, so "Kiềm dầu" answered a question about oil with seven controls that are not about oil.

**Decision (user, explicit, confirmed):** stop de-duplicating pairs and restructure the rail into **two levels
— body part (parent) → sub-feature (child)**. What shipped:

**Top level: 8 scrolling entries + the pinned "Màu" chip** (was 19 + pinned). **Three parents.**

| Top-level entry | Kind | Children (in order) |
|---|---|---|
| **Mặt** (`face.dashed`) | parent | Hình dáng mặt · Mắt · Răng · Đầu · Tạo khối · Căng mọng · Mụn |
| **Da** (`circle.hexagongrid`) | parent | Mịn da · Kiềm dầu · Sửa da |
| Mẫu | leaf (screen) | — |
| Tự động | leaf (locked) | — |
| Trang điểm | leaf (Phase 5) | — |
| **Cơ thể** (`figure.stand`) | parent | Thu gọn · Săn chắc |
| Tóc | leaf (Phase 5) | — |
| Khoá nền | leaf (locked, Phase 6.1) | — |
| *Màu* | pinned leaf, outside the scroll | — |

Everything that is not one of the three parents keeps the relative order it already had.

**"Da" is a parent of its own, not a sub-feature of "Mặt"** (user's correction, same day, after a first pass
filed Mịn da/Kiềm dầu under the face): **skin smoothing is a whole-body concept**. Today's engine only reaches
it through a face mask, but extending that to neck/arms/chest is exactly what "Sửa da"
(`bodySkinSync`) is for — so "Sửa da" is a **child of "Da"**, i.e. this group's own scope switch, rather than a
top-level item floating next to the parents. (It stopped being locked on 2026-09-21: it opens a one-switch
panel of its own — docs/ADR-0021 §UI.)

Three membership changes, all deliberate:
* **"Bọng mắt" is deleted**, not repointed — point (2) above. There is now exactly one entry into the eye panel.
* **The old top-level "Mặt" leaf is the child "Hình dáng mặt"** — same 15 sliders, same
  `EditState.SectionKey.face`, unchanged content; renamed only so a parent and one of its children are not
  both called "Mặt".
* **"Mịn da" / "Kiềm dầu" split into two panels** the same way Mắt/Răng did: `PanelKey.smooth` (7 sliders) and
  `PanelKey.shine` (1, Khử bóng dầu), both writing `EditState.SectionKey.skin` through `storageKey`. UI-only —
  `SkinSliders` and the render node still handle all eight keys together, nothing on disk migrated.
  "Kiềm dầu" gets `humidity`; reusing `sparkles` is what caused the complaint. (`face.dashed` for the "Mặt"
  parent, for the same reason one level up: its child "Hình dáng mặt" owns `face.smiling`.)
* **"Căng mọng" is filed under "Mặt"**, not "Cơ thể" — user's call, it is lip plumping. Still locked.

**Interaction:** tapping a **parent** does not open a panel of its own — it opens its **first unlocked child**
(or the first child when the whole group is locked, which is inert exactly as a locked item already is) and the
panel then shows that parent's children as a **second-level pill strip inside the panel** (`RailChildStrip`,
same mint-on-faint-mint language as the rail's own selected state, one level deeper — not new chrome). Tapping
a **leaf**, anywhere, behaves exactly as every rail item did before. The rail's highlight rule generalises:
`RailItemDescriptor.opensPanel(activeGroupKey)`, so a parent is highlighted whenever any of its children's
panels is open. **No two siblings share a panel any more**, which is the invariant the whole restructuring
buys (`RailLayoutTests.oneDoorPerThing`). This is exactly one level deep: the canvas's own third level (the
per-tool grid + single "Cường độ" slider) is still locked, see below.

**Wiring policy — active vs. locked (updated 2026-09-18 for the hierarchy):**
| Rail item | Status | Behavior |
|---|---|---|
| Mặt *(parent)* | **Active** | No panel of its own; opens "Hình dáng mặt" and shows the child strip. Locked only if all 7 children were locked. |
| Hình dáng mặt *(child of Mặt)* | **Active** | Opens the Face/Warp panel (all 15 keys, flat `SliderPanelView` list — not the per-tool grid below, that grid UI is itself locked) |
| Mắt *(child of Mặt)* | **Active** | Opens the **Mắt** panel: exactly the 3 eye keys. The only entry into it — ~~Bọng mắt~~ was deleted 2026-09-18. |
| Răng *(child of Mặt)* | **Active** | Opens the **Răng** panel: exactly one slider, Trắng răng. Own `sectionKey`, own icon (`mouth`). |
| Da *(parent)* | **Active** | No panel of its own; opens "Mịn da" and shows its strip. Unlocked because its children work — all three of them since 2026-09-21. |
| Mịn da *(child of Da)* | **Active** | Opens the **Mịn da** panel: 7 skin sliders, everything except Khử bóng dầu |
| Kiềm dầu *(child of Da)* | **Active** | Opens the **Kiềm dầu** panel: exactly one slider, Khử bóng dầu. Its own `sectionKey` and its own icon (`humidity`) since 2026-09-18 — it must never highlight together with Mịn da. |
| Sửa da *(child of Da)* | **Active (2026-09-21)** | Opens the **Sửa da** panel: the one panel with no slider in it, a single switch "Đồng bộ da toàn thân" over `EditState.sections["mask"]["bodySkinSync"]`. Not locked, and inert anyway while `RPEngineFeatureFlags.bodySkinSync` is off — the panel says so in one line, the `PanelFeatureGate` treatment "Tạo khối" introduced. It is the one panel that also carries a **detection notice** ("Không phát hiện được da.") because the whole-body classifier really can find nothing — deep skin tones, docs/ADR-0021 §5, unfixed. Relocated from top level into "Da" on 2026-09-18. |
| Mẫu | **Active (screen)** | Opens the preset library (Phase 3), leaves the slider panel where it was |
| Màu (pinned) | **Active** | Opens the Color panel; outside the scroll view, see the structural note below |
| Trang điểm, Tóc | Locked (Phase 5, unchanged) | Same treatment as Screen 1a/1b already spec'd |
| Cơ thể *(parent)* + Thu gọn, Săn chắc | **Locked** | Parent is locked because every child is; tap is inert |
| Đầu *(child of Mặt)* | **Active (2026-09-21)** | Opens the **Đầu** panel: three sliders — Thu nhỏ đầu / Hẹp đầu / Phồng tóc — over `HeadSliders.Key`, the third panel on the `face` namespace (docs/ADR-0022 §UI). Not locked, and inert anyway while `RPEngineFeatureFlags.headSliders` is off — the panel says so in one line (`PanelFeatureGate`). It is the second panel to carry a **detection notice** ("Không phát hiện được viền tóc.", from `WarpRenderNode`) because the hair trace really can find nothing: a hat, a shaved head, a parsing miss. The notice is scoped to this panel — "Hình dáng mặt" shares the `warp` node, names no node, and keeps all fifteen sliders working. |
| Tạo khối *(child of Mặt)* | **Active (2026-09-21)** | Opens the **Tạo khối** panel: three sliders — Gò má / Sống mũi / Hàm — over `ContourSliders.Key`, also on the `face` namespace (docs/ADR-0020 §UI). Not locked, inert while `RPEngineFeatureFlags.contourSliders` is off, same `PanelFeatureGate` treatment. No detection notice: it is pure landmark geometry. |
| Tự động, Khoá nền, and the children Căng mọng, Mụn | **Locked, new phase** | Dimmed 38% opacity, tap is inert (no crash, no panel switch) — no engine work backs these yet, except "Khoá nền", whose engine is finished and held back for an iPhone measurement (docs/ADR-0018) |
| ~~Bọng mắt~~ | **Deleted (2026-09-18)** | Not locked, not present — it was a duplicate door into the Mắt panel |
| ~~Xoá vật thể~~ | **Cut from scope (2026-09-11)** | Removed from the shipped rail entirely — not locked, not present. See callout below. |

**Cut from scope (decided 2026-09-11):** "Xoá vật thể" (free-form object removal) is removed from the rail
entirely, not merely locked — user's call, reasoning: the project's face pipeline (Vision → BlazeFace →
478-point mesh → BiSeNet parsing) has no bearing on arbitrary objects anywhere in a frame, so there's no
existing model/detector this feature could lean on the way other locked items lean on landmarks/parsing; it
would need a from-scratch selection+inpainting subsystem (manual brush selection + LaMa crop/resize/blend, per
`docs/PLAN.md`'s research) with no reuse of what the project has built. `Mụn`'s planned LaMa use (Phase 5, DoG
blob-detect → heal, large areas via LaMa) is **not** affected — that is blob-detected blemishes inside a known
skin mask, a different and much narrower problem than free-form user-selected regions. Do not resurrect this
rail item without a new explicit decision; the canvas's own `RAIL` const in `RetouchPro.dc.html` still lists it
(design source, left as-is) — the shipped `RailLayout.swift` deliberately diverges here, same pattern as the
existing reorder-vs-canvas deviation already documented there.

### Per-tool grid + single-intensity-slider pattern (screens 3b/3e/3f `faceTools`/`eyesTools`/`teethTools`)
The mockup's finer interaction — pick a sub-region tab (`faceSub`: Biểu cảm/3D Reshape/Tỷ lệ/Khuôn mặt/Chân
mày/Mắt/Mũi/Môi), then a grid of named tool icons (`FACE_TOOLS`: HD Portrait, Tự động, Độ rộng, Nâng, Làm
mượt, Thái dương, Gò má, Dài cằm, Ngấn cổ, Ngấn Pro, Cằm V, Mặt V, Góc hàm, Đường hàm, Đường chân tóc), then
one generic "Cường độ" slider for whichever tool is selected — is a **different micro-UX from the current
flat-list panel** and most of those named tools (HD Portrait, Ngấn cổ/double-chin, Ngấn Pro, Cằm V, Mặt V,
Đường chân tóc, etc.) have no corresponding `WarpSliders.Key`. **This whole pattern is locked/deferred** —
do not build the subtab+grid+single-slider chrome this pass. Same for `EYES_TOOLS` (10 named tools, only
"Sáng mắt" exists) and `TEETH_TOOLS` (5 named tools, only "Làm trắng" ≈ existing Trắng răng).

### New chrome, all locked/inert this pass
- **Khoá nền (background lock)** — pill toggle with switch knob, appears on canvas (3b/3c, floating bottom-
  center) and in the macOS toolbar (3f). Render the toggle and let it flip its own visual state, but it must
  not gate any render node — no segmentation work this pass.
- **Tự động / Thủ công (Auto/Manual mode segmented control)** — appears in 3c/3e/3f. "Tự động" stays selected
  and active (it's just today's automatic slider behavior); "Thủ công" (manual) renders but is locked — tapping
  it must not switch modes.
- **Cỡ cọ (brush size) + Vẽ/Xoá (brush add/erase) + mask-mode icons (Cổ điển/Nhanh/Phục hồi)** — only ever
  shown once "Thủ công" is reachable, which it isn't. Render statically dimmed for visual completeness if
  the manual-mode screen is built at all; do not wire pointer/drag handling for a paint mask.
- **Mẫu (templates)** — category tabs (Cho bạn/Của tôi/Yêu thích) + thumbnail strip + "Thêm" add card. Fully
  locked: render the gallery, selection state may exist locally in the view but must not call
  `EditState`/`Preset` apply.
- **Looks / AI Retouch** (screen 3d) — tabs "AI Retouch / Cho bạn / Thêm" + 5 preset swatches (Gốc, Tự nhiên,
  Normcore, Sữa, Điện ảnh) + a `lookTabs` row (Tỷ lệ/Looks/Kết cấu) + one intensity slider. Fully locked, same
  render-but-inert rule as Mẫu.

**Tab rename (decided 2026-09-11, applies when these screens are built in Phase 3):** the mockup's "Cho bạn"
tab in both Mẫu and Looks ships as a **static curated list**, not real personalization, for v1 — real
per-person personalization is a separate later feature (`docs/PLAN.md` §Phase 6.6, "Tự động v2"). Shipping the
label "Cho bạn" over a static list over-promises, so the tab is **renamed to "Nổi bật"** (or another neutral
label — not a hard requirement on the exact word, just: not "Cho bạn") in the real implementation. The two
strings above are still the mockup's literal wording, left as-is for canvas fidelity.

### macOS panel (3f) structural note
Right panel restructures to: `faceSub` tabs → mode segmented control + "Toàn mặt" dropdown → faceTools 4-col
grid → one slider → brush size + brush mode row → far-right 64pt icon rail (the 19-item RAIL, vertical). This
whole right-panel restructuring is itself part of the locked per-tool-grid pattern above — **do not replace
the current working macOS slider panel** with this structure. Only the vertical 19-item rail is new/real
navigation to build; it should sit where the existing 6-icon group rail sits today, superseding it (19 items
instead of 6, since Mặt/Mắt/Răng/Mịn da/Kiềm dầu now live in this rail per the table above) — confirm this
replacement doesn't orphan Màu/Trang điểm/Tóc access (Màu isn't in the 19-item rail at all in the mockup;
keep a way to reach the Color panel — e.g. keep it as an always-visible top-level tab alongside the rail
rather than dropping it).
