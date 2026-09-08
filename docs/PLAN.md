# Retouch Pro App — Plan macOS + iPadOS/iOS (slider retouch, preset, batch; tethering ở phase sau)

## Context

Hôm qua (03/09/2026) đã xong **Retouch Pro panel UXP cho Photoshop** tại
`/Users/duynguyen/Documents/Claude/Projects/panelpts`. Hôm nay làm **app độc lập** cho macOS + iPad/iPhone,
cùng loại Evoto / Xingtu / Meitu:

- Import ảnh từ Files, Photos, thẻ nhớ / máy ảnh cắm USB; sau đó **tethered import** (bấm chụp trên máy → ảnh tự vào app).
- **Project** cho mỗi buổi chụp. Chỉnh tấm đầu → lưu **preset** → các tấm sau tự áp.
- Chỉnh bằng **thanh trượt** (mịn da, mượt tóc, bóp mặt, mắt to, trắng răng…), không phải nút 1‑click.
- **Batch edit** + export hàng loạt.

Đã chốt với user (không hỏi lại):
- **UI theo chuẩn Evoto**: filmstrip trái, canvas giữa, panel slider phải, thanh preset trên.
- **Swift/SwiftUI native**, một codebase macOS + iPadOS + iOS. Không Flutter.
- **AI on-device only**, không server.
- Máy ảnh **Sony a6300** (micro‑USB). iPad đang dùng là **chip A‑series**.
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
  RetouchPro.xcodeproj        1 app target multiplatform (macOS 15+, iPadOS/iOS 18+), ký Development, chạy local
  App/                        entry, DI, scenes
  Packages/
    RPCore/     Project, Shot, EditState (Codable JSON), Preset, ProjectStore (.rpproj bundle)
    RPVision/   FaceAnalyzer: Vision → CoreML 478 landmarks → CoreML face parsing → SkinCore → FaceAnalysis cache
    RPEngine/   RenderGraph Metal+Core Image: Decode → Color → Skin → Warp(MLS) → Eyes/Teeth → Makeup → Output;
                PreviewRenderer, ExportRenderer, BatchQueue
    RPImport/   FilesImporter, PhotosImporter, MTPCameraImporter (ImageCaptureCore: liệt kê + tải file, cả Mac & iPad),
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

### Phase 3 — Preset, Batch, Export (2 tuần)
- Preset theo nhóm (Da/Mặt/Color…), thư viện, áp cho ảnh chọn / cả project, **auto-apply mọi ảnh mới vào project** (kể cả từ FolderWatcher/MTP).
- `BatchQueue` export nền, giới hạn theo GPU memory, thermal-aware trên iPhone.
- Export JPEG/HEIF/TIFF 8/16‑bit, profile, resize, sharpen sau resize, naming template, về Files/Photos/Share.
- **Bàn giao workflow đầy đủ (chưa tether)**: chụp → cắm máy/thẻ → ảnh vào project → tấm đầu chỉnh → lock preset → các tấm sau tự áp → export hàng loạt.

### Phase 4 — Tethered import (3 tuần, có spike go/no‑go riêng ở đầu phase)
- **Spike T1 (Mac)**: Swift CLI `IOUSBHost` + Sony handshake, bấm chụp body → nhận `0xC201` → `GetObject`. Pass: 20 tấm liên tiếp không mất, < 4 s/tấm, ghi log USB làm fixture. Xác minh: ảnh còn trên thẻ không, RAW+JPEG về đủ không, timeout idle.
- Nếu T1 pass: `PTPStack` + `IOUSBHostTransport`, `CaptureView` trên Mac (trạng thái kết nối, đếm ảnh, auto-preset). Ghi file atomic + fsync, không xoá gì trên máy.
- Test: replay fixture USB trong unit test; test thật 200 tấm.

### Phase 5 — Makeup, Heal, Hair v1 (3 tuần)
- Makeup sliders; xoá mụn auto + brush heal/clone; hair: bóng, tối/sáng, đổi màu.

### Phase 6 — Nâng cao (đánh giá lại)
- Tóc con bay (LaMa), body reshape, background clean, Canon/Nikon trong PTPStack, iCloud sync.

Ước lượng Phase 0–3: **~8 tuần**; Phase 4: +3 tuần.

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
