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
| S1 Landmark 478 → Core ML | sai số < 1 px @256 so MediaPipe Python; < 40 ms/face trên iPad A‑series |
| S2 Face parsing BiSeNet → Core ML | IoU skin/hair/eye ≥ 0.85 trên 10 ảnh; < 150 ms trên iPad A‑series |
| S3 Guided filter + MLS warp Metal trên 24 MP | preview 2048 px ≥ 30 fps khi kéo slider trên iPad A‑series; export < 8 s |
| S4 `CIRAWFilter` ARW a6300 | decode < 3 s trên iPad A‑series, 16‑bit |
| S5 ImageCaptureCore MTP import trên iPad | a6300 chế độ MTP cắm iPad qua adapter → liệt kê + tải JPEG/ARW về app |

Kết quả: `Research/spikes/REPORT.md`, chọn model/độ phân giải theo số đo thật.

### Phase 1 — Skeleton + Import + Project (2 tuần)
- Xcode project multiplatform + packages, `xcodebuild test` macOS và iOS Simulator.
- `.rpproj` bundle (originals/, previews/, edits/*.json, presets/).
- Import: Files, Photos (giữ RAW), drag-drop Mac, **MTP camera import** (ImageCaptureCore), **FolderWatcher** (chọn thư mục/card → ảnh mới tự vào project).
- UI khung Evoto: filmstrip (rating/flag), canvas zoom/pan, before/after, panel slider trống.

### Phase 2 — Vision pipeline + Slider cốt lõi (3 tuần)
- `FaceAnalyzer` → `FaceAnalysis` (landmarks, mask skin/hair/eyes/teeth/lips/brows/neck), cache theo hash.
- `RenderGraph` slider 0–100:
  - **Da**: Mịn da, Giữ texture, Đều màu da, Khử đỏ, Khử bóng dầu, Sáng da, Quầng thâm, Nếp nhăn.
  - **Mặt**: Bóp mặt, Gò má, Hàm, Cằm, Trán, Thái dương, Mũi (thu nhỏ/sống/đầu), Mắt (to/khoảng cách/nghiêng), Miệng (to/cười), Môi đầy.
  - **Mắt/Răng**: Sáng mắt, Trắng lòng trắng, Nét mắt, Trắng răng.
  - **Color**: Exposure, Contrast, Highlights, Shadows, WB, Vibrance, Saturation, Curves, HSL, Auto D&B.
- Preview realtime `MTKView`, multi-face chọn trên canvas.
- Golden tests PSNR ≥ 45 dB; bench trên iPad A‑series ghi file.

### Phase 3 — Preset, Batch, Export (2 tuần)
- Preset theo nhóm (Da/Mặt/Color…), thư viện, áp cho ảnh chọn / cả project, **auto-apply mọi ảnh mới vào project** (kể cả từ FolderWatcher/MTP).
- `BatchQueue` export nền, giới hạn theo GPU memory, thermal-aware trên iPad.
- Export JPEG/HEIF/TIFF 8/16‑bit, profile, resize, sharpen sau resize, naming template, về Files/Photos/Share.
- **Bàn giao workflow đầy đủ (chưa tether)**: chụp → cắm máy/thẻ → ảnh vào project → tấm đầu chỉnh → lock preset → các tấm sau tự áp → export hàng loạt.

### Phase 4 — Tethered import (3 tuần, có spike go/no‑go riêng ở đầu phase)
- **Spike T1 (Mac)**: Swift CLI `IOUSBHost` + Sony handshake, bấm chụp body → nhận `0xC201` → `GetObject`. Pass: 20 tấm liên tiếp không mất, < 4 s/tấm, ghi log USB làm fixture. Xác minh: ảnh còn trên thẻ không, RAW+JPEG về đủ không, timeout idle.
- **Spike T2 (iPad Wi‑Fi)**: Rocc + Smart Remote Embedded trên a6300: bấm chụp body có đẩy ảnh, tải được file gốc không.
- Nếu T1 pass: `PTPStack` + `IOUSBHostTransport`, `CaptureView` trên Mac (trạng thái kết nối, đếm ảnh, auto-preset). Ghi file atomic + fsync, không xoá gì trên máy.
- iPad: **Mac làm cầu** (thư mục project chia sẻ qua LAN/iCloud + FolderWatcher đã có từ Phase 1) là đường mặc định; Wi‑Fi trực tiếp nếu T2 pass; CascableCore chỉ khi user muốn cáp thẳng vào iPad A‑series.
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
- `xcodebuild test -scheme RetouchPro -destination 'platform=macOS'` và `-destination 'platform=iOS Simulator,name=iPad (A16)'` xanh mỗi phase; chạy thật trên iPad A‑series của user cho bench.
- Golden render PSNR, eval mask/landmark IoU có control, bench ms/frame và s/ảnh → ghi `Research/bench/*.json`, không đọc screenshot.
- Phase 3: screen-record workflow import → preset → auto-apply → export trên iPad thật.
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
