**Đã xử lý (2026-09-11):** file này đã được lên plan chi tiết trong `docs/PLAN.md` — xem mục "Cập nhật kế hoạch
(2026-09-11) — Phase 6 chi tiết + Share Extension", Phase 3/3B mới, và Phase 6 viết lại theo thứ tự phụ thuộc.
**Cùng ngày, cập nhật lần 2:** "Xoá vật thể" (§2.2 mục 9) đã bị **cắt khỏi phạm vi hẳn** (không phải khoá) và
"Sửa da" (§2.2 mục 5, trước đây là câu hỏi mở) đã **chốt nghĩa** = đồng bộ hiệu ứng da từ mặt ra toàn thân —
xem "Cập nhật lần 2" trong PLAN.md.
**Cùng ngày, cập nhật lần 3:** **iPadOS đã bị loại bỏ hẳn khỏi phạm vi triển khai** (không còn "tạm pending" như
PLAN §0.1 — đã sửa cả cấu hình Xcode thật, xem PLAN §0.2). Mọi mô tả "macOS + iPadOS + iOS" hay "iPhone/iPad"
trong file này (§0, §1.3, §3.3, §3.4, §4.1) chỉ còn đúng cho phần **macOS + iOS (iPhone)**; giữ nguyên chữ gốc
làm tài liệu lịch sử/bối cảnh gốc, không sửa lại từng dòng.

# Retouch Pro — Handoff: done vs. chưa làm (2026-09-10)

**Mục đích file này:** tóm tắt cho Fable 5 lên plan chi tiết cho các tính năng **chưa làm** — trọng tâm là
nhóm tính năng vừa mới có **UI (rail icon) nhưng bị khoá/inert**, thêm vào hôm nay (2026-09-10) theo turn 3
của design canvas. Không cần đọc lại toàn bộ `docs/PLAN.md`/ADR để có context — file này tự đủ.

## 0. Bối cảnh dự án (tối thiểu cần biết)

- App ảnh chân dung độc lập (kiểu Evoto/Meitu), **Swift/SwiftUI native**, 1 codebase macOS 15+ / iPadOS+iOS 18+.
  AI on-device only, không server. Chạy local (Development signing), không lên App Store.
  Camera Sony a6300, iPad hiện tại là A-series (ảnh hưởng riêng phần tethering, xem §3.4).
- Kiến trúc gói: `RPCore` (EditState/Preset/ProjectStore, thuần Swift) → `RPVision` (FaceAnalyzer: Vision +
  Core ML landmark 478 điểm + face parsing 19 lớp) → `RPEngine` (RenderGraph Metal: Color → Skin → Warp →
  Eyes/Teeth → [Makeup] → Output; chưa import RPVision, nhận `FaceRenderInput` value-type qua seam) →
  `RPImport` (Files/Photos/MTP/FolderWatcher) → `RPUI` (SwiftUI, mọi UI). App target lắp keo mọi thứ lại.
- Nguyên tắc cứng của dự án (đã lặp lại nhiều lần, Fable 5 nên giữ khi lên plan mới):
  - **"Measure before ship"**: mọi thuật toán mask/landmark/hiệu năng phải có số đo thật (golden PSNR, IoU,
    bench ms/frame), không suy đoán từ mắt nhìn hay tài liệu model gốc.
  - **Slider mặc định 0, 0 luôn là trung tính**; `EditSection.setSlider` xoá key khi về 0 — không được có
    slider trung tính ở giữa thang mà không phải 0.
  - **Tính năng lớn/tốn effort → làm UI trước (dimmed/inert), khoá lại, dời việc thuật toán sang phase sau**
    thay vì chặn cả critical path — đây chính xác là mẫu hình của mọi mục ở §2 dưới đây.
  - Mọi biên độ slider ăn theo mặt phải tính **theo phân số face width**, không phải pixel tuyệt đối, để
    preset chuyển được giữa các ảnh khác nhau và giữa preview/export.

## 1. Đã làm (hoạt động thật, có test + số đo)

