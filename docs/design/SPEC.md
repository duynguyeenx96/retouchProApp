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
| Da | Mịn da, Giữ texture, Đều màu da, Khử đỏ, Khử bóng dầu, Sáng da, Quầng thâm, Nếp nhăn | Skin (8 keys, `SkinSliders.Key.all` order) |
| Mặt | Bóp mặt, Gò má, Hàm, Cằm, Trán, Thái dương, Sống mũi, Cánh mũi, Đầu mũi, To mắt, Khoảng cách mắt, Nghiêng mắt, Rộng miệng, Cao miệng, Môi đầy | Warp/Face (15 keys, `WarpSliders.Key.all` order) |
| Mắt & Răng | Sáng mắt, Trắng lòng trắng, Nét mắt, Trắng răng | EyesTeeth (4 keys) |
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
- Bottom sheet (attached, not modal): grabber handle, scrollable slider list (~250pt tall) for the *currently selected group*, each row = label + mono value on top, custom track below (13px thumb, mint fill up to value, thumb draggable via horizontal pan — no native `Slider` chrome, matches mockup's flat-track custom style), then a fixed row of group tabs (icon + tiny label) across the bottom: Da / Mặt / Mắt & Răng / Màu / Trang điểm(locked) / Tóc(locked); home indicator bar under it.
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

### The 19-item rail (icon + label, from the canvas script's `RAIL` const, in order)
Mẫu(layers) · Răng(tooth) · Tự động(spark) · Trang điểm(brush) · Mặt(face) · Thu gọn(slim) · Cơ thể(body) ·
Mịn da(drop) · Sửa da(spark) · Săn chắc(slim) · Căng mọng(drop) · Mụn(oval) · Đầu(oval) · Tạo khối(spark) ·
Kiềm dầu(drop) · Mắt(eye) · Bọng mắt(eye) · Tóc(hair) · Xoá vật thể(erase).

Render all 19 as a horizontal scroll rail on iPhone (screen 3a, bottom of tool sheet) and a vertical 64pt icon
rail on macOS (screen 3f, far right) — same icon/label pairs both places. Active item = mint icon + mint
12%-opacity pill background; inactive = `#c9ccd1`/transparent.

**Icon fidelity (decided during implementation, 2026-09-10):** for the 6 active items, the rail icon is the
underlying `SliderSectionDescriptor.systemImage` it opens, not the mockup's own hand-drawn glyph — e.g. "Răng"
uses the `eye` SF Symbol (the shared Mắt & Răng panel's icon) rather than a tooth glyph, so the rail icon can
never visually disagree with the panel it opens. This is intentional and permanent, not a placeholder — SF
Symbol fidelity to the mockup's custom icon set was never a goal (the mockup's icons are hand-drawn SVG paths
with no SF Symbol equivalent for most of them anyway).

**Wiring policy — active vs. locked:**
| Rail item | Status | Behavior |
|---|---|---|
| Mặt | **Active** | Opens the existing Face/Warp slider panel (all 15 keys, current flat `SliderPanelView` list — not the new per-tool grid described below, that grid UI is itself locked, see below) |
| Mắt, Bọng mắt | **Active** (both) | Opens the existing Mắt & Răng panel filtered/scrolled to the 3 eye keys (Sáng mắt, Trắng lòng trắng, Nét mắt). Two rail entries intentionally point at the same real panel — do not build separate eye-bag logic. |
| Răng | **Active** | Opens the existing Mắt & Răng panel scrolled to Trắng răng |
| Mịn da, Kiềm dầu | **Active** | Opens the existing Da/Skin panel (Mịn da, Khử bóng dầu already exist as real keys there) |
| Trang điểm, Tóc | Locked (Phase 5, unchanged) | Same treatment as Screen 1a/1b already spec'd |
| Mẫu, Tự động, Thu gọn, Cơ thể, Sửa da, Săn chắc, Căng mọng, Mụn, Đầu, Tạo khối | **Locked, new phase** | Dimmed 38% opacity, tap is inert (no crash, no panel switch, optional "chưa khả dụng" toast) — no engine work backs these yet |
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
