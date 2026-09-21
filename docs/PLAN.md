# Retouch Pro App — Plan macOS + iOS (slider retouch, preset, batch; tethering ở phase sau)

## Context

Hôm qua (03/09/2026) đã xong **Retouch Pro panel UXP cho Photoshop** tại
`/Users/duynguyen/Documents/Claude/Projects/panelpts`. Hôm nay làm **app độc lập** cho macOS + iPhone,
cùng loại Evoto / Xingtu / Meitu:

- Import ảnh từ Files, Photos, thẻ nhớ / máy ảnh cắm USB; sau đó **tethered import** (bấm chụp trên máy → ảnh tự vào app).
- **Project** cho mỗi buổi chụp. Chỉnh tấm đầu → lưu **preset** → các tấm sau tự áp.
- Chỉnh bằng **thanh trượt** (mịn da, mượt tóc, bóp mặt, mắt to, trắng răng…), không phải nút 1‑click.
- **Batch edit** + export hàng loạt.

Đã chốt với user (không hỏi lại):
- **UI theo chuẩn Evoto**: filmstrip trái, canvas giữa, panel slider phải, thanh preset trên.
- **Swift/SwiftUI native**, một codebase macOS + iOS (iPhone) — **iPadOS đã bị loại bỏ khỏi phạm vi triển khai**
  (2026-09-11, xem §0.2). Không Flutter.
- **AI on-device only**, không server.
- Máy ảnh **Sony a6300** (micro‑USB).
- App **chạy local, không lên App Store** → không cần entitlement phân phối, không cần App Review.
- **Tethering là thách thức kỹ thuật → đẩy xuống Phase 4**, làm xong editor + preset + batch trước. Lý do ở §1.1.

Thư mục dự án: `/Users/duynguyen/Documents/Claude/Projects/retouchProApp` (trống). Môi trường: macOS 26.3, Xcode 26.2.

---

## 0.1 Cập nhật phạm vi (2026-09-04) — iPad tạm pending

User quyết định: **các feature/kiểm chứng liên quan tới iPad tạm thời pending, chỉ tập trung macOS + iOS (iPhone)**
giai đoạn này. Đã dọn khỏi §3 (Phases) và §5 (Verification): tiêu chí hiệu năng "trên iPad A-series" đổi thành
"trên iPhone"; spike S5 (MTP import qua adapter trên iPad) và Phase 4's iPad Wi-Fi spike (T2) / Mac-làm-cầu-cho-iPad
đã bỏ khỏi kế hoạch hiện hành. §1 (feasibility research gốc) và §4 (user prep) giữ nguyên làm tài liệu lịch sử —
không phải nội dung phase đang thực thi.

App vẫn multiplatform (không xoá target iPadOS khỏi Xcode project) — chỉ là không còn build/test/đo hiệu năng trên
iPad trong giai đoạn này. Khi user báo tiếp tục iPad, thêm lại các tiêu chí/spike này và đổi destination test về
iPad (A16) hoặc thiết bị thật.

## 0.2 Cập nhật phạm vi (2026-09-11) — loại bỏ hẳn iPadOS

**Ghi đè §0.1**: không còn là "tạm pending" nữa — user quyết định **loại bỏ hẳn việc triển khai trên iPadOS**
khỏi dự án. Khác §0.1 (chỉ dừng build/test, giữ nguyên target trong Xcode để bật lại dễ), lần này đã sửa trực
tiếp cấu hình Xcode:
- `RetouchPro.xcodeproj/project.pbxproj`: `TARGETED_DEVICE_FAMILY` đổi từ `"1,2"` (iPhone+iPad) thành `1`
  (chỉ iPhone) ở cả 2 target (`RetouchPro`, `RetouchProAppTests`) × 2 config (Debug/Release); xoá
  `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` (không còn ý nghĩa khi device family không có iPad).
  Đã xác nhận `xcodebuild -list` vẫn parse project bình thường sau khi sửa.
- `Package.swift` của các package con **không cần sửa** — SPM không phân biệt iPadOS/iPhone, chỉ khai
  `.iOS(.v18)` chung; giới hạn iPad nằm hoàn toàn ở build setting của app target.
- Toàn bộ comment trong code nhắc riêng "iPadOS"/"A-series iPad" (RPEngine, RPImport, App target, bench test
  labels) đã đổi thành "iOS"/"iPhone" cho khớp — không có nhánh code nào thật sự rẽ theo iPad riêng (mọi API
  dùng đều annotate chung `ios(...)`, không có `#if targetEnvironment(...)` nào phân biệt iPhone/iPad), nên đây
  thuần là sửa chữ, không phải sửa logic.
- **Target hiệu năng thấp nhất đổi từ "iPad A-series" sang "iPhone"** — không có tier iPad nữa. Số đo hiệu năng
  đã ghi trong các ADR trước đây (30 fps preview, export 5-8s...) giữ nguyên làm bar, chỉ đổi phần cứng tham
  chiếu; không cam kết một model iPhone cụ thể, giữ nguyên cách dự án đang làm ("máy nào có sẵn" — hiện là
  "IphoneDuy").
- `.claude/agents/coder.md`/`reviewer.md` đã cập nhật theo (không còn nhắc iPadOS/A-series iPad).
- Các phần lịch sử thuần tuý (§1 feasibility research gốc, §4 user prep, §6 Nguồn) **giữ nguyên không sửa**,
  đúng quy ước đã có ở §0.1 — chúng ghi lại nghiên cứu/chuẩn bị của thời điểm còn tính iPad vào scope, không
  phải nội dung đang thực thi. Đọc chúng với hiểu biết rằng iPad không còn trong phạm vi.

---

## 1. Đánh giá tính khả thi

### 1.1 Tethering (bấm chụp trên máy → ảnh tự vào app) — kết luận và lý do dời phase