### 1.1 Engine — 4 nhóm slider render thật (tổng 45 slider), Phase 2
| Nhóm UI | Số slider | RenderGraph stage | Tài liệu |
|---|---|---|---|
| Da (skin) | 8 | `RenderStage.skin`, guided filter + high-pass | ADR-0009 |
| Mặt (face reshape) | 15 | `RenderStage.warp`, MLS mesh warp từ landmark 478 điểm | ADR-0010 |
| Mắt & Răng | 4 | `RenderStage.eyesTeeth` | ADR-0011 |
| Màu (color) | 18 (16 hai chiều −100…100, 2 một chiều 0…100) | `RenderStage.color`, node đầu tiên, chạy được cả ảnh không có mặt | ADR-0012, ADR-0016 |

Tất cả: golden PSNR ≥ 45 dB (thực đo 79–189 dB tuỳ node), bit-exact ở 0, bench trên Mac + iOS Simulator
(**chưa đo trên iPhone thật** — biết và ghi rõ, chưa chặn ship). Live preview thật chạy trên `MTKView`
(ADR-0013): kéo slider không ghi đĩa, chỉ ghi khi thả tay; chọn mặt trên canvas thu hẹp render về 1 mặt.

### 1.2 Vision pipeline (RPVision, Phase 2)
- `FaceAnalyzer`: Vision (định vị thô) → crop → BlazeFace (Core ML, ROI chuẩn) → mesh landmark 478 điểm
  (Core ML) → face parsing BiSeNet 19 lớp (Core ML) → cache theo content-hash. Sai số landmark 0.861 px
  @256 trên ảnh a6300 thật (bar < 1 px). Không có lớp "răng"/"lòng trắng mắt" riêng trong dataset — 2 slider
  liên quan phải suy từ luminance/saturation, đã ghi rõ trong ADR-0006/0011.

### 1.3 Import + Project (Phase 1)

- Import Files, Photos (giữ RAW), MTP camera (`ImageCaptureCore`, cả Mac & iPad), FolderWatcher (theo dõi
  thư mục → auto import — dùng cho card reader).
- `.rpproj` bundle format (ADR-0002): `originals/ previews/ edits/*.json presets/`.
- `EditState` (Codable JSON, non-destructive), `EditState.SectionKey` = đúng 6 namespace: `skin face
  eyesTeeth color makeup hair` — 4 đầu có node thật, 2 sau (`makeup`, `hair`) tồn tại trong model nhưng
  **không có slider/thuật toán nào** (Phase 5).
- `RPCore.Preset` struct đã tồn tại (EditState bỏ trường theo-ảnh) nhưng **chưa có UI lưu/áp preset** — đó
  là việc của Phase 3.

### 1.4 UI shell (RPUI) — 12 màn hình theo design canvas, cộng thêm hôm nay
Từ `docs/design/RetouchPro.dc.html`/`docs/design/SPEC.md` (nguồn: `claude.ai/design/p/60d411fe-...`):
- **1a/1b** — editor iPhone (canvas full-bleed + sheet công cụ dưới) / macOS (3-pane: canvas, panel phải,
  rail icon) — **hoạt động thật**, nối vào 4 nhóm slider ở §1.1.
- **2a-2d** — thư viện (grid ảnh, filter, rating sao) + sheet/dialog xuất ảnh. **UI có thật, nút Xuất bị
  disable** — chưa có renderer đứng sau (Phase 3, xem §3.2). Filter/rating là metadata thật trên
  `Shot`/`Project`, không cần vision.
- **3a-3f (mới, turn 3, 2026-09-10)** — bộ rail 19 mục thay cho rail 6 nhóm cũ, mô phỏng một app retouch
  tham chiếu (kiểu Meitu/Facetune) với nhiều tool hơn hẳn. **Đây là phần vừa làm hôm nay và là trọng tâm
  của việc plan tiếp — chi tiết đầy đủ ở §2.**
- Vừa sửa thêm hôm nay: chiều cao dòng slider trên iPhone tăng (9pt→14pt padding mỗi bên) để dễ cuộn dọc
  hơn, đỡ chạm nhầm thanh trượt ngang.

**Test hiện tại:** 517 test (RPCore 32, RPImport 73, RPVision 53, RPEngine 166, RPUI 114, package-layering 5,
app tests), xanh trên macOS + iOS Simulator; build/install/launch xác nhận trên iPhone thật (`IphoneDuy`).

## 2. TRỌNG TÂM — rail 19 mục: đã làm gì, còn thiếu gì (cần Fable 5 lên plan)

### 2.1 Đã làm hôm nay (chỉ là điều hướng UI, KHÔNG có thuật toán mới)
Rail 19 icon + 1 mục "Màu" ghim cuối (tổng 20), hiển thị đầy đủ trên cả iPhone (hàng ngang cuộn được, dưới
sheet công cụ) và macOS (cột dọc cuộn được, rail phải). Thứ tự ưu tiên theo thói quen chỉnh sửa thật của
user (Mặt → Mắt → Mịn da trước, Màu luôn là bước cuối):

```
Mặt, Mắt, Mịn da, Mẫu, Răng, Tự động, Trang điểm, Thu gọn, Cơ thể, Sửa da, Săn chắc,
Căng mọng, Mụn, Đầu, Tạo khối, Kiềm dầu, Bọng mắt, Tóc, Xoá vật thể, [Màu — ghim cuối]
```

Trong 20 mục đó, đúng **7 mục nối vào panel/slider đã hoạt động thật sẵn có** (không phải tool riêng, chỉ
là lối tắt vào 1 trong 4 nhóm ở §1.1):

| Rail item | Panel thật đang mở |
|---|---|
| Mặt | Panel Mặt (15 slider warp) |
| Mắt, Bọng mắt, Răng | **Cùng chung** panel Mắt & Răng (4 slider) — 3 lối tắt vào 1 panel |
| Mịn da, Kiềm dầu | **Cùng chung** panel Da (8 slider) — 2 lối tắt vào 1 panel |
| Màu (ghim cuối) | Panel Màu (18 slider) |

**13 mục còn lại bị khoá (dimmed 38% opacity, tap không làm gì, giống hệt cách Trang điểm/Tóc đã khoá từ
trước)**: Mẫu, Tự động, Trang điểm, Thu gọn, Cơ thể, Sửa da, Săn chắc, Căng mọng, Mụn, Đầu, Tạo khối,
Xoá vật thể, Tóc. **Không có bất kỳ code/UI nào đứng sau các icon này** — chúng chỉ là icon + label render
ra, `sectionKey == nil`, bấm vào không đổi panel.

Cũng **chưa xây** (theo đúng yêu cầu "làm UI rail trước, phần còn lại khoá lại" — những phần này thậm chí
không có UI rỗng, bỏ hẳn khỏi lần làm này):
- **Khoá nền (background lock)** — toggle pill xuất hiện trên canvas + toolbar macOS trong mockup gốc.
- **Chế độ Tự động/Thủ công + cọ mask thủ công** (brush size, brush add/erase, mask mode icon).
- **Mẫu (template gallery)** — dải thumbnail + tab "Cho bạn/Của tôi/Yêu thích".
- **Looks / AI Retouch picker** — 5 preset màu (Gốc/Tự nhiên/Normcore/Sữa/Điện ảnh) + tab.
- **Grid+subtab+1-slider micro-UI** mà mockup dùng cho từng tool con trong Mặt/Mắt/Răng (`FACE_SUB` 8 tab,
  `FACE_TOOLS` 15 tool tên riêng, `EYES_TOOLS` 10, `TEETH_TOOLS` 5 — phần lớn không khớp 1-1 với 45 slider
  hiện có, xem bảng chi tiết §2.2).

### 2.2 Chi tiết từng mục khoá — cần gì để mở khoá (input cho Fable 5 lên plan)

Với mỗi mục, ghi rõ: cái mockup mô tả, engine hiện có gì liên quan (nếu có), và việc còn thiếu.