| Platform | Đường kỹ thuật | Khả thi |
|---|---|---|
| **macOS** | `IOUSBHost` (macOS 10.15+) mở a6300 ở chế độ PC Remote → tự viết PTP + **Sony SDIO extension** (handshake `0x9201/0x9202/0x9209`, event `0xC201`, handle `0xFFFFC001`, theo libgphoto2) → `GetObject` JPEG/ARW. Fallback `ImageCaptureCore.requestSendPTPCommand`. | ✅ Khả thi, không cần entitlement vì chạy local. Rủi ro: a6300 có timeout/kém ổn định (gphoto bug #1038); phải xác minh bấm chụp trên body có phát event. |
| **iPad A‑series / iPhone qua cáp** | `IOUSBHost` **không có trên iPadOS**. `USBDriverKit` chỉ chạy **iPad M‑series**. `ImageCaptureCore` trên iOS **chặn vendor PTP** (`ICReturnPTPNotAuthorizedToSendCommand`), mà Sony bắt buộc vendor handshake (chế độ MTP thì máy không cho chụp). | ❌ **Không làm được native** với iPad hiện tại. |
| **iPad / iPhone qua Wi‑Fi** | Sony Camera Remote API (app Smart Remote Embedded có sẵn trong a6300; PlayMemories đóng 08/2025 nhưng app trong máy vẫn chạy) qua thư viện **Rocc** (Swift, MIT); hoặc PTP/IP port 15740. | ⚠️ Khả thi, cần xác minh trên máy: bấm chụp body có đẩy ảnh, tải được **file gốc** hay chỉ 2 MP. |
| **iPad qua Mac làm cầu** | Mac tether USB → thư mục project chia sẻ (LAN / iCloud Drive) → iPad tự nhận ảnh mới. | ✅ Đơn giản, tận dụng đường Mac. |
| **CascableCore** (SDK thương mại, binary, license key, giá liên hệ) | a6300 hỗ trợ USB + Wi‑Fi trên iOS. | Dự phòng nếu muốn cáp trực tiếp vào iPad A‑series. |

→ Tethering không có đường "chuẩn hoá" nhanh cho iPad A‑series, và Mac cần viết PTP stack riêng. **Dời sang Phase 4**, sau khi workflow import thủ công + preset + batch đã chạy. Trong lúc đó, **import từ máy ảnh cắm USB ở chế độ MTP** (không vendor command, ImageCaptureCore hỗ trợ cả Mac và iPad) và **đọc thẻ nhớ qua card reader** đáp ứng được workflow "chụp một loạt → cắm → đổ vào project → auto preset".

### 1.2 Phân tích khuôn mặt / phân vùng

| Nhu cầu | Giải pháp on-device | Khả thi |
|---|---|---|
| Phát hiện mặt | Apple Vision `DetectFaceRectanglesRequest` | ✅ |
| Landmark dày cho reshape | Vision 76 điểm không đủ → **MediaPipe Face Landmarker 478 điểm** convert TFLite → **Core ML** (MediaPipe Tasks không hỗ trợ macOS) | ✅ cần tự convert + kiểm chứng |
| Face parsing 19 lớp (da, tóc, mắt, lông mày, môi, răng, cổ) | **BiSeNet CelebAMask‑HQ → Core ML** | ✅ |
| Mask da toàn thân | **Port `skincore.js` → `SkinCore.swift`/Metal** + Vision person segmentation | ✅ tái sử dụng trực tiếp |
| Body pose | Vision body pose | để sau |

### 1.3 Thuật toán slider

| Slider | Thuật toán | Khả thi |
|---|---|---|
| Mịn da giữ texture | Guided filter + high-pass giữ lỗ chân lông × skin mask | ✅ |
| Đều màu da, khử đỏ, khử bóng dầu, Auto D&B | Port từ `commands.js` sang Metal | ✅ |
| Bóp mặt, gò má, cằm, mũi, mắt to, miệng, môi | Mesh warp **Moving Least Squares** từ 478 landmark; slider = delta tương đối theo face width → chuyển sang ảnh khác được | ✅ |
| Sáng mắt, trắng răng | mask parsing + curve cục bộ | ✅ |
| Xoá mụn tự động | DoG blob → PatchMatch heal; LaMa Core ML cho vùng lớn (~200 MB, ~2 s) | ⚠️ trung bình |
| Mượt tóc / tóc con bay | detect sợi + inpaint; detect khó | ⚠️ sau |
| Lấp chân tóc, thêm tóc | generative | ❌ bỏ |
| Makeup | mask + blend, tái dùng bảng màu panel | ✅ |
| Color (exposure, WB, curves, HSL, LUT) | Core Image + kernel | ✅ |
| Background blur / clean | segmentation + blur/inpaint | ⚠️ sau |

### 1.4 Hiệu năng & RAW
- a6300 24 MP ARW: `CIRAWFilter` decode được. Preview 2048 px, export full-res, RGBA16Float.
- **iPad A‑series** là target hiệu năng thấp nhất: preview phải đạt ≥ 30 fps ở 1536–2048 px; export 24 MP chấp nhận 5–8 s; landmark/parsing chạy 1 lần/ảnh, cache theo hash; Core ML model chọn bản nhỏ (parsing 512 px).

---

## 2. Kiến trúc

```
retouchProApp/
  RetouchPro.xcodeproj        1 app target multiplatform (macOS 15+, iOS 18+ — iPhone only), ký Development, chạy local
  App/                        entry, DI, scenes
  Packages/
    RPCore/     Project, Shot, EditState (Codable JSON), Preset, ProjectStore (.rpproj bundle)
    RPVision/   FaceAnalyzer: Vision → CoreML 478 landmarks → CoreML face parsing → SkinCore → FaceAnalysis cache
    RPEngine/   RenderGraph Metal+Core Image: Decode → Color → Skin → Warp(MLS) → Eyes/Teeth → Makeup → Output;
                PreviewRenderer, ExportRenderer, BatchQueue
    RPImport/   FilesImporter, PhotosImporter, MTPCameraImporter (ImageCaptureCore: liệt kê + tải file, cả Mac & iPhone),
                FolderWatcher (theo dõi thư mục → auto import; dùng cho card reader và cho Mac‑làm‑cầu)
    RPUI/       SwiftUI: ProjectsView, EditorView (Filmstrip / Canvas / SliderPanel / PresetBar), BatchExportView, PresetManager
    RPTestKit/  golden images, eval harness mask/landmark, bench
    -- Phase 4 --
    PTPStack/   pure Swift: PTP framing, session, GetObject, event loop, SonyExtension (sau: Canon/Nikon)
    RPCamera/   IOUSBHostTransport (macOS), SonyWiFiTransport (Rocc), CaptureView
  Research/     spikes, ảnh test, ground truth, bench (tiếp nối research/ của panelpts)
  docs/         ADR, spec preset JSON, danh sách slider
```

Nguyên tắc:
- **EditState** JSON thuần; **Preset** = EditState bỏ trường theo ảnh. Reshape lưu delta tương đối theo face width, skin/makeup theo mask → áp sang ảnh khác không cần chỉnh lại.
- Render **non-destructive**, originals bất biến.
- Quy tắc "measure before ship" của user (từ panelpts): thuật toán mask/landmark có flag + harness đo, có control, đọc file chẩn đoán không đoán từ screenshot.
- Tái sử dụng `panelpts/RetouchProUXP`: `skincore.js` → `SkinCore.swift` (đối chứng bit-exact bằng `research/eval.js`), logic `commands.js` → Metal kernel.

---

## 3. Phases

### Phase 0 — Spike kỹ thuật cho engine (1 tuần)

| Spike | Pass |
|---|---|
| S1 Landmark 478 → Core ML | sai số < 1 px @256 so MediaPipe Python; < 40 ms/face trên iPhone |
| S2 Face parsing BiSeNet → Core ML | IoU skin/hair/eye ≥ 0.85 trên 10 ảnh; < 150 ms trên iPhone |
| S3 Guided filter + MLS warp Metal trên 24 MP | preview 2048 px ≥ 30 fps khi kéo slider trên iPhone; export < 8 s |
| S4 `CIRAWFilter` ARW a6300 | decode < 3 s trên iPhone, 16‑bit |

Kết quả: `Research/spikes/REPORT.md`, chọn model/độ phân giải theo số đo thật.

### Phase 1 — Skeleton + Import + Project (2 tuần)

- Xcode project multiplatform + packages, `xcodebuild test` macOS và iOS Simulator.
- `.rpproj` bundle (originals/, previews/, edits/*.json, presets/).
- Import: Files, Photos (giữ RAW), drag-drop Mac, **MTP camera import** (ImageCaptureCore), **FolderWatcher** (chọn thư mục/card → ảnh mới tự vào project).
- UI khung Evoto: filmstrip (rating/flag), canvas zoom/pan, before/after, panel slider trống.

**Cập nhật (2026-09-21) — xoá ảnh khỏi project và xoá cả project, hai thao tác Phase 1 chưa từng có UI.**
User phát hiện lúc dùng thật: lỡ import sai ảnh thì không có cách nào gỡ ra khỏi project (chỉ có filmstrip để
xem, không có menu xoá), và không có cách nào xoá hẳn một project — đáng lo hơn vì mỗi ảnh import là **bản
sao đầy đủ** (`ProjectStore.addShot(copyingOriginalAt:)` copy file, không phải reference), nên không xoá được
project = không có cách nào lấy lại dung lượng trên iPhone. Đã ship cả hai, UI-only + 1 API mới trong RPCore:
- **Xoá ảnh khỏi project**: menu "Xoá ảnh khỏi dự án…" (destructive) trên mỗi ảnh trong filmstrip (Mac) và
  `PhoneLibraryView` (iOS, không có filmstrip), có alert xác nhận nói rõ "Tệp gốc vẫn được giữ trong dự án,
  không bị xoá khỏi máy" — dùng lại nguyên `ProjectStore.removeShot` đã có sẵn từ trước (cố ý không xoá file
  gốc trong `originals/`, chỉ xoá bản ghi + edit state, xem doc comment tại chỗ khai báo), chỉ thêm UI gọi vào.
- **Xoá cả project**: menu chuột phải/nhấn giữ trên card project ở màn Thư viện (`ProjectsView`), có
  confirmation dialog nói rõ đây là xoá **mọi bản sao ảnh gốc đã import**, không phải file user chọn ban đầu.
  API mới: `ProjectStore.deleteBundle()` (xoá nguyên thư mục `.rpproj`, ngoại lệ duy nhất của quy tắc "không
  bao giờ đụng `originals/`" vì đây là xoá cả bundle, không có gì dở dang để giữ lại) và
  `ProjectLibrary.deleteProject(at:)`/`ProjectsModel.deleteProject(_:)` gọi xuống nó.
- Không đổi `EditState`/format đĩa nào khác, không phải render mới — hai việc này đều là CRUD trên
  `ProjectStore`, không đụng RenderGraph/Vision. 12 test mới (`ProjectDeleteTests`, `ProjectDeletionTests`,
  5 test trong `EditorModelTests` cho remove-shot).

### Phase 2 — Vision pipeline + Slider cốt lõi (3 tuần)

- **Từ S1 (đo trên ảnh a6300 thật):** landmark model tự nó đạt 0.193 px @256 (< 1px, dư 5×), nhưng pipeline
  full (Vision face detector → crop → landmark) rớt xuống 1.399 px vì ROI của Vision lệch box/xoay so với
  BlazeFace nhiều hơn trên ảnh chân dung thật (đủ mọi góc nghiêng) so với ảnh Wikimedia thẳng mặt dùng để
  calibrate ban đầu — chi tiết `Research/spikes/S1-landmark/S1-landmark.md` §4a, `docs/ADR-0005`. **Bắt buộc**:
  convert thêm `blaze_face_short_range.tflite` (cùng script `convert_tflite_to_coreml.py`), dùng 2 giai đoạn
  (Vision định vị mặt thô → crop quanh mặt → BlazeFace ra ROI chuẩn → landmark mesh) thay vì đưa thẳng box của
  Vision vào landmark model.
- **Từ S2 (face parsing, đo trên CelebAMask-HQ + ảnh a6300 thật):** IoU da 0.94, tóc 0.94 — pass. IoU mắt 0.84,
  hụt 0.01 so bar 0.85, xác nhận là giới hạn cố hữu của model gốc (không phải lỗi convert — bản PyTorch gốc cũng
  chỉ 0.8401) trên vật thể nhỏ (mắt trung bình 1365px/262144px). Quyết định: chấp nhận, dùng feathered mask cho
  slider mắt (sáng mắt, trắng lòng trắng) thay vì mask cứng. Dataset **không có lớp răng riêng** (`mouth` = khoang
  miệng) → slider trắng răng phải suy ra từ **độ sáng (luminance)** trong vùng `mouth`, không dùng mask parsing.
  Chi tiết `Research/spikes/S2-face-parsing/S2-face-parsing.md`, `docs/ADR-0006`.
- **Từ S3 (guided filter + MLS warp Metal, đo trên ảnh a6300 thật):** cả hai kernel đúng so với reference
  (guided filter lệch 2.1e-6 so bản CPU `Double`; MLS GPU lệch tối đa **1.11e-3 px** (preview 2048px/grid 65) / **3.34e-3 px** (export 24MP/grid 129) so CPU
  `Double`, đo trên 84-handle reshape thật, 11 ảnh a6300 (`Research/spikes/S3-guided-filter-mls/results/mls_gpu_vs_cpu.json`)). Trên M1 Pro: preview 2048 px
  guided(s=4) + warp(grid 65) = **1.84 ms → 545 fps**; export 24 MP GPU 16.4 ms, cả vòng (decode+upload+readback)
  ~187 ms. iOS Simulator: 4.11 ms preview, 17.4 ms export — **chưa đo trên iPhone thật**, giống S1/S2.
  Ràng buộc bắt buộc cho Phase 2: dùng **fast guided filter s=4** (bản exact tốn **2.3 GB** buffer trung gian ở
  24 MP → không chạy được trên iPhone), **mesh grid 65 cho preview / 129 cho export** (grid 33 rớt 45 dB ở ảnh xấu
  nhất), **lọc da trên sRGB đã gamma chứ không phải linear** (cùng ε, linear làm mịn vùng tối mạnh hơn 2.6×),
  luôn có **border anchor** cho warp, và **precompile shader** (đang compile lúc chạy, 1.8 s cold trên Simulator —
  Xcode 26 cần component Metal Toolchain tải riêng). Chi tiết
  `Research/spikes/S3-guided-filter-mls/S3-guided-filter-mls.md`, `docs/ADR-0007`.
- **Đã làm (2026-09-05), `FaceAnalyzer` 2 giai đoạn:** convert xong
  `blaze_face_short_range.tflite` → Core ML bằng chính script/pattern của S1
  (`Research/spikes/S1-landmark/convert_blazeface_to_coreml.py`; fp32 lệch **2.3e-5 px**
  so TFLite ở box top-1 @128 → conversion đúng; fp16 lệch 0.14 px nhưng end-to-end chỉ
  tốn thêm **0.001–0.002 px**, nên ship fp16). Pipeline
  Vision (box thô) → crop 3.5× quanh mặt → BlazeFace (ROI chuẩn + 2 keypoint mắt) →
  mesh 478 điểm hạ sai số từ **1.399 px xuống 0.866 px** trên 11 ảnh a6300 thật và
  0.911 → 0.858 px trên 20 ảnh stock (gộp theo số điểm: 1.084 → **0.861 px**, 14 818 điểm)
  — **đạt bar &lt; 1 px trên ảnh thật của user**. Control là chính bản chạy đã lưu của S1,
  chấm lại bằng cùng một hàm. Hệ số crop giai đoạn 2 được quét 6 giá trị × 2 tập ảnh,
  cực tiểu gộp ở **3.5** (3.0 xếp nhì 0.875 px, 1.5 tệ nhất 0.990 px). ROI cho mesh dùng
  **1.5 của MediaPipe**, *không* dùng `FaceCrop.visionBoxScale` = 1.40 (1.40 là hiệu chỉnh
  cho box của Apple, dùng cho box BlazeFace là trừ hai lần). Crop parsing lấy từ box
  BlazeFace, khung CelebA (1.87× × 0.544) và **xoay chuẩn theo roll của ROI** →
  parts-present **11/11 ảnh a6300** (S2 tốt nhất 10/11), 19/20 ảnh stock. Số liệu:
  `Research/phase2/face-analyzer/results/summary.json`, `docs/ADR-0008`.
  Trên Mac M-series (2691 px, `.all`): Vision 15.2 ms + BlazeFace 7.6 ms + mesh 4.2 ms +
  parsing 9.2 ms = **36.4 ms/ảnh**; cache hash: cold 46.7 ms → warm **0.052 ms** (896×),
  3 request song song cùng key chỉ chạy 1 lần (`Research/bench/p2-face-analyzer-*.json`).
  **Chưa đo trên iPhone thật** — giống S1/S2. Ghi chú: `DetectFaceRectanglesRequest`
  của Apple **không chạy được trên iOS 26 Simulator** (`Vision Code=9`), nên có
  `FaceAnalyzer.analyze(_:visionBoxes:)` để caller (và test iOS) tự cấp box giai đoạn 1.
- `FaceAnalyzer` → `FaceAnalysis` (landmarks 478, mask skin/hair/eyes/lips/brows/mouth/neck),
  cache theo hash — **xong**, sau flag mặc định tắt `RPVisionFeatureFlags.faceAnalyzer`
  (+ `blazeFaceShortRange`). Cache key = `Shot.contentHash` (RPImport đã tính sẵn) +
  vân tay options; LRU 24 entry trong `actor`, request trùng key chạy chung 1 `Task`.
  `FaceAnalysis` **không có mask "răng"** (CelebAMask-HQ không có lớp răng): chỉ có
  `ParsedFace.mouthInterior()`, slider trắng răng phải suy từ luminance trong đó.
  Mask quanh mắt/môi/lông mày bắt buộc dùng `ParsedFace.feathered(_:)`
  (`FaceParsingGroup.requiresFeatheredMask`), không dùng mask cứng — IoU mắt 0.84 là
  sai số biên ±1 px (S2 §4). Feather 512² tốn 4.1 ms trên CPU → RPEngine nên làm trên GPU
  khi nối slider mắt.
- **Đã làm (2026-09-05), `RenderGraph` + nhóm slider "Da":** đưa 2 kernel của S3 lên
  API sản phẩm trong RPEngine. `RenderNode` (`name`/`stage`/`isActive`/`prewarm`/`encode`)
  sắp theo đúng thứ tự §2 (`color → skin → warp → eyesTeeth → makeup`) nên thứ tự đăng ký
  không đổi được ảnh; slider = 0 thì node **không dispatch, không cấp phát**, EditState rỗng
  chỉ copy nguyên ảnh (bit-exact). Giữ nguyên ràng buộc bắt buộc của S3: guided filter
  **s = 4**, lưới **65 preview / 129 export**, lọc trên **sRGB đã gamma**, shader
  **precompile** qua `RenderGraph.prewarm()` (2 file `.metal` nối lại, vẫn **1 lần compile/tiến
  trình**). RPEngine **vẫn không import RPVision**: seam là value type thuần
  `FaceRenderInput`/`RenderMask` (bytes + affine), đúng hình dạng `ParsedFace.feathered(_:)`
  + `CropRegion.outputToImage` trả ra; adapter nằm ở app target
  (`App/FaceAnalysisRenderBridge.swift`) vì `FaceAnalysis` kéo theo Core ML — bridge này có
  test riêng (`RetouchProAppTests`, target không `TEST_HOST`, 11 test) sau khi review vòng 1
  phát hiện nó chưa test. Mọi bán kính là **phân số theo face width** (mịn da 0.030×, blur
  lớn 0.150×) → preset chuyển được giữa các ảnh. 8 slider Da chạy trong **1 pass composite**
  trên 2 lớp mờ: `base` = guided filter (giữ biên) và `low` = chính guided filter với
  **ε = 1e6**, tức double box blur (test đo lệch 3.1e-7) — không viết kernel blur thứ hai.
  "Giữ texture" là **modifier** của "Mịn da", ở 100 thì triệt tiêu đúng bằng ảnh gốc, nên
  không tính vào `isIdentity`. Golden PSNR so `SkinReference` (bản CPU `Double` viết từ đặc
  tả, độc lập code path nhưng cùng thứ tự bước với shader nên chỉ bắt lỗi transcribe, không
  bắt lỗi công thức chung — như `SpikeS3Support` ở S3): **toàn node 79.0 dB**, riêng
  composite 151.8 dB, từng slider 151.5–189.0 dB, mask lệch tối đa 2.4e-3 — **vượt bar 45
  dB**. Tốc độ trên M1 Pro, ảnh a6300 thật (4000×6000): preview 2048 px đủ 8 slider
  **3.22 ms → 311 fps**, chỉ mịn da 1.66 ms → 602 fps; 24 MP **33.8 ms** (bar là 8 s). iOS
  Simulator: 4.76 ms preview / 35.2 ms export — **chưa đo trên iPhone thật**, giống
  S1/S2/S3/FaceAnalyzer. Bộ nhớ scratch 24 MP là **552 MB** (base 192 + low 192 + guided
  144 + mask 24 MB, đã verify bằng tay; cấp phát lười nên sửa mình mịn da chỉ tốn 360 MB) —
  số phải kiểm lại trên máy thật trước tiên. Ba slider ship bản **đơn giản nhất-mà-đúng và có
  ghi rõ giới hạn**: *Quầng thâm* nâng mọi vùng tối cục bộ trong mask da chứ chưa giới hạn
  quanh hốc mắt; *Nếp nhăn* lấp nửa âm của high-pass nên không phân biệt được nếp nhăn với
  sợi tóc/lông mi; *Khử đỏ* dùng `R − (G+B)/2` so mức trung bình cục bộ chứ không dùng bảng
  Selective Color của `commands.js`. Sau flag mặc định tắt `RPEngineFeatureFlags.skinSliders`
  (+ `.guidedFilter`) — bản thân `RenderGraph` không có flag riêng, tắt hết các nhóm slider thì
  graph rỗng, chỉ copy nguyên ảnh (không throw). Review vòng 1 bắt được 2 lỗi phải sửa (blit sai định
  dạng texture khi passthrough; `SkinRenderNode.cache` cứng subsample của preview thay vì
  theo request — giờ `GuidedFilter` có `precondition` chặn lệch resources/options) — cả hai
  đã sửa và có regression test, review vòng 2 **PASS**. Số liệu:
  `Research/bench/p2-skin-{macos,ios-simulator}.json`, `Scripts/bench-skin.sh`, `docs/ADR-0009`.
- **Đã làm (2026-09-06), nhóm slider "Mặt" + `WarpRenderNode`:** đưa kernel MLS của S3 lên
  API sản phẩm ở `RenderStage.warp`. 15 slider (Bóp mặt, Gò má, Hàm, Cằm, Trán, Thái dương,
  Mũi thu nhỏ/sống/đầu, Mắt to/khoảng cách/nghiêng, Miệng to/cười, Môi đầy) 0–100, mặc định 0,
  ở 0 là **bit-exact** (đo). Toàn bộ toán slider nằm trong `FaceReshape` — hàm **thuần**, không
  Metal, test không cần GPU. Hệ trục là của chính khuôn mặt (gốc `p[10]`, trục `p[10]→p[152]`):
  theo **roll** đã verify chính xác (bất biến dưới xoay mesh 0.4 rad). Theo **yaw thì mới quan
  sát, chưa validate** — tỉ trọng má trái dao động 0.480–0.683 trên 11 ảnh thật (0.5 là chính
  diện) nên khung có phản ứng theo pose, nhưng đúng bao nhiêu thì **chưa đo được** vì không có
  ground-truth head pose. (Review vòng 1 bắt lỗi: claim cũ "tổng hai má đúng bằng 1 ⇒ xử lý đúng
  yaw" là ngộ nhận — tổng đó luôn ≈1 kể cả ảnh gần như chính diện `DSC05259` (+0.4998/−0.5000),
  sai số tổng chỉ 1.6e-3 trên cả 11 ảnh, nên không phân biệt được đúng/sai yaw; đã rút lại claim.)
  Mọi biên độ là **phân số của face width** hoặc gain không thứ nguyên →
  `f(k·landmark, k·faceWidth) == k·f(landmark, faceWidth)` **chính xác** (test ở k = 0.25/1/3.7/11,
  sai số < 1e-9×faceWidth) — đây chính là điều kiện §2 để preset chuyển được giữa các ảnh và
  giữa preview 2048 px với export 24 MP. Quy tắc handle: mỗi slider góp **cả vùng** của nó, kể cả
  điểm trọng số 0 (thành neo identity) — nhờ đó "Môi đầy" ghim vòng môi trong (môi dày lên mà
  khoang miệng không mở ra) và "Bóp mặt" không kéo thái dương vào. Danh sách index môi và mũi
  **không lấy theo trí nhớ** mà chọn từ `(t, u/faceWidth)` đo trên 11 mesh a6300 thật: loại
  candidate 275 vì đổi dấu trên 4/11 ảnh, loại candidate 457 vì tuy không đổi dấu nhưng nằm sát
  trục giữa gấp 5× so điểm cánh mũi tệ nhất đã chọn (nhiễu landmark có thể lật dấu); luật vùng
  hình học đã thử và bỏ (nó gom 60–110 điểm má). Kiểm hình học 11 ảnh: oval bao ≥ 0.941 landmark
  còn lại, vòng môi trong nằm trong vòng ngoài 20/20 ở 11/11 ảnh, hai cánh mũi và hai mắt luôn
  nằm khác phía trục giữa, 10/10 điểm iris nằm trong mắt của nó (iris gán theo **khoảng cách**,
  không theo tên "left/right" của MediaPipe; chiều nghiêng mắt cũng suy ra từ hình học). Giữ
  nguyên ràng buộc S3: lưới **65 preview / 129 export**, **luôn có border anchor** (4/cạnh → 166
  control point cho cả nhóm), `similarity`, α = 2; **không thêm file `.metal` nào** (3 hàm shader
  đã có từ S3, vẫn 1 lần compile/tiến trình). Vì warp là biến dạng hình học nên golden có **3
  tầng**: (1) grid solve GPU so CPU `Double` lệch **1.52e-3 px** (65, +37% so S3's 1.11e-3 do
  gần gấp đôi handle — 84→150) / **3.29e-3 px** (129, −1.5% so S3) trên 11 mesh thật, vẫn dưới
  bar 0.01 px 6.6×/3.0×; (2) **round-trip landmark** qua lưới lệch tối đa 3.55 px =
  **0.0067×faceWidth** (65) / 2.62 px = 0.0043 (129), trung bình 0.50 / 0.20 px — đây là sai số
  của **lưới**, không phải của node, và 129 chỉ tốt hơn 65 khoảng 1.4× vì α = 2 làm trường biến
  thiên gắt quanh handle; (3) ảnh render so `WarpReference` (bản CPU `Double` tự raster lại
  chính lưới đó) **82.7 dB**, lệch tối đa 1.8e-3 — vượt xa bar 45 dB. Tốc độ M1 Pro, ảnh a6300
  thật: preview 2048² đủ 15 slider **0.88 ms → 1142 fps**; export **24 MP thật** (mesh dời vào
  khung 4000×6000 bằng `crop_rect` của manifest, crop không resample) **2.79 ms**; iOS Simulator
  2.68 ms / 4.21 ms. Bộ nhớ node chỉ là lưới: **166 kB preview / 659 kB 24 MP** (so với 552 MB
  của nhóm Da). **Chưa đo trên iPhone thật** — giống S1/S2/S3/FaceAnalyzer/Da. Ghi rõ giới hạn:
  mọi hằng số biên độ **chưa tinh chỉnh theo thẩm mỹ** (cần người xem render), α = 2 kế thừa từ
  ADR-0007 chứ chưa đo, mỗi slider chỉ **một chiều** (Cằm ngắn lại, Trán hạ chân tóc, Thái dương
  đẩy ra, Mắt khoảng cách xa ra) vì luật 0–100; bản hai chiều là quyết định UI/plan chứ không
  phải sửa `FaceReshape`. Sau flag mặc định tắt `RPEngineFeatureFlags.warpSliders`
  (+ `.mlsMeshWarp`) — cùng chuẩn không-flag-chung với nhóm Da; `RenderGraph.standard` chỉ đăng
  ký node nào có flag bật, tắt hết các nhóm thì graph rỗng (không throw). Review vòng 1 bắt 2
  lỗi phải sửa (flag `renderGraph` dùng chung giữa 2 nhóm khiến tắt nhóm này tắt luôn nhóm kia —
  đã xoá hẳn flag chung; claim yaw ở trên — đã rút lại và ghi rõ giới hạn) — cả hai đã sửa có
  regression test, review vòng 2 **PASS**. Số liệu:
  `Research/bench/p2-warp-{macos,ios-simulator}.json`, `Scripts/bench-warp.sh`, `docs/ADR-0010`.
- **Đã làm (2026-09-06), nhóm slider "Mắt/Răng" + `EyesTeethRenderNode`:** 4 slider (Sáng mắt,
  Trắng lòng trắng, Nét mắt, Trắng răng) 0–100, mặc định 0, ở 0 là **bit-exact**, ngoài mask cũng
  bit-exact (đo). Đúng hai ràng buộc bắt buộc của S2: (1) **không có lớp răng** — `RenderMaskKind`
  vẫn không có case `teeth`, "Trắng răng" suy từ **luminance + độ bão hoà trong `mouthInterior`**;
  (2) mask mắt/miệng **luôn feathered** (bridge chỉ gọi `ParsedFace.feathered(_:)`, có test mới
  trong `RetouchProAppTests`). Phát sinh thêm một quan sát: **cũng không có lớp lòng trắng**
  (`l_eye`/`r_eye` là cả khe mắt, gồm mống + đồng tử), nên "Trắng lòng trắng" dùng **cùng công
  thức** với răng, chỉ khác ngưỡng bão hoà: `weight = saturate((luma − luma cục bộ)/0.06) ×
  saturate(1 − sat/knee)`, knee **0.60 cho lòng trắng** (lỏng — lòng trắng đỏ/hồng chính là ca
  cần sửa; mống mắt đã bị loại bởi số hạng luma) và **0.40 cho răng** (chặt — đối thủ trong khoang
  miệng là môi/lợi/lưỡi đều đỏ đậm). "Trắng" = bỏ 85% chroma **giữ nguyên luma** rồi nâng 10% về
  trắng, tách vậy nên răng vàng không thành xám nâu. So với **trung bình cục bộ** chứ không phải
  ngưỡng tuyệt đối → chịu được thay đổi phơi sáng và tông da. Lớp trung bình cục bộ là **chính
  guided filter với ε = 1e6** (double box blur), bán kính **0.050×faceWidth** → không viết kernel
  blur thứ hai; cấp phát **lười**: chỉ "Sáng mắt" thì không đụng tới nó (**24 MB** thay vì 384 MB
  ở 24 MP). "Nét mắt" là **tương phản cục bộ ở cỡ con mắt, không phải sharpen mức pixel** (unsharp
  thật cần lớp blur bán kính nhỏ thứ hai = thêm 192 MB ở 24 MP) — nói rõ chứ không để tên slider
  tự hàm ý. Rút `SkinRenderNode.encodeMask` thành `MaskRasteriser` dùng chung (nhóm này cần 2
  kind), kernel `rp_skin_mask` giữ nguyên tên; golden của nhóm Da **giống hệt tới từng chữ số**
  trước/sau khi rút (79.023038843777613 dB / 151.79566853244586 dB, reviewer tự chạy lại xác
  nhận). Thêm **file `.metal` thứ 3** nhưng vẫn **1 lần compile/tiến trình** (nối vào cùng
  `makeLibrary(source:)`, dùng lại `kRPLuma` + `rp_skin_mask`). Golden 3 tầng so `EyesTeethReference`
  (bản CPU `Double` viết từ đặc tả, cùng giới hạn "chỉ bắt lỗi transcribe, không bắt lỗi công thức"
  như `SkinReference`): mask mắt/miệng lệch **2.08e-3**, composite **158.9 dB**, từng slider
  159.7–178.0 dB, **toàn node 89.9 dB** — vượt bar 45 dB. Thêm một loại số **PSNR không nói được**:
  **độ chọn lọc** trên chân dung tổng hợp có nhãn vùng (không có ground-truth răng/lòng trắng trên
  ảnh thật) — `teethWhiten=100` đổi răng 0.0249 và **lợi đúng bằng 0**; `scleraWhiten=100` đổi
  lòng trắng 0.0151 và **mống mắt đúng bằng 0** (da 3.9e-7 = vệt feather tràn khỏi ellipse cứng,
  nhỏ hơn 64 000 lần) — reviewer xác nhận số 0 này là hệ quả thật của `saturate()` khi lift bão
  hoà về 0, không phải do ảnh test dựng sẵn tương phản bằng 0. Tốc độ M1 Pro, ảnh a6300 thật
  (4000×6000): preview 2048 px đủ 4 slider **1.86 ms → 538 fps**, chỉ Sáng mắt 0.56 ms → 1779 fps;
  24 MP **19.9 ms** (bar 8 s). iOS Simulator 5.16 ms preview / 17.5 ms export — **chưa đo trên
  iPhone thật**, giống S1/S2/S3/FaceAnalyzer/Da/Mặt. Ghi rõ giới hạn: mọi hằng số (2 knee,
  0.85/0.10, gain, gamma) **suy từ vật lý chứ chưa tinh chỉnh theo mắt người**; đốm loé trên mống
  mắt và mống mắt xám/xanh sáng bị tính nhầm là lòng trắng; lòng trắng đỏ ngầu tự nó kéo trọng số
  xuống nên **sửa non đúng chỗ cần nhất**; răng trong bóng/răng kim loại bị bỏ qua. Sau flag mặc
  định tắt `RPEngineFeatureFlags.eyesTeethSliders` (+ `.guidedFilter`). **Cờ kernel `guidedFilter`
  giờ có 2 nhóm dùng chung** → `disableSkinRenderGraph()`/`disableEyesTeethRenderGraph()` chỉ tắt
  nó khi nhóm kia không còn cần (đọc chính cờ nhóm kia, **không** phải refcount đã bị bác ở
  ADR-0010 — vẫn tôn trọng cờ set tay không qua helper); nếu tắt vô điều kiện thì tái lập đúng lỗi
  cờ-chung của ADR-0010 (tắt Da làm `RenderGraph.standard()` throw cho Mắt/Răng) — có regression
  test hai chiều, review **PASS** ngay vòng 1 (không phải sửa lại). Rủi ro chưa xử lý, ghi nhận
  chứ không chặn: nếu Da (552 MB) và Mắt/Răng (384 MB) cùng bật ở export 24 MP thì cộng dồn
  ~936 MB scratch — **phải kiểm trên iPhone thật trước khi bật mặc định cả hai**. Số liệu:
  `Research/bench/p2-eyes-teeth-{macos,ios-simulator}.json`, `Scripts/bench-eyes-teeth.sh`,
  `docs/ADR-0011`.
- **Đã làm (2026-09-06), nhóm slider "Color" + `ColorRenderNode`:** node **đầu tiên** của pipeline
  (`RenderStage.color`, trước Da/Mặt/Mắt-Răng). 10 tên trong plan ship thành **18 slider** 0–100,
  mặc định 0, ở 0 **bit-exact** (đo, max abs = 0): WB tách 2 trục (`wbTemperature` ấm,
  `wbTint` sang magenta) và HSL thành **8 dải màu** (`hslRed`…`hslMagenta`) — đúng kiểu
  "Mũi (thu nhỏ/sống/đầu)" của nhóm Mặt. Mỗi slider **chỉ một chiều**, và đây là **bắt buộc chứ
  không phải chọn**: `EditSection.setSlider` **xoá** key khi đặt về 0 (đã kiểm trực tiếp trong
  `RPCore/EditState.swift`, không chỉ tin báo cáo coder), nên "vắng mặt" và "trung tính" phải là
  cùng một số; slider có dấu hoặc trung tính ở 50 sẽ làm `EditState` rỗng không còn là passthrough
  — muốn hai chiều phải sửa `Slider` ở RPCore (quyết định plan), không phải sửa node. Node này
  **không nhận `FaceRenderInput`**: color là chỉnh toàn ảnh, nên chạy được cả trên ảnh **không có
  mặt** (phong cảnh, ảnh sản phẩm). **Chọn Metal thuần chứ không dùng CIFilter** dù §1.3 ghi
  "Core Image + kernel", có **control đo thật** chứ không lý luận suông: (1) `CIColorControls`/
  `CIVibrance`/`CIToneCurve`/`CITemperatureAndTint` **không công bố công thức** nên không thể viết
  reference `Double` đạt bar 45 dB; (2) **9/18 slider không có CIFilter** (HSL theo dải, Auto D&B 2
  thang) nên vẫn phải viết kernel; (3) đo trên cùng texture, cùng tiến trình: chuỗi CI làm **9/18
  slider** (contrast+saturation chung 1 lệnh `CIColorControls`, temperature+tint chung 1 lệnh
  `CITemperatureAndTint`) tốn 1.25 ms preview / 7.64 ms 24 MP so với node này làm **18/18 slider**
  1.59 / 9.46 ms — tức **ngang nhau**, tốc độ *không* phải lý do (không claim Metal nhanh hơn; số
  9/18 này reviewer bắt được coder ghi nhầm "8/18" ở ADR/bench trước khi commit — đã sửa và chạy
  lại bench để khớp). Thứ tự 9 bước trong composite là hợp đồng, reference dựng lại từng bước:
  Auto D&B → Exposure+WB (**trong ánh sáng tuyến tính**, ngoại lệ duy nhất của
  `pixelSpace == .sRGBEncoded`, đổi hệ 1 lần cho cả 2, đã verify không rò rỉ sang slider khác) →
  Highlights/Shadows (gamma giữ hai đầu, cửa sổ theo luma) → Contrast (smoothstep) → Curves →
  Vibrance → Saturation → HSL. **Auto D&B là bản port đúng số của `autoskin.js`** (đã đối chiếu
  trực tiếp với `panelpts/RetouchProUXP/autoskin.js`+`commands.js`, không chỉ tin báo cáo): lưới
  phân tích **rộng 320**, `rBig = max(3, 0.055×320) = 18`, `rSmall = max(1, 0.012×320) = 4`,
  `k = strength/50×9`, hai đường cong khớp thành gamma **0.8091**/**1.2199** đúng với 2 điểm cong
  gốc `[128,146]`/`[128,110]`. Lưới nhỏ này là lý do node nhẹ: **2.46 MB** ở 24 MP (rẻ nhất trong 4
  nhóm — Da 552 MB, Mắt/Răng 384 MB). Hai chỗ **lệch so với `commands.js`, ghi rõ**: D&B chạy
  **toàn khung, không nhân mask da** (mask sẽ kéo tầng color — chạy *trước* tầng da — phụ thuộc
  khuôn mặt), và clamp mask upsample **sau** bilinear chứ không trước. "Curves" là cường độ một
  đường cong film cố định qua **LUT 256 ô/kênh** (không phải trình soạn knot người dùng — đổi knot
  sau này chỉ đổi dữ liệu, không đổi kernel), sai số LUT+lerp **3.8e-6**. HSL là 8 cửa sổ tam giác
  ±60° chuẩn hoá theo tổng → phân hoạch đơn vị, 8 dải cùng 100 đúng bằng Saturation 100 (lệch max
  **0.0**, có test). Golden 2 tầng so `ColorReference` (bản CPU `Double`, cùng giới hạn "chỉ bắt
  lỗi transcribe" như `SkinReference`/`WarpReference`/`EyesTeethReference`): composite **137.8 dB**,
  từng slider **143.2–168.6 dB** (3 slider = vô cực vì trên fixture chỉ đổi vùng màu phẳng), **toàn
  node 136.3 dB**, max abs 9.5e-7 — vượt xa bar 45 dB. Số **PSNR không nói được**: Highlights kéo
  đầu sáng **−0.0483**, đầu tối **đúng 0**; Shadows nâng đầu tối **+0.1059**, đầu sáng **0**; Auto
  D&B **−0.0727** đốm sáng / **+0.0738** đốm tối / **+0.0013** dốc phẳng; `hslRed` đổi mảng đỏ
  0.1162, xanh lá/aqua **đúng 0**; exposure = **+1 EV** (tỉ lệ 1.9999997); WB giữ độ sáng (lệch
  −3.9e-4). Tốc độ M1 Pro, ảnh a6300 thật (4000×6000): preview 2048 px đủ 18 slider **1.59 ms →
  628 fps**, chỉ tone 0.54 ms; 24 MP **9.46 ms** (bar 8 s). iOS Simulator 3.62 ms preview / 10.0 ms
  export — **chưa đo trên iPhone thật**, giống S1/S2/S3/FaceAnalyzer/Da/Mặt/Mắt-Răng. Ghi rõ giới
  hạn: mọi hằng số **chưa tinh chỉnh theo mắt người**; mỗi slider một chiều; Auto D&B toàn khung;
  HSL chỉ có bão hoà (chưa độ sáng/xoay hue). Sau flag mặc định tắt
  `RPEngineFeatureFlags.colorSliders` — **không dùng chung cờ kernel với nhóm nào** (node sở hữu cả
  4 kernel của nó), `disableColorRenderGraph()` vô điều kiện mà không kéo nhóm khác xuống, có
  regression test hai chiều. Thêm **file `.metal` thứ 4** nhưng vẫn **1 lần compile/tiến trình**.
  Review **PASS ngay vòng 1** (không phải sửa lại — chỉ 1 gợi ý không chặn về số 8/18 vs 9/18 nêu
  trên, đã sửa trước khi commit). Số liệu: `Research/bench/p2-color-{macos,ios-simulator}.json`,
  `Scripts/bench-color.sh`, `docs/ADR-0012`.
- **Đã làm (2026-09-07), preview realtime `MTKView` + chọn mặt trên canvas:** đưa `RenderGraph`
  lên màn hình thật, panel chuyển từ 45 dòng disabled thành **45 slider chạy thật** (Da 8, Mặt 15,
  Mắt/Răng 4, Color 18), key lấy thẳng từ `*Sliders.Key.all` của RPEngine nên UI không lệch tên với
  node. `LivePreviewRenderer` (RPEngine) giữ ảnh trên GPU: **upload 1 lần/ảnh**, kéo slider chỉ chạy
  graph, zoom/pan chỉ chạy pass `rp_preview_present` (file `.metal` **thứ 5**, chỉ đặt/thu phóng,
  không có toán retouch, vẫn **1 lần compile/tiến trình**). Drawable `bgra8Unorm` + colorspace sRGB
  — **không phải `_srgb`** (giá trị đã gamma sRGB theo ADR-0007, `_srgb` sẽ encode lần hai làm ảnh
  bạc màu); preview hiển thị 8-bit, pipeline sau nó vẫn 16F, export (Phase 3) đọc texture chứ không
  đọc drawable. Bằng chứng chính: đường qua UI so `RenderGraph.renderPixels` **bit-exact** (lệch
  max abs = 0.0, reviewer tự chạy lại xác nhận); bản 16F ship thật lệch đúng 1 nấc half-float
  4.88e-4 → 74.45 dB; present ở 1:1 lệch 0.0. Kéo slider **không ghi đĩa**, chỉ ghi 1 lần khi thả
  tay/đổi ảnh. **Chọn mặt**: `EditState` trước đây không có khái niệm mặt đang chọn; chốt mô hình
  slider vẫn dùng chung cho cả ảnh, thêm đúng 1 số nguyên `perImage["selectedFace"]` (vắng = mọi
  mặt = hành vi cũ) — để trong `perImage` vì `Preset` **không có** field này (đã kiểm trực tiếp
  `RPCore/Preset.swift`, không chỉ tin báo cáo) nên "mặt số 2" không đi theo preset sang ảnh khác;
  chọn mặt **thu hẹp `RenderRequest.faces`, không sửa node** (đã grep xác nhận không node nào tham
  chiếu `FaceSelection`) → mọi số đã đo của 4 nhóm slider **không đổi**; áp cho cả 3 nhóm phụ thuộc
  mặt kể cả Da, Color không bao giờ bị thu hẹp. UI: khung chữ nhật quanh từng mặt trên canvas, chạm
  để chọn, hit-test ưu tiên khung nhỏ nhất. **4 cờ nhóm slider bật mặc định ở *app target*
  (`App/AppEngineSetup.swift`), gói RPEngine vẫn mặc định tắt** — luật "flag mặc định tắt" là luật
  của thư viện, app là chỗ số đã đo được dùng (cả 4 nhóm đã có golden 79.0/82.7/89.9/136.3 dB); tắt
  lại qua `RP_DISABLE_GROUPS`/`defaults write`, không cần build lại. **Chưa bật export** (rủi ro
  ~936 MB scratch Da+Mắt/Răng ở ADR-0011 chưa kiểm trên iPhone thật) — task này chỉ dựng đường
  `RenderQuality.preview`. Phân tích khuôn mặt chạy **1 lần/ảnh** qua seam `FaceInputProviding`
  (RPEngine không import Core ML; adapter ở app target dùng lại `FaceAnalysisRenderBridge`, cache
  key `<hash>@<w>x<h>` vì cùng ảnh 2 độ phân giải là 2 kết quả khác nhau) — có test ghim 100 lần đổi
  slider = 0 lần phân tích thêm. Tốc độ M1 Pro, ảnh a6300 thật (4000×6000) ở preview 2048 px: đủ 4
  nhóm **8.03 ms → 125 fps**, riêng lẻ color 1.64/da 3.26/mặt 0.71/mắt-răng 1.88 ms, present
  (zoom/pan) 0.39 ms, kéo slider 60 khung liên tiếp **8.25 ms/khung → 121 fps**; chi phí 1 lần/ảnh:
  decode 117.4 ms + upload 11.5 ms. iOS Simulator: 7.47 ms preview đủ 4 nhóm / 8.97 ms mỗi khung khi
  kéo; decode 464.8 ms. **Chưa đo trên iPhone thật** — giống S1/S2/S3/FaceAnalyzer/Da/Mặt/Mắt-Răng/
  Color. Giới hạn ghi rõ: `RenderGraph.render` vẫn `waitUntilCompleted` **trên main thread** (~8 ms/
  khung, thoải mái ở 60 Hz máy này, rủi ro thật trên máy chậm hơn — sửa là sửa `RenderGraph` chứ
  không phải UI, nên đợi số máy thật); khung mặt là hình chữ nhật chứ không phải viền mesh; chưa ai
  chấm render bằng mắt — item này làm các hằng số *nhìn thấy được*, không phải tinh chỉnh chúng.
  Review vòng 1 bắt 1 lỗi phải sửa (ADR-0013 trích số cũ 9.29 ms/35.7 ms không khớp file bench thật
  — đã sửa khớp lại toàn bộ số trong ADR với file JSON hiện có) — đã sửa, không cần review lại vì
  chỉ là lỗi tài liệu, không phải code. Số liệu:
  `Research/bench/p2-live-preview-{macos,ios-simulator}.json`, `Scripts/bench-live-preview.sh`,
  `docs/ADR-0013`.
- **Đã làm (2026-09-08), slider hai chiều −100…100, khoanh vùng đúng nhóm "Màu":** mở lại đúng
  một điểm ADR-0012 đã ghi là "cần quyết định ở tầng plan". **16/18** slider Color thành
  −100…100; **`curves` và `autoDodgeBurn` giữ 0…100**; **Da/Mặt/Mắt-Răng không đụng tới**, vẫn
  0…100. Lý do mở: nhóm Color là nhóm duy nhất phải **sửa cái đã có trong file** chứ không phải
  thêm hiệu ứng — ảnh a6300 (hoặc JPEG đã qua preset người khác) về tay đã quá sáng/quá rực/quá
  ấm, và với thang 0…100 thì "bớt đi" là không thể diễn đạt. Lập luận cũ "một chiều là **bắt
  buộc** vì `setSlider` xoá key ở 0" **đúng một nửa**: hợp đồng chỉ cần **mặc định == trung tính
  == identity**, không hề cấm có giá trị ở **cả hai phía** của 0. 0 vẫn là mặc định, vẫn bị xoá
  khỏi JSON, vẫn passthrough **bit-exact** (đo lại: max abs = **0**) — cái thật sự bị cấm là
  slider trung tính ở 50, và vẫn không có cái nào. **Không nới `Slider.range` toàn cục** (một
  dòng, compile được, và sai): tra cứu theo **(section, parameter)** qua
  `Slider.range(for:in:)` với `bidirectionalSections = {color}` + `oneDirectionalParameters`;
  nới toàn cục sẽ cho slider Mặt nhận −100 — giá trị `FaceReshape` không có nghĩa gì, không
  control-point MLS nào thiết kế cho nó, ADR-0010 chưa đo bao giờ — và Mịn da −100 = "thêm
  nhiễu". Có regression test hai đầu ghim chuyện này: `SliderRangeScopeTests` (RPCore),
  `SliderPanelLayoutTests` (RPUI), và `EditorModelTests` chạy model thật: −40 vào `color.exposure`
  **sống tới đĩa**, −40 vào slider Da **kẹp về 0 và bị xoá key**. Hai slider giữ một chiều là
  **có lập luận, không phải bỏ sót**: `curves` là *cường độ* một look film cố định — nghịch đảo
  của một look không phải là look, và ngoại suy qua 0 làm **kẹp thật** (toe nâng 0.030 → đen
  thành **−0.030**, bẹp 3 % đáy thang); `autoDodgeBurn` là **phép sửa lỗi** đo sai số sáng cục bộ
  của chính khung đó rồi giảm nó đi, đảo dấu = **khuếch đại đúng cái đốm nó sinh ra để xoá**.
  Nửa âm **không phải là bản soi gương** của nửa dương — soi gương sai đo được ở 4 chỗ, nên mỗi
  slider đối xứng trong **không gian mà phép toán sống**: exposure `exp2(a)` đối xứng theo
  **stop** (−100 = 0.5×, nghịch đảo đúng của 2×; gain `1+a` sẽ ra **đen thui**), WB
  `pow(1±k, a)` đối xứng theo **log gain** (điểm cuối vẫn đúng 1.22/0.78/0.88 của ADR-0012, và
  −x là nghịch đảo **từng kênh** của +x), Highlights/Shadows dùng **gamma nghịch đảo** `1/g` với
  `|a|` làm trọng số trộn (bản soi gương ngoại suy sẽ đẩy pixel gần đen **xuống dưới 0**),
  Saturation **tuyến tính** theo hệ số nhân chứ không mũ (mũ `2^a` chỉ tới 0.5× và **không bao
  giờ chạm** trắng đen). Contrast là chỗ duy nhất ngoại suy *đúng*: trộn ngược khỏi smoothstep
  làm ảnh phẳng về xám giữa, vẫn giữ hai đầu và vẫn **đơn điệu** (dốc đáy **0.750 > 0**, đo).
  **Bug thật đã bắt được, không phải dọn dẹp**: mọi test `> 0` và mọi tổng "có gì bật không" đều
  viết từ thời chỉ có số dương — `active = exposure + contrast + …` với dấu sẽ cho **exposure
  +50, contrast −50 → tổng 0 → trả về ảnh gốc** trên tấm ảnh người dùng vừa chỉnh; y hệt ở
  `hslTotal` (đổi tên `hslAbsoluteTotal`) và `needsLinearLight` (bỏ qua vòng ánh sáng tuyến tính
  khi exposure **âm**). Đã đổi hết sang `!= 0` và **tổng trị tuyệt đối** `fabs()`, có test ghim:
  cặp triệt tiêu vẫn đổi ảnh **0.1418** (exposure/contrast) và **0.3023** (HSL), không phải 0.
  `needsDodgeBurnAnalysis` **cố tình giữ `> 0`** vì đó đúng là slider không bao giờ âm. Giữ
  nguyên quy ước dấu `highlights`/`shadows` của ADR-0012 (dương = **kéo vùng sáng xuống**,
  **ngược Lightroom**): lật bây giờ sẽ **âm thầm diễn giải lại mọi giá trị đã ghi** trong
  `edits/*.json`, nên ghi vào tài liệu + dòng direction trên UI thay vì lật. Golden (M1 Pro):
  từng slider ở **−100** đạt **142.96–174.60 dB** (thấp nhất `wbTemperature`, cao nhất `hslBlue`,
  cộng `hslAqua`/`hslGreen` vô cực như cũ), composite trộn dấu **138.05 dB**, **toàn node trộn
  dấu 139.33 dB** (max abs 5.4e-7), toàn dương 136.58 dB — bar 45 dB. Số PSNR không nói được:
  Highlights −100 **đẩy đầu sáng lên +0.0360** (so −0.0483 ở +100), đầu tối **đúng 0**; Shadows
  −100 **dìm đầu tối −0.0755**, đầu sáng **0**, pixel tối nhất còn **0.00757 > 0** và **0 kênh
  bị kẹp**; Exposure −100 = **−1 EV** (tỉ lệ 0.49999995); Saturation −100 = trắng đen **thật**
  (chroma dư **0.0**) và 8 dải HSL cùng −100 khớp đúng nó (lệch **3.0e-8**); Contrast dải ramp
  0.6478 → **0.5596** ở −100 (và 0.7360 ở +100); WB ±60 quay về lệch **0.00201** ngoài vùng kẹp
  (0.0347 nếu tính cả 2880 kênh kẹp ở mảng màu bão hoà — ghi cả hai, không chỉ số đẹp). **Tốc độ
  có trả giá và đã đo tử tế**: 3 `pow()`/pixel thay 3 phép nhân-cộng ở khối WB. Đọc lần đầu ra
  **+14 %** ở 24 MP nhưng **chạy lại 3 lần mới dám kết luận** — biên độ run-to-run của
  `all_sliders` là **~6 %**, nên +14 % là nhiễu: 9.197 ms (nền ADR-0012) → **9.538 / 9.966 /
  10.088**, tức **+8 %** theo median. Cái làm số này đọc được là **hàng control**: `all_sliders_
  at_zero` (nhánh passthrough, chỉ đổi thêm `fabs()`) đi **2.078 → 2.097 ms = +1 %**, tức máy
  **không trôi**, và +8 % kia là chi phí thật của `pow()`; `tone_only` +4.6 % đều cả 3 lần (khối
  có exposure+WB, không có HSL/D&B) khớp cùng giải thích. Preview 2048 px **1.449 ms GPU (1.72 ms
  wall) → 581 fps** (bar 30 fps; `all_sliders_fps` trong JSON tính theo wall, cùng cách ADR-0012
  trích — bảng so sánh ở trên dùng GPU median cả hai phía nên vẫn cùng hệ quy chiếu), 24 MP
  **9.54 ms** (bar 8 s), **trộn dấu tốn ngang toàn dương** (10.237 ms) — không
  có đường chậm cho giá trị âm. Bộ nhớ **không đổi** (2.46 MB). Ghi rõ một tối ưu **cố ý chưa
  làm**: 3 `pow()` đó có tham số **uniform** (`pow(1.22, wbTemperature)` giống hệt mọi pixel) nên
  hoàn toàn tính được 1 lần trên CPU rồi truyền vào — lời ~0.8 ms/khung ở 24 MP, nhưng đổi ý
  nghĩa và layout `ColorParams` (đang bị test ghim stride) và kéo theo `ColorReference`; với 3 bậc
  độ lớn dư địa so bar export thì không đáng đổi trong task này, ghi lại để là **nước đi đã biết
  chứ không phải phát hiện sau này**. iOS Simulator chạy lại cùng schema: **golden giống hệt Mac
  từng chữ số** (0 / 142.96–174.60 / 138.05 / 139.33 dB) — đúng như kỳ vọng và đáng nói: claim độ
  chính xác là tính chất của **shader**, không phải của GPU chạy nó; wall-clock 11.6 ms ở 24 MP,
  4.577 ms preview, `gpu_median_ms` ở Simulator vô nghĩa (`is_real_device: false`). UI: track vẽ
  **0 ở giữa** và fill từ tâm ra cho hàng hai chiều, số có **dấu `+` tường minh** (chỉ ở hàng hai
  chiều), dòng direction **gọi tên cả hai đầu** (`+ ấm hơn · − lạnh hơn`), VoiceOver đọc
  `"+40, từ -100 đến 100"`, phím tăng/giảm kẹp theo `range.lowerBound` chứ không phải 0 cứng —
  và `SliderParameter.range` **đọc từ `RPCore.Slider`** chứ không tự khai, nên panel không thể
  mời một giá trị mà document sẽ kẹp mất. Test: **RPCore 73 + RPEngine 166 + RPUI 103 = 342
  pass**. Giới hạn ghi rõ: **chưa ai nhìn render ở −100** — nửa âm mang đúng bộ hằng số chưa tinh
  chỉnh của nửa dương, golden chỉ chứng minh GPU tính đúng công thức đã viết chứ không chứng minh
  công thức đẹp; WB ±x **không** round-trip bit-exact (0.002, tệ hơn ở chỗ kênh bão hoà); chỉ
  nhóm Màu hai chiều. Số liệu: `Research/bench/p2-color-{macos,ios-simulator}.json`,
  `Scripts/bench-color.sh`, `docs/ADR-0016`.
- `RenderGraph` slider (Màu −100…100 cho 16/18 key, các nhóm còn lại 0–100 — `docs/ADR-0016`):
  - **Da**: Mịn da, Giữ texture, Đều màu da, Khử đỏ, Khử bóng dầu, Sáng da, Quầng thâm, Nếp nhăn.
  - **Mặt**: Bóp mặt, Gò má, Hàm, Cằm, Trán, Thái dương, Mũi (thu nhỏ/sống/đầu), Mắt (to/khoảng cách/nghiêng), Miệng (to/cười), Môi đầy.
  - **Mắt/Răng**: Sáng mắt, Trắng lòng trắng, Nét mắt, Trắng răng.
  - **Color**: Exposure, Contrast, Highlights, Shadows, WB (temperature + tint), Vibrance, Saturation, Curves, HSL (8 dải màu), Auto D&B — **18 key**.
- Golden tests PSNR ≥ 45 dB; bench trên iPhone ghi file.

**Cập nhật design (2026-09-10), Turn 3 canvas — "Bộ công cụ đầy đủ theo ảnh tham chiếu":** design canvas
(`claude.ai/design/p/60d411fe-...`) thêm 6 màn hình mới (3a-3f) đưa ra một **rail 19 mục** (thay rail 6 nhóm
hiện tại) theo một app retouch tham chiếu (kiểu Meitu/Facetune), cùng vài chrome mới: khoá nền (background
lock), chế độ Tự động/Thủ công + cọ mask thủ công, thư viện Mẫu (template), bảng Looks/AI Retouch. Quyết định
của user: **làm UI/rail trước, các tính năng lớn/tốn effort thì deactivate (hiện dạng khoá/dimmed, không xây
thuật toán mới đợt này), rồi cập nhật plan** — chi tiết mapping ở `docs/design/SPEC.md` §"Turn 3". Việc cần
làm ngay (Phase 2, UI-only, không thêm RenderGraph node): rail 19 icon (iPhone ngang dưới, macOS dọc phải),
nối 5 mục có sẵn engine thật (Mặt, Mắt, Bọng mắt, Răng → panel Mắt&Răng hiện tại, Mịn da + Kiềm dầu → panel
Da hiện tại) vào các panel **hiện có** (không xây lại UI grid+subtab+single-slider của mockup — pattern đó
tự nó cũng bị khoá, xem SPEC), 12 mục còn lại (Mẫu, Tự động, Thu gọn, Cơ thể, Sửa da, Săn chắc, Căng mọng,
Mụn, Đầu, Tạo khối, Xoá vật thể — Trang điểm/Tóc đã khoá sẵn) hiện dimmed/inert giống Trang điểm/Tóc. Khoá
nền, Tự động/Thủ công, cọ mask, Mẫu, Looks: render nhưng không có tác dụng lên `RenderGraph`/`EditState`.
Việc lớn bị dời (không phải bỏ, ghi nhận lại theo đúng chỗ đã có trong plan):
- **Mụn (acne removal)** → đã có trong Phase 5 ("xoá mụn auto + brush heal/clone"), không phải việc mới.
- **Tóc, Trang điểm** → Phase 5 (đã có).
- **Cơ thể (body reshape)** → Phase 6 ("body reshape", đã có).
- **Xoá vật thể (object removal, LaMa inpaint)** → gần với Phase 6 "tóc con bay (LaMa)", mở rộng phạm vi LaMa
  sang xoá vật thể tự do — ghi thêm vào Phase 6 khi tới lượt, chưa ước lượng riêng.
- **Mới, chưa có trong plan trước đây — thêm vào Phase 6 "Nâng cao"**: Đầu (head reshape, khác face warp vì
  đổi cả khung đầu/tóc), Tạo khối (contour — tô sáng/tối theo landmark, gần với "Auto D&B" của nhóm Màu nhưng
  khoanh vùng theo mesh chứ không toàn khung), Thu gọn/Săn chắc/Căng mọng (slim/firm/plump — nhánh của body
  reshape, cần body pose/segmentation trước, xem §1.2 "Body pose: để sau"), Sửa da (skin-fix, tên mơ hồ trong
  mockup — cần hỏi lại ý nghĩa cụ thể khi tới lượt làm, không suy đoán), Tự động (one-tap auto retouch — áp
  một preset/công thức cố định của toàn bộ nhóm, cần chốt công thức trước khi làm chứ không phải render mới).
- **Mẫu (template gallery) / Looks (AI Retouch preset picker)**: về bản chất là mở rộng của hệ **Preset** đã
  có trong Phase 3 (lưu/áp EditState) — khi làm Phase 3 preset UI, cân nhắc dùng lại chính UI Mẫu/Looks này
  thay vì xây preset UI riêng, nhưng đó là quyết định của lúc làm Phase 3, không phải bây giờ.
- **Khoá nền (background lock)**: cần segmentation chủ thể để gate node theo mask nền/foreground — chưa có
  hạng mục riêng trong plan, thêm vào Phase 6 cùng "background clean" (đã ghi ở đó, background lock là tiền
  đề nhẹ hơn của background clean — làm lock trước blur/clean sẽ tự nhiên hơn).
- **Chế độ Thủ công + cọ mask (manual paint mask)**: hạ tầng dùng chung cho nhiều tool ở trên (brush add/
  subtract một mask cục bộ rồi mới áp slider) — thêm vào Phase 6, làm trước khi làm bất kỳ tool "Thủ công" cụ
  thể nào ở trên vì chúng đều cần nó.

**Cập nhật (2026-09-18) — rail 19 mục phẳng ở trên đã bị thay bằng rail 2 tầng "bộ phận → tính năng con".**
Đoạn 2026-09-10 ngay trên giữ nguyên làm lịch sử; phần *cấu trúc* của nó không còn đúng. Ba vòng phản hồi của
user, cùng một lỗi: (1) "Răng" mở panel mắt; (2) "Mắt" và "Bọng mắt" là hai cửa vào **cùng một** nội dung,
không có gì phân biệt — user bác luôn lập luận "hai mục cùng sáng là đúng"; (3) "Mịn da" và "Kiềm dầu" dùng
chung icon `sparkles` và mở chung một panel không lọc. Quyết định của user (đã hỏi lại và chốt): **tái cấu
trúc rail thành 2 tầng** thay vì vá từng cặp. Kết quả đã ship, UI-only, **không thêm RenderGraph node,
không thêm `EditState.SectionKey`, không migrate gì trên đĩa**:
- Top level còn **8 mục cuộn + chip "Màu" ghim**, **3 nhóm cha**: **Mặt** *(cha)* · **Da** *(cha)* · Mẫu ·
  Tự động · Trang điểm · **Cơ thể** *(cha)* · Tóc · Khoá nền.
- Con của **Mặt**: Hình dáng mặt · Mắt · Răng · Đầu · Tạo khối · Căng mọng · Mụn.
  Con của **Da**: Mịn da · Kiềm dầu · Sửa da. Con của **Cơ thể**: Thu gọn · Săn chắc.
- **"Da" là nhóm cha riêng, không nằm trong "Mặt"** (user chỉnh lại ngay trong ngày): mịn da là khái niệm
  **toàn thân**, engine hôm nay mới chỉ áp qua mask mặt và chính "Sửa da" (`bodySkinSync`, còn khoá) là cái
  mở rộng nó ra cổ/tay/ngực — nên "Sửa da" là **con của "Da"** chứ không đứng lẻ ở top level.
- **"Bọng mắt" bị xoá hẳn** (không phải trỏ lại), "Mặt" cũ (15 slider warp) thành con **"Hình dáng mặt"**.
- Hai namespace tách panel: `eyesTeeth` → "Mắt" (3) / "Răng" (1), `skin` → "Mịn da" (7) / "Kiềm dầu" (1) —
  qua `SliderSectionDescriptor.storageKey`, engine `SkinSliders`/`EyesTeethSliders` và node giữ nguyên.
- Chạm mục cha = mở **con chưa khoá đầu tiên** + hiện dải tab con trong panel (`RailChildStrip`); mục cha khoá
  khi **mọi** con đều khoá (hiện là "Cơ thể"). Chi tiết ở `docs/design/SPEC.md` §Turn 3 "Rail hierarchy".
- Trạng thái khoá của từng tool **không đổi** trong đợt này: Tạo khối vẫn khoá (node có nhưng
  `RPEngineFeatureFlags.contourSliders` mặc định tắt), Đầu/Căng mọng/Mụn/Thu gọn/Săn chắc/Sửa da/Tự động/
  Khoá nền vẫn khoá.
  *(Cập nhật 2026-09-21: **Tạo khối đã được nối UI** và không còn khoá — nó mở panel riêng 3 slider, cờ engine
  vẫn tắt nên nhóm bị disable kèm lý do thay vì khoá cả rail item. Xem "Trạng thái 6.2 — Tạo khối" ở §Phase 6.
  Mười mục còn lại trong danh sách trên vẫn khoá.)*

**Cập nhật kế hoạch (2026-09-11), Phase 6 chi tiết + Share Extension:** Input: `docs/HANDOFF-remaining-features-2026-09-10.md` (13 mục rail khoá + yêu cầu Share Extension), 3 research pass
song song (mask/segmentation, body/head/contour, object-removal+preset+Share Extension — không phải spike đo số,
chỉ khảo sát API/kỹ thuật khả thi để lên kế hoạch, giống cách §1 ban đầu được viết trước Phase 0). Kết quả: Phase 3
có thêm một phase con (3B, Share Extension) chạy song song vì không đụng RenderGraph/Vision; Phase 3 tự nó có thêm
việc nhỏ (mở rộng Preset thành thư viện Mẫu/Looks); Phase 6 được viết lại có **thứ tự phụ thuộc rõ** thay vì một
danh sách phẳng, cộng một spike mới (S5, giống mẫu spike go/no-go của Phase 4) cho nhóm body reshape. Chi tiết đầy
đủ từng mục ở §"Phase 6" bên dưới; đây là tóm tắt các quyết định/thay đổi so với `docs/PLAN.md` bản trước:

- **Xác nhận giữ nguyên**: Mụn (Phase 5, DoG+PatchMatch/LaMa nhỏ), Trang điểm/Tóc (Phase 5) — không có gì mới cần
  nghiên cứu thêm, đúng như HANDOFF §2.2 mục 3/6 đã ghi. Mụn có thêm một ghi chú lịch: nếu Cọ mask (Phase 6.1) đã
  xong trước khi Phase 5 bắt đầu thì "brush heal/clone" của Mụn nên tái dùng thẳng, không dựng brush riêng.
- **Mẫu (templates)/Looks chuyển hẳn vào Phase 3** (không phải Phase 6) — về bản chất là UI cho `RPCore.Preset` đã
  có sẵn CRUD theo-project trong `ProjectStore` (`presets/` bundle). Việc thêm: kho preset **dựng sẵn** (bundle
  resource, "Cho bạn"), kho preset **toàn cục ngoài project** cho "Của tôi" (project chưa có, chỉ có theo-từng-
  project — thêm một store nhỏ tái dùng nguyên `Preset`/`AtomicFileWriter`, rỗi Application Support/app container),
  và favorites (`Set<PresetID>` hoặc field bool). Hai việc này rẻ, không phải thuật toán mới.
- **Share Extension là Phase 3B mới**, chạy song song Phase 3 (không đụng file chung), chi tiết dưới.
- **Phase 6 viết lại theo tầng phụ thuộc** (6.0 spike → 6.1 hạ tầng dùng chung → 6.2 việc rẻ độc lập → 6.3 phụ
  thuộc 6.1 → 6.4 phụ thuộc spike 6.0 → 6.5 Tự động, phụ thuộc Phase 3 xong).
- **2 câu hỏi cần user chốt trước khi giao việc cho coder** (không tự đoán, xem "Cần quyết định" cuối §Phase 6):
  Tự động (công thức one-tap), Looks "Cho bạn" (personalization thật hay danh sách tĩnh).
- **1 câu hỏi cũ đã tự giải quyết được, không cần hỏi lại**: tên project tự tạo khi vào từ Share Extension
  (HANDOFF §4.1 mục 3) — dự án đã có sẵn `ProjectLibrary.suggestedProjectName()` (`Packages/RPUI/Sources/RPUI/
  Model/ProjectLibrary.swift:149`, format `"Shoot yyyy-MM-dd"`, dùng khi tạo project rỗng từ UI hiện tại) — dùng
  lại đúng hàm đó cho nhất quán, không phát minh format mới.

**Cập nhật lần 2 (2026-09-11, cùng ngày):** user quyết định **loại bỏ hẳn "Xoá vật thể" khỏi phạm vi** (không
phải khoá — cắt hẳn) và **chốt luôn nghĩa của "Sửa da"**, giải quyết 1 trong 3 câu hỏi treo ở trên. Chi tiết ở
đúng vị trí của từng mục trong §Phase 6 bên dưới (đã sửa trực tiếp, không viết đè bằng block riêng); code cũng
đã sửa theo (`RailLayout.swift`/`RailLayoutTests.swift`/`docs/design/SPEC.md` — rail còn **18 mục**, 12 khoá,
không còn "Xoá vật thể"; `Packages/RPUI` 114 test xanh). Tóm tắt lý do:
- **Xoá vật thể — cắt:** lý do user đưa ra — pipeline nhận diện của dự án (Vision → BlazeFace → mesh 478 điểm →
  BiSeNet parsing) là **nhận diện khuôn mặt**, không giúp được gì cho việc chọn/xoá một vật thể bất kỳ trong
  khung hình. Đúng: research đã xác nhận việc này cần dựng cả 1 hạ tầng riêng (cọ chọn vùng tự do + LaMa
  crop/resize/blend) không tái dùng được gì từ face pipeline hiện có — khác hẳn Mụn (Phase 5), vốn vẫn dùng LaMa
  nhưng cho **vùng mụn được detect tự động trong mask da đã biết**, không phải chọn tự do. Mụn không bị ảnh
  hưởng bởi quyết định này.
- **Sửa da — chốt nghĩa:** không phải tool sửa đốm cục bộ, mà là **đồng bộ hiệu ứng da từ mặt ra toàn thân**. Lý
  do user đưa ra: các slider Da hiện có (Mịn da, Đều màu da…) chỉ tác động trong mask khuôn mặt (từ BiSeNet, chỉ
  chạy trên crop quanh mặt) — với ảnh chân dung kiểu beauty, da mặt được làm mịn/đều màu trong khi da cổ/vai/tay
  lộ ra trong khung vẫn giữ nguyên, tạo ra sự lệch chi tiết nhìn giả. Kỹ thuật cụ thể ở bảng 6.2 bên dưới.

**Cập nhật lần 3 (2026-09-11, cùng ngày):** cả 2 câu hỏi còn treo (Tự động, Looks "Cho bạn") đã được chốt qua
trao đổi trực tiếp, cộng 1 ý mới của user mở rộng "Tự động" thành 2 giai đoạn. Không còn câu hỏi mở nào chặn
việc giao task cho coder — mục "Cần quyết định" ở cuối §Phase 6 giữ lại làm log quyết định, không còn mục nào
đang chờ. Tóm tắt:
- **Tự động v1 — chốt công thức**: không đụng nhóm Mặt (đúng đề xuất — rủi ro warp sai tỉ lệ), chỉ Da + Color
  (+ Mắt nhẹ), dùng nguyên công thức khởi đầu đã đề xuất (Mịn da 30, Đều màu da 20, Sáng mắt 15, Auto D&B 40)
  làm mặc định v1. Có thêm **1 slider cường độ tổng** sau khi áp — kéo giảm/tăng toàn bộ combo thay vì phải vào
  từng slider riêng. Chi tiết ở 6.5.
- **Looks/Mẫu "Cho bạn" — chốt: danh sách tĩnh cho v1, đổi tên tab** thành "Nổi bật" (tên trung tính khác cũng
  được, miễn không hứa hẹn cá nhân hoá mà v1 không làm) — áp dụng cho cả 2 màn Mẫu và Looks.
- **Ý mới của user — "Tự động v2": cá nhân hoá theo khuôn mặt đã nhận diện.** Thay vì cá nhân hoá kiểu gu-chung
  (nearest-neighbor theo lịch sử preset, phương án (b) cũ đã bỏ), user đề xuất cụ thể hơn và hay hơn: nếu khuôn
  mặt trong ảnh đang sửa **trùng với một khuôn mặt đã từng được chỉnh trước đó** (nhận diện qua nhiều ảnh khác
  nhau, không chỉ trong 1 project), thì khi bấm "Tự động" có thể áp **trung bình các thông số đã dùng cho đúng
  khuôn mặt đó**, lưu local. Đây là tính năng mới, nặng hơn nhiều so với những gì đã research — cần model
  **face embedding/re-identification** hoàn toàn mới (pipeline hiện có chỉ detect + landmark + parsing, không
  nhận diện danh tính), viết thành spike riêng (**S6**) trước khi cam kết effort, tách thành mục **6.6** chạy
  sau "Tự động v1" chứ không chặn v1. Chính sách đã chốt: khi nhận diện khớp, **gợi ý cho user xác nhận, không
  tự áp im lặng** — an toàn hơn vì model nhận nhầm người là rủi ro thật (áp sai thông số cho người lạ), đặc biệt
  khi chưa có đủ số liệu tin cậy từ sử dụng thật. Chi tiết kỹ thuật ở 6.6.

### Phase 3 — Preset, Batch, Export (2 tuần + ~3-4 ngày cho Mẫu/Looks)
- Preset theo nhóm (Da/Mặt/Color…), thư viện, áp cho ảnh chọn / cả project, **auto-apply mọi ảnh mới vào project** (kể cả từ FolderWatcher/MTP).
- `BatchQueue` export nền, giới hạn theo GPU memory, thermal-aware trên iPhone.
- Export JPEG/HEIF/TIFF 8/16‑bit, profile, resize, sharpen sau resize, naming template, về Files/Photos/Share.
- **Bàn giao workflow đầy đủ (chưa tether)**: chụp → cắm máy/thẻ → ảnh vào project → tấm đầu chỉnh → lock preset → các tấm sau tự áp → export hàng loạt.
- **Mới (2026-09-11): dùng lại UI rail "Mẫu" đã khoá (`RailLayout`, id `templates`) làm màn preset thay vì xây UI
  preset riêng** — đúng gợi ý cũ ở HANDOFF §2.2 mục 1. Ba việc thêm, đều là CRUD/plumbing không phải thuật toán:
  (a) kho preset dựng sẵn (tab **"Nổi bật"** — đổi tên từ "Cho bạn" của mockup, chốt 2026-09-11, xem "Cập nhật
  lần 3" ở trên: danh sách tĩnh cho v1, không hứa hẹn cá nhân hoá bằng tên tab): `Preset` JSON đóng gói sẵn
  trong app bundle, decode read-only lúc khởi động; (b) kho preset toàn cục ngoài project ("Của tôi"): store
  mới nhỏ, tái dùng nguyên `Preset`/`AtomicFileWriter` của `ProjectStore` nhưng gốc ở Application Support
  (macOS) / app container (iOS) thay vì trong một `.rpproj`, vì preset "của tôi" phải dùng được xuyên project
  trong khi `ProjectStore.savePreset` hiện chỉ ghi vào đúng 1 project; (c) "Yêu thích": `Set<PresetID>` cờ
  riêng hoặc field bool trên `Preset`.
  "Looks/AI Retouch picker" (5 preset màu Gốc/Tự nhiên/Normcore/Sữa/Điện ảnh) dùng chung đúng cơ chế (a), chỉ khác
  tab hiển thị (cùng đổi tên "Cho bạn" → "Nổi bật") và giới hạn `sections` còn mỗi `color` khi tạo bằng
  `Preset.init(from:limitedTo:)` (hàm đã có). Cá nhân hoá thật cho tab này — không làm ở v1, xem "Tự động v2"
  (§Phase 6.6) cho hướng cá nhân hoá thật sự user muốn (theo khuôn mặt nhận diện, không phải theo gu-chung).

### Phase 3B — Share Extension "Mở với RetouchPro" (~1.5–2 tuần, chạy song song Phase 3)

Hướng kỹ thuật và UX đích **đã chốt với user** (`docs/HANDOFF-remaining-features-2026-09-10.md` §4.1) — phần dưới
là chi tiết kỹ thuật xác nhận lại qua research, không phải quyết định mới cần hỏi. Không phụ thuộc RenderGraph/
Vision nên làm song song Phase 3 được, không đụng file nào Phase 3/6 đụng tới.

1. **Xcode**: thêm 1 target Share Extension mới (**chỉ iOS/iPhone** — iPadOS đã loại khỏi phạm vi §0.2, và Share
   Extension từ Photos.app trên macOS cũng không phải nhu cầu ở đây, `App/RetouchPro-macOS.entitlements` không
   đổi). `NSExtensionActivationRule` lọc ảnh qua `NSExtensionActivationSupportsImageWithMaxCount = 1`.
2. **App Group** `group.com.duynguyen.RetouchPro...` — thêm `com.apple.security.application-groups` vào đúng 2
   nơi: `App/RetouchPro.entitlements` (target iOS chính, hiện **chưa có** key này — đã đọc trực tiếp file xác
   nhận) và entitlements riêng của target extension mới. Container chung của App Group là chỗ extension ghi tạm
   ảnh trước khi app chính đọc.
3. **Handoff extension → app**: dùng đúng API hỗ trợ chính thức — `NSExtensionContext.open(_:completionHandler:)`
   gọi URL scheme (`retouchpro://open?...`). **Không dùng `NSUserActivity`/Handoff** — đó là cơ chế continuity
   liên-thiết-bị khác hẳn, không phải đường extension→containing-app.
4. **App chính nhận URL**: đi qua đúng `ShotIngestor`/pipeline `.rpproj` sẵn có (tái dùng `PhotosImporter`/ingest
   code hiện tại, không viết đường ingest riêng) → tạo project mới, tên = `ProjectLibrary.suggestedProjectName()`
   (đã có sẵn, xem mục "1 câu hỏi cũ đã tự giải quyết được" ở trên) → điều hướng thẳng `EditorView` với shot đó đã
   chọn — cần route mới ở `RetouchProRootView`/`EditorModel` cho cả 2 case: cold-start và app đang chạy nền.
5. **Test — không dùng được `devicectl process launch` như các task khác** (Share Extension không có bundle ID
   launch độc lập, chỉ được người dùng gọi từ Share Sheet của app khác). Hai đường: (a) thủ công — cài qua
   `devicectl install app` như thường, người test tự mở Photos → Share → chọn RetouchPro; (b) tự động — thêm
   **1 target XCUITest mới** (project hiện **chưa có** UI test target nào) lái `XCUIApplication` mở host app
   (Photos hoặc host test riêng) → trigger share sheet → tap icon RetouchPro, chạy được cả Simulator lẫn máy thật
   qua `xcodebuild test`. Việc "vào thẳng editor, cold-start lẫn app đang chạy nền" nên có test XCUITest riêng
   cho từng case, đúng yêu cầu ở HANDOFF §4.1 mục 5.
6. Không có số đo "measure before ship" (không phải thuật toán mask/landmark) nhưng **cần một pass `reviewer`
   độc lập** theo policy mới (`.claude/agents/reviewer.md`): đây là bề mặt entitlement/data-sharing, nằm đúng
   trong danh sách "luôn review" dù không phải render code.

### Phase 4 — Tethered import (3 tuần, có spike go/no‑go riêng ở đầu phase)
- **Spike T1 (Mac)**: Swift CLI `IOUSBHost` + Sony handshake, bấm chụp body → nhận `0xC201` → `GetObject`. Pass: 20 tấm liên tiếp không mất, < 4 s/tấm, ghi log USB làm fixture. Xác minh: ảnh còn trên thẻ không, RAW+JPEG về đủ không, timeout idle.
- Nếu T1 pass: `PTPStack` + `IOUSBHostTransport`, `CaptureView` trên Mac (trạng thái kết nối, đếm ảnh, auto-preset). Ghi file atomic + fsync, không xoá gì trên máy.
- Test: replay fixture USB trong unit test; test thật 200 tấm.

### Phase 5 — Makeup, Heal, Hair v1 (3 tuần)
- Makeup sliders; xoá mụn auto + brush heal/clone; hair: bóng, tối/sáng, đổi màu.

### Phase 6 — Nâng cao (viết lại 2026-09-11, theo thứ tự phụ thuộc)

Base cũ (Tóc con bay/flyaway hair qua LaMa, background clean, Canon/Nikon trong PTPStack, iCloud sync) giữ
nguyên, không nghiên cứu lại lần này. Phần mới là 13 mục rail khoá từ turn 3 (`docs/HANDOFF-remaining-
features-2026-09-10.md` §2.2) — viết theo **tầng phụ thuộc** thay vì danh sách phẳng, vì một nửa số mục chỉ làm
được sau khi hạ tầng dùng chung xong.

**6.0 — Spike go/no-go cho nhóm body reshape (S5, ~1.5 tuần, làm trước 6.4)**

Giống mẫu spike T1 của Phase 4: đo trước khi cam kết effort. Câu hỏi: cơ thể chỉ có ~19-21 khớp thưa từ
`VNDetectHumanBodyPoseRequest` (2D, iOS 14+) / `VNDetectHumanBodyPose3DRequest` (3D mét, iOS 17+) — so với 478
điểm dày của `FaceReshape` — có đủ làm control point cho MLS warp cơ thể không, hay bắt buộc cần mesh cơ thể
dày kiểu SMPL (không có đường convert on-device sẵn có, sẽ là một dự án model-conversion mới ngang hoặc nặng
hơn S1/S2). Hướng đo: `VNGeneratePersonSegmentationRequest` lấy silhouette → dò biên (`VNContoursRequest` hoặc
trace Metal/CPU) → gắn control point MLS dọc biên đó thay vì chỉ tại khớp → so lệch với ground-truth thủ công
trên vài ảnh thật. Pass: warp không tạo méo/blob ở vùng giữa hai khớp liền kề. Fail: ghi rõ lý do, xuống thang
độ tham vọng của 6.4 (xem dưới) thay vì cố làm tiếp không đo.

**6.1 — Hạ tầng dùng chung (làm trước mọi tool cần vùng chọn cục bộ)**

| Hạng mục | Mục tiêu | Kỹ thuật | Effort |
|---|---|---|---|
| Cọ mask thủ công | Vẽ/xoá 1 mask cục bộ (brush add/subtract) rồi áp slider chỉ trong vùng đó — tiền đề bắt buộc của "brush heal/clone" trong Mụn (Phase 5) và mọi "chế độ Thủ công" sau này | Stroke = vector `(điểm, áp lực)`, KHÔNG dùng PencilKit (`PKCanvasView` không hợp mục đích mask, mutate `PKStroke` phá `UndoManager` theo tài liệu Apple) — tự bắt `UITouch`/`NSEvent`, rasterize bằng compute shader (splat tròn mềm, falloff) vào texture `r8Unorm` ngoài màn hình, add/subtract là cờ blend-mode của kernel. Undo = replay lại danh sách stroke từ đầu (rẻ ở độ phân giải mask, không cần snapshot texture). Gate node hiện có bằng đúng pattern `MaskRasteriser`/`RenderMaskKind` đã có từ ADR-0009 (nhân mask vào coverage trước khi composite) — không phải kỹ thuật mới, chỉ thêm 1 nguồn mask nữa. Lưu trữ: **không** nhét bitmap vào `EditState` JSON — theo đúng quy ước Lightroom/Photoshop, ghi PNG nén vào `masks/<shot id>/<mask id>.png` (thêm subfolder mới cạnh `originals/previews/edits/presets` trong `.rpproj`), `EditState.perImage` chỉ giữ id tham chiếu (đúng namespace hiện có cho dữ liệu theo-ảnh, không transfer qua preset). | ~1.5-2 tuần |
| Khoá nền (background lock) | Chặn hiệu ứng lan ra nền, cần subject mask | `VNGeneratePersonSegmentationRequest` (iOS 15+/macOS 12+) — khác hẳn pipeline BiSeNet/BlazeFace hiện có của RPVision (bài toán foreground/background, không phải face parsing), dùng thẳng request có sẵn của Vision, không cần convert model mới. `qualityLevel` `.fast`/`.balanced`/`.accurate` — Apple khuyến nghị `.fast` cho tương tác, `.accurate` có độ trễ đáng kể; **chưa có số đo trên A-series/iPhone**, phải bench như mọi node khác trước khi bật mặc định. Output alpha mask gate y hệt pattern `MaskRasteriser`. Có thể làm **trước** cọ mask vì đơn giản hơn (không cần input vẽ tay) và tự nó validate luôn con đường "mask ngoài-mặt gate node" mà cọ mask cũng cần. | ~0.5-1 tuần |

**6.2 — Việc rẻ, không phụ thuộc 6.1 (làm sớm được, song song 6.0/6.1)**

| Hạng mục | Mục tiêu | Kỹ thuật | Effort |
|---|---|---|---|
| Tạo khối (Contour) | Tô sáng/tối theo khối mặt (gò má, sống mũi, hàm) theo mesh, không toàn khung | Xác nhận đúng hướng đã đoán ở HANDOFF: `ColorRenderNode` hiện tại của Auto D&B **đã global, chưa mask** (đọc code xác nhận). Chỉ cần thêm: vài mask ellipse/radial mềm neo tại index landmark 478 điểm sẵn có (tam giác gò má dưới mắt, đường sống mũi qua `tNasion`/`tNoseTip` `FaceReshape` đã tính, dải hàm theo oval mặt), rồi nhân mask đó vào đúng công thức dodge/burn LUT đã có. Không landmark mới, không model mới, không kernel Metal họ mới. | ~0.5 tuần |
| Đầu (Head reshape) | Warp cả khung đầu/viền tóc, không chỉ landmark mặt | Vision không có API viền đầu/tóc riêng, nhưng RPVision **đã có** — `FaceParsingClass.hair`/`FaceParsingGroup.hair` từ BiSeNet (ADR-0006/S2). Dò biên ngoài của mask tóc (`VNContoursRequest` hoặc trace CPU/Metal) làm control point MLS thêm, kết hợp mở rộng vòng oval mặt (478 điểm) ra ngoài theo tỉ lệ neo vào biên tóc đó — cùng họ với `FaceReshape` (identity handle + vùng trọng số) hơn là một bài toán model mới. Cần vòng đo mới kiểu ADR-0010 (chưa có ground-truth viền tóc trên ảnh a6300 thật). | ~1.5 tuần |
| **Sửa da — đồng bộ da toàn thân** (nghĩa chốt 2026-09-11) | **Không phải bộ slider mới.** Mở rộng đúng 8 slider Da hiện có (Mịn da, Giữ texture, Đều màu da, Khử đỏ, Khử bóng dầu, Sáng da, Quầng thâm, Nếp nhăn) từ mask-chỉ-trong-mặt ra một mask da-toàn-thân, dùng **cùng giá trị** người dùng đã chỉnh cho mặt — để da cổ/vai/tay lộ trong khung không bị lệch tông/độ mịn so với mặt vừa beauty. | Mask da hiện có (BiSeNet, ADR-0006) chỉ chạy trên **crop quanh mặt**, không phủ toàn khung — cần một mask "da" full-frame mới, khác nguồn. Rẻ nhất, không cần model mới: **skin-color classification cổ điển** (ngưỡng theo không gian màu YCbCr/HSV, kỹ thuật CV kinh điển, không phải deep learning) chạy toàn ảnh; đo IoU trên bộ ảnh test nhiều tông da khác nhau trước khi ship, đúng "measure before ship" (giống phương pháp đo của S2). Có thể **cộng thêm** (không bắt buộc) `VNGeneratePersonSegmentationRequest` (Khoá nền, 6.1) để loại false-positive nền màu da (gỗ, cát, tường be) — v1 ship được chỉ với ngưỡng màu, v2 cộng segmentation khi 6.1 xong. Mask da-toàn-thân và mask da-mặt (BiSeNet) phải **hợp nhất mượt** (feather ở cổ) để không lộ đường biên hai mask ráp lại. Wrinkle kiến trúc đáng ghi chú: `SkinRenderNode` hôm nay chỉ nhận mask **theo từng mặt** (`FaceRenderInput`/seam `faces`), còn mask da-toàn-thân là **whole-frame, không theo mặt** — cần mở seam để node nhận thêm 1 mask phụ whole-frame, hợp nhất trước khi dispatch (không phải viết kernel mới, `SkinRenderNode`'s kernel đã đo 79 dB, chỉ đổi input mask). UI: một toggle (không phải panel slider riêng) — chi tiết UI chốt lúc build. | ~1-1.5 tuần, không phụ thuộc 6.1 (Khoá nền là nâng cấp tuỳ chọn, không chặn) |

**Trạng thái 6.2 — Tạo khối (cập nhật 2026-09-21): engine xong + đã có UI, cờ vẫn tắt.**
- **Engine (đã merge, `docs/ADR-0020-contour-sliders.md`)**: 3 slider `contourCheek`/`contourNose`/`contourJaw`
  (0–100, mặc định 0, nằm trong `EditState.SectionKey.face` nên **transfer qua preset**), 11 lobe ellipse mềm
  neo theo mesh 478 điểm, nhân thẳng vào bước dodge/burn LUT sẵn có trong `ColorRenderNode` — không node mới,
  không kernel họ mới. Số đã đo: golden GPU-vs-CPU **162.98 dB**, vùng không thuộc slider đổi **đúng 0**, phủ
  **10.4%** khung (không toàn khung), chi phí biên **0.75 ms** ở preview 2048 px / **3.94 ms** ở 24 MP (Mac M1 Pro).
- **UI (2026-09-21, đợt này)**: rail item "Tạo khối" (con của "Mặt") nay trỏ vào panel riêng
  `SliderPanelLayout.PanelKey.contour` — panel **thứ ba** trên namespace `face`, cạnh "Hình dáng mặt" (15 slider
  warp), với 3 nhãn "Gò má" · "Sống mũi" · "Hàm". UI-only: `EditState`/`Slider`/`FaceSliders`/render node không đổi.
- **`RPEngineFeatureFlags.contourSliders` vẫn mặc định tắt** (thiếu số đo trên iPhone thật, đúng luật
  measure-before-ship). Trong bản dựng cờ tắt: rail item **không khoá**, panel mở được và vẽ đủ 3 slider, nhưng
  nhóm bị disable kèm một câu lý do (`PanelFeatureGate.contourSliders` → `GroupAvailability.blockedReason`) —
  đúng cách panel đã báo "không nhận diện được khuôn mặt", không phải lock kiểu Phase 5. Bật cờ sau này là một
  dòng, không phải một đợt UI. Không có "detection notice" riêng cho Tạo khối: nó là hình học landmark thuần,
  không có gì để *nhận diện hỏng* ngoài chính khuôn mặt.

**6.3 — Phụ thuộc 6.1**

| Hạng mục | Mục tiêu | Kỹ thuật | Effort |
|---|---|---|---|
| Săn chắc (Firm) | Hiệu ứng săn chắc da tay/chân, khả năng cao là **không hình học** | Local-contrast/dodge-burn trên da chi, giống Contour/Auto D&B hơn là warp — cần mask vùng chi, tái dùng silhouette từ Khoá nền (6.1) thay vì tự phân vùng lại. Không cần đợi spike 6.0 vì không đụng hình học. | ~0.5-1 tuần, phụ thuộc Khoá nền |

**Đã cắt khỏi phạm vi (2026-09-11): Xoá vật thể (Object removal).** Quyết định của user — pipeline nhận diện
hiện có của dự án là nhận diện **khuôn mặt** (Vision → BlazeFace → mesh 478 điểm → BiSeNet), không giúp được gì
cho việc chọn/xoá vật thể bất kỳ trong khung; mở rộng LaMa sang "vùng tự do người dùng chọn" sẽ cần dựng nguyên
1 hạ tầng crop/resize/blend + validate-bằng-QA-không-PSNR mới toanh, không tái dùng được gì từ face pipeline —
khác hẳn Mụn (Phase 5) vẫn giữ LaMa nhưng cho vùng mụn **tự động detect trong mask da đã biết**, không phải
chọn tự do; Mụn không bị ảnh hưởng. Không còn là rail item (`RailLayout.swift`), không còn trong SPEC.md.

**6.4 — Phụ thuộc spike 6.0**

| Hạng mục | Mục tiêu | Nếu spike 6.0 go | Nếu spike 6.0 no-go |
|---|---|---|---|
| Thu gọn (slim), Cơ thể (body) | Warp hình học vùng eo/thân | MLS neo theo biên silhouette (kỹ thuật đo ở 6.0), ~2-3 tuần/mục | Giảm phạm vi xuống warp đơn giản quanh 1 bounding-box (kém chính xác hơn nhiều, cần user chấp nhận đánh đổi) hoặc hoãn vô thời hạn — **ghi lại quyết định, không tự chọn nhánh** |
| Căng mọng (plump) | Phóng to cục bộ (ngực/hông) quanh khớp cơ thể | Cùng cơ chế MLS silhouette-anchored, ~2-3 tuần | Cùng đánh đổi như trên |

**6.5 — Tự động v1 (one-tap auto retouch, công thức cố định)**

Phụ thuộc Phase 3 (Preset UI) xong. **Công thức chốt 2026-09-11** (xem "Cập nhật lần 3" đầu §Phase 6): không
đụng nhóm Mặt (an toàn — warp hình học sai tỉ lệ dễ bị chê hơn nhiều so với chỉnh da/màu quá tay, và có thể
chỉnh lại bằng slider thường), chỉ Da + Color (+ Mắt nhẹ) — **Mịn da 30, Đều màu da 20, Sáng mắt 15, Auto D&B
40** là mặc định v1. Kỹ thuật: áp 1 `Preset` cố định qua `EditState.applying(_:mode:)` đã có sẵn
(`RPCore/Preset.swift`) — không phải render mới. Cộng thêm **1 slider "cường độ tổng"** (chốt cùng lúc): sau
khi áp công thức mặc định, 1 thanh trượt riêng scale toàn bộ combo lên/xuống thay vì user phải vào từng slider
— kỹ thuật là nhân hệ số scale [0,1] vào từng giá trị trong `Preset` trước khi `applying`, không phải slider
mới trong `EditState` (không lưu riêng, tính lại mỗi lần user kéo). Effort kỹ thuật ~2-3 ngày.

**6.6 — Tự động v2: cá nhân hoá theo khuôn mặt đã nhận diện (mới, đề xuất 2026-09-11)**

Ý của user: nếu khuôn mặt trong ảnh đang sửa **trùng với một khuôn mặt đã từng được chỉnh trước đó** (nhận
diện qua nhiều ảnh khác nhau, không giới hạn trong 1 project), "Tự động" nên **gợi ý áp trung bình các thông số
đã dùng cho đúng khuôn mặt đó**, lưu local — khác hẳn cá nhân hoá kiểu "gu chung" (nearest-neighbor theo lịch
sử preset nói chung) đã cân nhắc trước đó cho tab Looks/Mẫu, và **hay hơn** vì đúng ngữ cảnh "chỉnh ảnh cho
khách quen" của 1 app photographer. Phụ thuộc 6.5 (dùng chung cơ chế áp Preset) và cần 1 spike mới trước khi cam
kết effort, vì đây là bài toán khác hẳn mọi thứ pipeline hiện có:

- **Cần model mới: face embedding / re-identification.** Pipeline hiện có (Vision → BlazeFace → mesh 478 điểm
  → BiSeNet parsing) chỉ **detect** (tìm mặt, landmark, phân vùng) chứ không **nhận diện danh tính** (đây là
  mặt của ai). Apple Vision không có API công khai cho việc này (Photos app có "People" nội bộ, không public).
  Cần convert 1 model embedding nhỏ gọn (kiểu ArcFace/MobileFaceNet — biến 1 crop khuôn mặt thành 1 vector,
  cùng người thì vector gần nhau theo cosine similarity) sang Core ML, đúng quy trình `coremltools` đã dùng cho
  BlazeFace/landmark/parsing.
- **Spike S6 (~1.5-2 tuần, go/no-go trước 6.6, giống mẫu S1/spike 6.0):** đo **false-accept rate** (nhận nhầm 2
  người khác nhau là 1 — rủi ro chính, vì áp sai thông số cho người lạ là lỗi rất dễ bị phát hiện, mất uy tín
  1 app ảnh chuyên nghiệp) và false-reject rate trên ảnh thật. **Rủi ro logistics cần lường trước**: bộ ảnh test
  hiện có (`Research/data/`) nhiều khả năng chưa có đủ "cùng 1 người, nhiều ảnh/buổi chụp khác nhau" để đo —
  khác spike 6.0 (chỉ cần ảnh người bất kỳ) hoặc S1/S2 (so với ground-truth công khai) — có thể cần user chụp/
  cung cấp thêm ảnh test trước khi chạy spike này.
- **Lưu trữ**: kho danh tính (embedding centroid + trung bình trượt các thông số Da/Color đã dùng cho danh tính
  đó) phải ở **ngoài project** (giống store "Của tôi" ở Phase 3, vì 1 người có thể xuất hiện ở nhiều project/
  buổi chụp khác nhau) — Application Support (macOS) / app container (iOS), không phải trong `.rpproj`.
- **Chính sách đã chốt (2026-09-11): gợi ý, không tự áp im lặng.** Khi khớp danh tính đạt ngưỡng tin cậy, hiện
  gợi ý (preview + nút xác nhận) thay vì tự động áp — giảm hậu quả của 1 lần nhận nhầm xuống "user bấm bỏ qua"
  thay vì "âm thầm áp sai thông số". Có thể nới sang tự áp khi đã có đủ số liệu tin cậy thật từ sử dụng, nhưng
  đó là quyết định của một lần sau, không phải v2.
- Effort: ~1.5-2 tuần spike (S6) + ~1-1.5 tuần nối vào "Tự động" (kho danh tính, matching, UI gợi ý/xác nhận)
  nếu spike go ≈ **~3-3.5 tuần**, tách hẳn khỏi 6.5 nên không chặn "Tự động v1" ra mắt trước.

### Cần quyết định — log quyết định (không còn câu hỏi mở, xem "Cập nhật lần 3" đầu §Phase 6)

Toàn bộ câu hỏi mở của bản plan trước (Sửa da, Tự động, Looks "Cho bạn") đã được chốt qua trao đổi 2026-09-11 —
xem "Cập nhật lần 2"/"Cập nhật lần 3" ở đầu §Phase 6 và các mục 6.2/6.5/6.6 tương ứng. Mục này giữ lại làm log,
không còn gì đang chờ; câu hỏi mở duy nhất còn lại trong toàn bộ Phase 6 là kết quả **spike S6** (6.6) và
**spike 6.0** (body reshape) — cả hai là việc *đo*, không phải việc *hỏi*.

Ước lượng Phase 0–3: **~8 tuần** (+ ~3-4 ngày Mẫu/Looks trong Phase 3); Phase 3B (Share Extension): **+1.5-2
tuần**, song song Phase 3; Phase 4: +3 tuần; Phase 6 (turn-3 phần mới, không tính base cũ, Xoá vật thể đã cắt):
**6.0 spike ~1.5 tuần + 6.1 ~2-3 tuần + 6.2 ~3-3.5 tuần (Tạo khối + Đầu + Sửa da) + 6.3 ~0.5-1 tuần (Săn chắc) +
6.4 ~4-6 tuần nếu spike 6.0 go + 6.5 ~2-3 ngày + 6.6 ~3-3.5 tuần nếu spike S6 go ≈ 15-19.5 tuần tuỳ kết quả 2
spike** — số này để chèn timeline tổng, không phải cam kết cứng.

---

## 4. User cần chuẩn bị
1. Cáp/adapter: micro‑USB → Lightning/USB‑C (tuỳ iPad) hoặc card reader; cho Mac: micro‑USB → USB‑C.
2. 10–20 ảnh chân dung thật từ a6300 (JPEG + ARW) cho golden/ground-truth, để vào `Research/data/`.
3. Apple ID có trong Xcode để ký Development (chạy local trên iPad thật; free account đủ, app hết hạn 7 ngày phải build lại; paid account 1 năm).
4. Phase 4: a6300 set USB = PC Remote, pin đầy (PC Remote không sạc qua USB), bật Smart Remote Embedded nếu test Wi‑Fi.

---

## 5. Verification
- `xcodebuild test -workspace RetouchPro.xcworkspace -scheme RetouchPro -destination 'platform=macOS'` và
  `xcodebuild test -workspace RetouchPro.xcworkspace -scheme RetouchPro -destination 'platform=iOS Simulator,name=iPhone 17'`
  xanh mỗi phase; hoặc `Scripts/test.sh all`. **`-workspace` là bắt buộc**: với `-project RetouchPro.xcodeproj`,
  xcodebuild bỏ hết test target của local Swift package và báo "There are no test bundles available to test"
  (docs/ADR-0001). Chạy thật trên iPhone của user cho bench.
- Golden render PSNR, eval mask/landmark IoU có control, bench ms/frame và s/ảnh → ghi `Research/bench/*.json`, không đọc screenshot.
- Phase 3: screen-record workflow import → preset → auto-apply → export trên iPhone thật.
- Phase 4: `PTPStack` test bằng fixture replay; test thật 200 tấm trên Mac, log số tấm nhận/mất.
- Log app tại `~/Library/Containers/<bundle>/Data/Library/Logs/RetouchPro/`.

## 6. Nguồn
- IOUSBHost chỉ macOS/Catalyst: https://developer.apple.com/documentation/iousbhost
- USBDriverKit chỉ iPad M‑series: https://developer.apple.com/documentation/usbdriverkit ; WWDC22 https://developer.apple.com/videos/play/wwdc2022/110373/
- iOS chặn vendor PTP qua ImageCaptureCore: https://developer.apple.com/forums/thread/656878
- libgphoto2 a6300: https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/cameras/sony-a6300.txt ; timeout bug https://sourceforge.net/p/gphoto/bugs/1038/
- PC Remote kẹt "Connecting" nếu không handshake: https://docodethatmatters.com/hacking-sony-a6000-for-modernization/
- Rocc (Sony Wi‑Fi, MIT): https://github.com/simonmitchell/rocc
- Cascable a6300 (dự phòng): https://compatibility.cascable.se/sony/a6300/
- MediaPipe Face Landmarker: https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker
- Face parsing → Core ML: https://github.com/zllrunning/face-parsing.PyTorch/issues/27
- LaMa Core ML: https://github.com/john-rocky/lama-cleaner-iOS
- Evoto features: https://shotkit.com/evoto-ai-review/

**Thêm (2026-09-11), nghiên cứu Phase 6 chi tiết + Share Extension:**
- Vision person segmentation: https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest ,
  quality levels: https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest/qualitylevel
- Vision person instance mask (multi-person, iOS 17+): https://developer.apple.com/documentation/vision/vngeneratepersoninstancemaskrequest?language=objc
- Vision body pose 3D (iOS 17+), WWDC23 "Explore 3D body pose and person segmentation in Vision"
- LaMa project/paper (FFC, image-wide receptive field claim): https://advimman.github.io/lama-project/
- App Extension Programming Guide — Share: Apple Developer Documentation
- App Groups entitlement (`com.apple.security.application-groups`): Apple Developer Documentation
- `NSExtensionActivationSupportsImageWithMaxCount`: Apple Developer Documentation
- Share Extension UI testing pattern (XCUITest driving the system share sheet): SwiftLee, "Share Extension UI Tests
  written in Swift"