1. **Mẫu (Templates)** — mockup: dải thumbnail preset, tab "Cho bạn/Của tôi/Yêu thích", nút "Thêm". Engine:
   `RPCore.Preset` struct đã có (EditState bỏ trường theo ảnh) nhưng chưa có UI lưu/áp/liệt kê preset —
   đúng việc của **Phase 3 "Preset"** đã ghi sẵn trong PLAN. Khuyến nghị: khi làm Phase 3, cân nhắc dùng lại
   chính UI "Mẫu"/"Looks" này thay vì thiết kế preset UI riêng.
2. **Tự động (one-tap auto retouch)** — mockup: 1 tap áp toàn bộ preset cố định. Chưa có công thức/preset
   mặc định nào được chốt. Cần: quyết định "tự động" áp cái gì (kết hợp bao nhiêu % mỗi nhóm Da/Mặt/Mắt) —
   là quyết định sản phẩm, không phải việc render mới.
3. **Trang điểm (Makeup)** — đã có sẵn trong PLAN Phase 5, chưa có slider/thuật toán. Không có gì mới.
4. **Thu gọn / Cơ thể / Săn chắc / Căng mọng** — 4 mục này đều là nhánh của **body reshape** (đã có trong
   PLAN Phase 6 "body reshape" nhưng chỉ 1 dòng, chưa breakdown). Cần: body pose/segmentation trước (PLAN
   §1.2 đã ghi "Body pose: để sau" — chưa có giải pháp on-device nào được chọn), rồi mới quyết được warp
   toàn thân theo kiểu gì (MLS như mặt, hay khác).
5. **Sửa da (Skin-fix)** — tên mơ hồ trong chính mockup, chưa rõ nghĩa cụ thể khác gì với 8 slider Da hiện
   có. **Cần hỏi lại ý nghĩa** (không suy đoán) trước khi lên plan cho mục này.
6. **Mụn (Acne removal)** — đã có trong PLAN Phase 5 ("xoá mụn auto + brush heal/clone"), đánh giá khả thi
   "⚠️ trung bình" ở PLAN §1.3: DoG blob detect → PatchMatch heal; ảnh lớn dùng LaMa Core ML (~200 MB,
   ~2 s/ảnh). Không phải việc mới, chỉ chưa tới lượt.
7. **Đầu (Head reshape)** — khác face warp vì đổi cả khung đầu/tóc, không chỉ landmark mặt. Chưa có trong
   PLAN trước đây, mới thêm vào Phase 6 hôm nay. Cần nghiên cứu riêng (không dùng chung mesh 478 điểm của
   `FaceReshape`).
8. **Tạo khối (Contour)** — tô sáng/tối theo khối mặt (gò má, sống mũi…) theo landmark, gần với ý tưởng
   "Auto D&B" của nhóm Màu (ADR-0012) nhưng phải khoanh vùng theo mesh thay vì toàn khung ảnh. Có thể tái
   dùng landmark 478 điểm đã có, việc mới là khoanh vùng + curve cục bộ.
9. **Xoá vật thể (Object removal)** — mở rộng phạm vi của "LaMa inpaint" đã có trong PLAN Phase 6 (vốn ghi
   cho "tóc con bay") sang xoá vật thể tự do theo vùng người dùng chọn (brush select). Cần thêm UI chọn
   vùng (khác brush mask ở mục 10) + kiểm chứng LaMa trên vùng lớn/tuỳ ý thay vì vùng tóc nhỏ.
10. **Chế độ Thủ công + cọ mask (manual paint mask)** — hạ tầng dùng chung: vẽ/xoá một mask cục bộ (brush
    add/subtract, brush size, 3 mask mode "Cổ điển/Nhanh/Phục hồi" trong mockup) rồi mới áp slider chỉ trong
    vùng đó. **Đây là tiền đề bắt buộc phải làm trước** bất kỳ tool "Thủ công" nào ở trên — không tool nào
    trong 13 mục khoá có thể chạy chế độ thủ công nếu thiếu cái này.
11. **Khoá nền (Background lock)** — cần segmentation chủ thể (person/subject mask) để chặn hiệu ứng không
    lan ra nền. Có liên quan tới "background clean" đã có trong PLAN Phase 6 — làm lock trước, blur/clean
    sau, tự nhiên hơn vì lock là bài toán nhẹ hơn (chỉ cần mask, không cần inpaint/blur chất lượng cao).
12. **Looks / AI Retouch picker** — về bản chất là mở rộng preset system (giống Mẫu, mục 1) nhưng đóng gói
    thành "look" toàn bộ ảnh (màu + có thể cả da). "Cho bạn" (for-you personalization) ngụ ý cá nhân hoá —
    **cần quyết định rõ: có AI cá nhân hoá thật hay chỉ là 1 danh sách preset tĩnh** trước khi lên plan kỹ
    thuật, khác nhau rất nhiều về effort.
13. **Grid+subtab+1-slider micro-UI** (không phải rail item, mà là *cách tương tác* bên trong Mặt/Mắt/Răng
    mà mockup vẽ) — 8 subtab (Biểu cảm/3D Reshape/Tỷ lệ/Khuôn mặt/Chân mày/Mắt/Mũi/Môi) + 15 tool tên riêng
    cho Mặt (HD Portrait, Độ rộng, Nâng, Làm mượt, Ngấn cổ, Ngấn Pro, Cằm V, Mặt V, Góc hàm, Đường hàm,
    Đường chân tóc — **đa số không khớp 1-1 với 15 `FaceSliders.Key` hiện có**), 10 tool riêng cho Mắt, 5
    cho Răng. Hiện tại UI vẫn dùng list phẳng cũ (`GroupSliderList`, tất cả slider hiện cùng lúc), không
    phải grid+subtab+1-slider-mỗi-lần của mockup. **Đây là quyết định UX lớn**: có đáng đổi từ "list phẳng,
    thấy hết slider" sang "chọn tool → 1 slider cường độ" không, và nếu có thì tên tool nào map vào slider
    nào, tool nào cần thuật toán hoàn toàn mới.

### 2.3 Nguồn tham khảo cho Fable 5

- `docs/design/SPEC.md` §"Turn 3 — expanded toolset rail" — spec đầy đủ, bảng wiring, chính sách khoá.
- `docs/design/RetouchPro.dc.html` — markup gốc (màn 3a-3f), có toàn bộ code JS định nghĩa `RAIL`,
  `FACE_SUB`, `FACE_TOOLS`, `EYES_TOOLS`, `TEETH_TOOLS`, `GROUPS` — đọc trực tiếp nếu cần tên/icon chính xác.
- `docs/PLAN.md` — mục "Cập nhật design (2026-09-10), Turn 3 canvas" trong Phase 2, và bổ sung ở Phase 6.
- `Packages/RPUI/Sources/RPUI/Model/RailLayout.swift` — implementation thật của bảng wiring (đọc để biết
  chính xác `sectionKey` nào đang trỏ đi đâu, phòng khi tài liệu lệch code).

## 3. Các phase còn lại khác (không thuộc turn 3, nhưng cũng "chưa làm" — nhắc lại cho đủ)

### 3.1 Phase 2 (đang dở, phần còn lại ngoài 4 nhóm slider)

Không có mục nào treo — Phase 2 coi như xong phần render core, chỉ còn việc UX của turn 3 (§2).

### 3.2 Phase 3 — Preset, Batch, Export (chưa bắt đầu)

- UI export đã có (2b/2d), nút bị disable — chưa có renderer viết file thật.
- Lý do treo: Da + Mắt/Răng cùng bật ở export 24 MP ước tính ~936 MB scratch GPU, **chưa đo trên iPhone
  thật** (ADR-0011) — phải đo trước khi bật export mặc định cả 2 nhóm cùng lúc.
- Batch queue (nền, GPU-memory-aware, thermal-aware trên iPhone): chưa có dòng code nào.
- Preset lưu/áp cho ảnh chọn/cả project, auto-apply ảnh mới: chưa có UI (model `Preset` đã có).
- Mặc định export jpg/jpeg, quality cho chỉnh 80-100%

### 3.3 Phase 4 — Tethered import (chưa bắt đầu, có spike go/no-go riêng)

- macOS: cần tự viết `IOUSBHost` + Sony PTP/SDIO extension handshake — khả thi nhưng chưa làm.
- iPad A-series: **không khả thi native** (đã kết luận, xem PLAN §1.1) — Wi-Fi hoặc Mac-làm-cầu là lối
  duy nhất, và cả hai đều pending vì user tạm gác iPad (xem `feedback-dont-reask-settled-decisions` /
  `project-retouchpro-app-decisions` trong memory — không cần hỏi lại quyết định này).

### 3.4 Phase 5 — Makeup, Heal, Hair v1 (chưa bắt đầu)
Makeup sliders, xoá mụn auto + brush heal/clone (= mục 6 ở §2.2), tóc (bóng/tối-sáng/màu).

### 3.5 Phase 6 — Nâng cao (chưa bắt đầu, danh sách vừa được bổ sung hôm nay)

Tóc con bay (LaMa), body reshape, background clean, Canon/Nikon trong PTPStack, iCloud sync — cộng thêm
toàn bộ 8 mục turn-3 mới liệt kê ở §2.2 (mục 4, 7, 8, 9, 10, 11 và một phần mục 1/12).

## 4. Yêu cầu mới bổ sung (chưa hề có trong PLAN.md trước đây)

### 4.1 "Mở với RetouchPro" từ app Photos trên mobile

**Yêu cầu (user, 2026-09-10):** cho phép người dùng chọn 1 ảnh trong app **Photos** trên iPhone/iPad, dùng
Share Sheet chọn **"Mở với RetouchPro"** để vào thẳng **trang chỉnh sửa (editor)** với ảnh đó — không phải
mở app rồi tự bấm Nhập → chọn Photos như hiện tại. **Mục đích rõ ràng: gộp "mở app + import" thành đúng 1
thao tác.** Project chứa ảnh đó **tự động tạo**, không hỏi lại người dùng chọn project.

**Quyết định kỹ thuật (user, 2026-09-10): dùng Share Extension, không dùng Photo Editing Extension.** Lý do
đã chốt — mục tiêu là tiết kiệm thao tác (1 bước), không phải sửa ảnh ngay trong Photos; Share Extension đơn
giản hơn nhiều và đúng mục tiêu này (Photo Editing Extension để sau, không cần bàn tới trong lần plan này).

**Hiện trạng liên quan:** `RPImport.PhotosImporter`/`PhotoKitLibrarySource` (Packages/RPImport) đã đọc được
ảnh từ thư viện Photos **khi người dùng chủ động mở app rồi bấm Nhập** — cơ chế lấy ảnh (PhotoKit, giữ RAW)
đã có sẵn và tái dùng được. Cái thiếu là **điểm vào ngược lại**: từ Photos/Share Sheet gọi vào RetouchPro.

**Luồng đích (UX đã chốt):** Photos → chọn ảnh → Share Sheet → "RetouchPro" → app mở thẳng ra **editor**
với ảnh đó đã nằm trong canvas, sẵn sàng chỉnh ngay — không có màn hình trung gian nào (không hỏi chọn
project, không quay về thư viện trước).

**Việc kỹ thuật cần Fable 5 lên plan (đây là hạng mục mới, không nằm trong Phase 1-6 hiện tại):**
1. Thêm **Share Extension target** mới vào `RetouchPro.xcodeproj` (`NSExtensionActivationRule` lọc theo
   ảnh — `NSExtensionActivationSupportsImageWithMaxCount`), nhận `NSExtensionItem` chứa ảnh, rồi mở app
   chính qua URL scheme (ví dụ `retouchpro://open?...`) hoặc `NSUserActivity` kèm định danh ảnh/asset.
2. **App Group** (`group.com.duynguyen.RetouchPro...`) để extension process và app chính chia sẻ được dữ
   liệu ảnh — cả `App/RetouchPro.entitlements` lẫn `App/RetouchPro-macOS.entitlements` hiện **chưa có App
   Group nào** (đã kiểm tra), cần thêm mới.
3. Luồng nhận ảnh trong app chính khi được mở từ extension: ảnh vừa nhận đi qua đúng `ShotIngestor`/
   `.rpproj` như luồng import thường (không tạo đường ingest riêng) — **tự động tạo 1 project mới** cho ảnh
   đó (đã chốt, không hỏi user chọn project). Cần chốt thêm khi Fable 5 lên plan: tên project tự tạo đặt
   theo mẫu gì (ví dụ "Ảnh từ Photos <ngày>", theo đúng format project đang dùng trong `RPCore.Project`).
   Sau khi ingest xong, app phải **điều hướng thẳng tới `EditorView` với ảnh đó đã chọn** (không dừng lại ở
   `ProjectsView`/thư viện) — đây là phần UI/routing mới, cần xem lại `RetouchProRootView`/`EditorModel` để
   biết cách mở thẳng vào 1 shot cụ thể khi app khởi động từ cold-start lẫn khi app đã đang chạy nền.
4. **Đây là app chạy Development signing, không lên App Store** (đã chốt từ đầu dự án, xem §0) — Share
   Extension **vẫn hoạt động bình thường** với Development signing + provisioning profile local, không cần
   App Store; chỉ cần app + extension cùng ký chung 1 team/App Group. Không phát sinh vấn đề phân phối.
5. Không có việc "measure before ship" nào ở đây (không phải thuật toán mask/landmark) — đây thuần là hạng
   mục kiến trúc/kết nối hệ thống (Xcode target + entitlement + URL handoff + routing), effort chủ yếu nằm
   ở việc dựng đúng project structure và test được extension (`xcodebuild` test cho extension target cần
   cấu hình riêng, Fable 5 nên tra cứu cách chạy UI test cho Share Extension trên Simulator/thiết bị thật —
   phần "mở thẳng vào editor, cold-start lẫn app đang chạy nền" nên có test/kiểm chứng riêng cho cả 2 case).

**Đề xuất vị trí trong roadmap:** gần với Phase 1 (Import) về mặt chức năng, nhưng Phase 1 đã xong từ lâu —
nên coi đây là **phase/mục mới độc lập**, có thể chèn song song với Phase 3 (không phụ thuộc render/export)
hoặc làm sớm hơn nếu user muốn ưu tiên (import nhanh hơn workflow, không đụng gì tới RenderGraph/Vision).

## 5. Việc cụ thể nhờ Fable 5

1. Với **13 mục rail bị khoá** ở §2.2 — viết plan chi tiết theo đúng format `docs/PLAN.md` đang dùng (mỗi
   phase: mục tiêu, thuật toán candidate + đánh giá khả thi, thứ tự phụ thuộc giữa các mục — ví dụ mục 10
   "cọ mask" phải xong trước mọi tool thủ công khác).
2. Xác nhận/điều chỉnh việc gộp vào Phase 6 hiện tại có hợp lý không, hay một số mục (ví dụ Mụn — đã ở
   Phase 5) nên tách phase riêng vì độ ưu tiên khác nhau.
3. Với mục 5 ("Sửa da") và mục 12 ("Looks — AI cá nhân hoá thật hay preset tĩnh") — nêu rõ đây là câu hỏi
   cần user quyết trước khi lên plan kỹ thuật, đừng tự suy đoán rồi lên plan sai hướng.
4. Ước lượng effort/tuần theo đúng style PLAN.md hiện tại (Phase 0-3: ~8 tuần, Phase 4: +3 tuần) cho từng
   mục mới, để chèn được vào timeline tổng.
5. Với §4.1 ("Mở với RetouchPro" từ Photos) — hướng kỹ thuật (Share Extension) và UX đích (vào thẳng editor,
   tự động tạo project) **đã chốt**, không cần hỏi lại; việc còn mở là mẫu đặt tên project tự động (§4.1
   mục 3) — nếu cần quyết định gì thêm về hiển thị tên, hỏi cụ thể đúng điểm đó, đừng hỏi lại toàn bộ hướng.
