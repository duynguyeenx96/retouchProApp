# Tổng quan pipeline nhận diện khuôn mặt (Core ML)

Tài liệu tổng hợp, không phải ADR — mục đích là trả lời nhanh "lấy model ở đâu,
train/convert thế nào, lưu kết quả ở đâu, kỹ thuật Core ML gì" mà không phải đọc
lại 6 ADR. Chi tiết đầy đủ + số đo nằm ở các ADR trích dẫn trong từng mục; tài
liệu này không lặp lại số liệu, chỉ dẫn tới nguồn.

Nguồn: `docs/ADR-0005`, `ADR-0006`, `ADR-0007`, `ADR-0008`, `ADR-0013`,
`ADR-0015`, và báo cáo spike `Research/spikes/{S1-landmark,S2-face-parsing,S3-guided-filter-mls}/*.md`.

---

## 1. Không train model nào cả — toàn bộ là convert model có sẵn

Đây là điểm quan trọng nhất: **không có bước training** trong dự án này. Cả 3
model đều là checkpoint public, được convert sang Core ML rồi dùng thẳng
(inference-only, "off-the-shelf"):

| Model | Nguồn gốc | Việc phải làm |
|---|---|---|
| **BlazeFace Short Range** | Google MediaPipe, `blaze_face_short_range.tflite` | Convert TFLite → Core ML |
| **FaceLandmark478** | Google MediaPipe Face Landmarker, `face_landmarks_detector.tflite` | Convert TFLite → Core ML |
| **BiSeNet (face parsing 19 lớp)** | `zllrunning/face-parsing.PyTorch`, checkpoint `79999_iter.pth` train sẵn trên CelebAMask-HQ | Convert PyTorch → Core ML |

Cộng thêm **Apple Vision** (`DetectFaceRectanglesRequest`) — không phải convert
gì, dùng thẳng framework hệ thống, chỉ dùng cho bước dò thô đầu tiên.

Vì không train nên toàn bộ công sức đổ vào: (1) convert đúng số học, (2) đo lại
độ chính xác so với bản gốc, (3) ghép 4 model/framework này thành một pipeline
đủ chính xác cho việc chỉnh ảnh — vốn không phải use-case gốc của từng model
riêng lẻ.

---

## 2. Pipeline 4 giai đoạn (đã chốt ở ADR-0008)

```
stage 1  Apple Vision DetectFaceRectanglesRequest   → box thô, toàn ảnh
stage 2  crop vuông 3.5× box đó → BlazeFace 128px    → box chính xác + eye keypoints
stage 3  MediaPipe ROI (square_long, ×1.5) từ box đó → mesh 478 điểm, 256px
stage 4  crop roll-normalised theo khung CelebA      → parsing 19 lớp, 512px
```

Lý do phải 4 tầng, không rút gọn:
- **BlazeFace không thay được Vision (stage 1)**: chạy trên cả khung 24 MP thì
  *không tìm ra mặt nào* trong 4/11 ảnh test thật (mặt quá nhỏ so với input
  128px của nó).
- **Vision không thay được BlazeFace (stage 2)**: box của Vision lớn hơn
  BlazeFace ~8%, lệch tâm 5.5% cạnh ROI, roll lệch 2.4° — nếu đưa thẳng box này
  vào mesh thì sai số landmark là **1.399 px**, trong khi đi qua BlazeFace trước
  thì còn **0.866 px** (bar của plan là < 1 px). Số đo: ADR-0008 §Decision 2.
- **Parsing cần crop đã xoay theo roll**: nếu không xoay, ảnh mặt nghiêng mạnh
  bị BiSeNet gộp toàn bộ thành một vùng "skin" phẳng, mất hết mắt/mũi/mày. Xoay
  trước thì đúng 10/11 → 11/11 ảnh thật (ADR-0006 §Consequence, ADR-0008 §Decision 3).

---

## 3. Kỹ thuật convert từng model (đây là phần "Core ML" thật sự)

### 3.1 BlazeFace + FaceLandmark478 — đọc thẳng TFLite flatbuffer, tự viết MIL (ADR-0005, ADR-0008)

Không dùng chuỗi converter có sẵn (`tf2onnx → onnx2torch → coremltools`, hay
`tflite2tensorflow`) vì mỗi hop có thể lệch số học và không falsifiable được.
Thay vào đó: `Research/spikes/S1-landmark/convert_tflite_to_coreml.py` (~200
dòng) đọc trực tiếp flatbuffer TFLite bằng thư viện `tflite`, rồi build thẳng
chương trình `coremltools.MIL` — không qua TensorFlow/ONNX/Torch.

Hai chỗ phải can thiệp thủ công ở tầng op (không converter tự động nào làm được):
1. MediaPipe áp sigmoid lên logit *bên ngoài* mạng — converter gộp vào trong
   graph để output là `score` dùng được ngay (0.005 nhiễu, 1.000 có mặt).
2. `PAD` theo trục channel dịch sang `mb.pad` thì model load được trên macOS
   nhưng **crash trên iOS Simulator** (`error code: -7`). Phải emit bằng
   `mb.concat` + khối zero tường minh — cùng kết quả số học, chạy được mọi nơi.

Độ chính xác đo bằng cách so trực tiếp với bản chạy trên **LiteRT interpreter**
gốc, cùng tensor input — không so "bằng mắt": landmark fp32 lệch 3.5e-5 px,
fp16 lệch 0.046 px; BlazeFace fp32 lệch tối đa 2.3e-5 px/box, fp16 0.14 px.

### 3.2 BiSeNet (face parsing) — `torch.jit.trace` → `coremltools`, một hop (ADR-0006)

Nguồn là PyTorch state_dict sẵn nên đường ngắn nhất *cũng là* đường an toàn
nhất: `Research/spikes/S2-face-parsing/convert_bisenet_to_coreml.py` load
module `BiSeNet` gốc (vendor lại trong `vendor/`, giấy phép MIT), trace ở
kích thước 1×3×512×512, đưa thẳng vào `coremltools.convert`.

Hai thứ được gấp *vào trong* graph thay vì làm ở tầng Swift, để Python
reference và Swift client không có cơ hội lệch nhau:
- **Chuẩn hoá ImageNet** (`(x - mean) / std`) — Core ML `ImageType` chỉ hỗ trợ
  1 scale + bias/kênh nên phải viết thêm một lớp `NormalisedBiSeNet` quanh
  model gốc để nhét phép `/std` (per-channel) vào graph.
- **Argmax** — model gốc trả về 19 kênh logit (10 MB/ảnh ở fp16); bọc thêm
  `ArgmaxBiSeNet` để trả thẳng `labels int32 [1,512,512]` (1 MB).

Đo bằng cách so logit giữa bản Core ML và bản PyTorch gốc trên cùng ảnh:
fp32 lệch trung bình 1.96e-6 (~như nhau), fp16 lệch 2.2e-3, đổi argmax
99.976% pixel — dùng số này để khẳng định lỗi (nếu có) không nằm ở bước
convert.

**Bảng thứ tự 19 lớp không suy đoán mà đo lại 3 cách** (IoU so ground-truth,
pin test đối chiếu bảng Python, kiểm tra hình học "tóc trên da, mắt trên
môi") — vì một bảng lớp bị lệch thứ tự vẫn "trông giống mask" nên không tự
phát hiện bằng mắt được. Không có lớp "răng" trong CelebAMask-HQ — răng phải
suy ra từ độ sáng bên trong lớp "mouth".

### 3.3 fp16 vs fp32 — tại sao chọn fp16 để ship

Cả 3 model đều convert ra cả 2 bản để **đối chứng lẫn nhau**, không phải để
chọn ngẫu nhiên: bản fp32 dùng làm control chứng minh việc convert không làm
sai lệch mạng gốc; bản fp16 (nhẹ hơn, nhanh hơn) là bản thực sự ship, với sai
số so fp32 đã đo và nằm trong ngưỡng chấp nhận (ví dụ BlazeFace fp16 chỉ làm
lệch kết quả landmark cuối cùng 0.001–0.002 px so với ảnh thật).

---

## 4. Dùng kết quả để "chỉnh ảnh" thế nào

Đầu ra 4 stage trên (box, 478 landmark, 19-class mask) không phải là sản phẩm
cuối — chúng là input cho các thuật toán chỉnh sửa ở `RPEngine`:

- **478 landmark → MLS mesh warp** (Moving Least Squares, biến dạng hình học)
  cho các slider nhóm "Mặt" (bóp mặt, gò má, cằm, mũi, mắt to…). Viết tay bằng
  Metal kernel, không dùng `CIWarpKernel` (đo được: warp per-pixel-inverse tốn
  gấp 208× so với warp theo lưới ở 24 MP). Công thức closed-form similarity
  transform trong số phức. Chi tiết: ADR-0007, ADR-0010.
- **19-class mask → guided filter** cho slider nhóm "Da" (mịn da giữ texture:
  guided filter + high-pass, nhân mask da). Tự viết Metal, không dùng
  `MPSImageGuidedFilter` (đo: MPS chậm hơn 6.3× ở cùng độ chính xác, hoặc kém
  hơn 12.6 dB ở cùng tốc độ) — vì use-case của MPS là upsample alpha-matte,
  khác bài toán tự-guide làm mịn da. Chi tiết: ADR-0007, ADR-0009.
- **Mask mắt/môi/miệng (feathered)** → slider nhóm "Mắt/Răng" (sáng mắt, trắng
  lòng trắng, nét mắt, trắng răng — răng suy từ độ sáng+bão hoà trong vùng
  `mouthInterior`, vì không có lớp răng riêng). Chi tiết: ADR-0008 §Decision 4,
  ADR-0011.
- **Color** (exposure, contrast, WB, HSL…) là nhóm **duy nhất không cần mặt** —
  chạy trên cả ảnh phong cảnh/sản phẩm không có người.

---

## 5. Cache — không chạy lại 4 model mỗi lần kéo slider (ADR-0008 §Decision 5, ADR-0013 §5)

`FaceAnalyzer` là một `actor` giữ **LRU cache 24 entry**, key =
`(contentHash, optionsFingerprint)`:

- `contentHash` lấy từ `RPCore.Shot.contentHash` (đã tính sẵn lúc import ảnh),
  **không** hash lại pixel mỗi lần (hash pixel một ảnh 24 MP tốn ~48 ms — chạy
  mỗi lần render sẽ phá cache).
- `optionsFingerprint` là SHA-256 của options encode JSON (không dùng
  `hashValue` của Swift vì nó seed ngẫu nhiên theo process, key lưu đĩa sẽ hỏng
  sau khi restart app).
- Phân tích chạy **đúng 1 lần mỗi khi mở ảnh**, không chạy lại khi kéo slider
  (`LivePreviewWiringTests.analysisRunsOncePerShot`: mở ảnh gọi 1 lần, kéo
  slider 100 lần gọi thêm 0 lần).
- Nhiều request cùng key đồng thời (vd 2 lần redraw dính nhau) dùng chung 1
  `Task`, không chạy phân tích 2 lần.

Tốc độ đo trên máy Mac: cache lạnh 46.7 ms, **cache nóng 0.052 ms (nhanh hơn
896×)**. Trên iPhone thật, lần phân tích lạnh đo được **556.9 ms** cho 1 ảnh 1
mặt (ADR-0015) — chậm hơn Mac ~15×, đây là chi phí một lần khi mở ảnh, không
lặp lại khi kéo slider.

---

## 6. Model file lưu ở đâu, ship ra sao

**Trong lúc phát triển / trên máy Mac** (theo ADR-0015, hiện hành cho code):

```
Research/spikes/S1-landmark/models/{BlazeFaceShortRange,FaceLandmark478}.mlpackage
Research/spikes/S2-face-parsing/models/FaceParsing19.mlpackage
```

3 file này **không phải chỉ để test** — `RetouchPro.xcodeproj/project.pbxproj`
reference thẳng 3 đường dẫn trên làm **Sources build input** của chính app
target (`com.apple.compilers.coreml` compile `.mlpackage` → `.mlmodelc` lúc
build, nhúng thẳng vào bundle app). Xoá hoặc đổi tên các file này là xoá luôn
khả năng build app, không chỉ hỏng test.

`AppEngineSetup.modelSources()` tìm model theo thứ tự: biến môi trường
`RP_MODELS_DIR` → app bundle đã compile → `Research/spikes/*/models/` (fallback
cuối, chỉ dùng lúc dev). Thiếu 1 trong 2 model bắt buộc thì cả pipeline mặt tắt
— không bao giờ chạy nửa vời (2/3 model có, 1 thiếu).

**Lưu ý quan trọng — khác với ADR-0015:** ADR-0015 viết "`.gitignore` phải
tiếp tục track 3 file này" vì chúng là product input. Nhưng khi push repo này
lên GitHub public (2026-09-07), đã **chủ động loại 3 file `.mlpackage` này +
mọi biến thể fp16/fp32 khỏi git** (xem `.gitignore`, mục "Converted CoreML
models"), vì chúng convert từ checkpoint bên thứ 3 (Google MediaPipe, BiSeNet)
và không muốn public. Hệ quả: **clone repo từ GitHub về sẽ không build được
app ngay** — phải tự chạy lại 3 script convert (`convert_tflite_to_coreml.py`,
`convert_blazeface_to_coreml.py`, `convert_bisenet_to_coreml.py` trong
`Research/spikes/`) trước khi build. Đây là đánh đổi có chủ đích, không phải
thiếu sót.

**Kết quả đo / log ở đâu:**

| Loại | Đường dẫn |
|---|---|
| Số đo chính xác (so gốc TFLite/PyTorch) | `Research/spikes/*/results/*.json` |
| Benchmark tốc độ (macOS + iOS Simulator + iPhone) | `Research/bench/p2-*.json` |
| Log runtime thật (mở app, phân tích từng ảnh) | `session.log` trên máy/thiết bị, qua `AppContainer.startupLog` + `FaceAnalyzerFaceInputProvider` log mỗi lần phân tích |
| Golden reference test (Double CPU, so PSNR) | `Packages/RPVision/Tests`, `Packages/RPEngine/Tests` (`*Reference.swift`) |

---

## 7. Feature flags — mọi thứ mặc định tắt cho tới khi có số đo

Mỗi model / node có **1 flag riêng**, mặc định `false`, chỉ bật thật ở
`App/AppEngineSetup.swift` lúc launch (không bật mặc định trong package —
`import RPVision`/`RPEngine` trần không được tự cấp phát texture/tải model):

`RPVisionFeatureFlags`: `faceLandmarks478`, `faceParsing19`,
`blazeFaceShortRange`, `faceAnalyzer` (gate cả pipeline — thiếu 1 trong 4 thì
throw `RPVisionFeatureDisabled` nói rõ thiếu flag nào).

`RPEngineFeatureFlags`: `colorSliders`, `skinSliders`, `warpSliders`,
`eyesTeethSliders` — 4 nhóm slider, bật cả 4 ở app target (ADR-0013 §2), có
thể tắt riêng lẻ lúc chạy dev qua `RP_DISABLE_GROUPS=warp` hoặc
`defaults write com.duynguyen.RetouchPro RPDisableGroups -string "skin,warp"`.

---

## 8. Giới hạn hiện tại (chưa xử lý, ghi nhận không phải để chặn)

- Toàn bộ hằng số thẩm mỹ (biên độ warp, gamma, knee...) suy từ vật lý/công
  thức, **chưa tinh chỉnh theo mắt người** — ADR-0009…0012 đều ghi rõ.
- Eye IoU của BiSeNet chỉ đạt 0.840 (bar plan là 0.85) — do giới hạn của
  checkpoint, không phải lỗi convert.
- Không có lớp "răng" trong 19-class parsing — teeth suy từ độ sáng, không
  phải mask thật.
- Multi-face: `maxFaces`/`FaceAnalyzer.pick` có unit test nhưng **chưa đo trên
  ảnh nhóm đông người thật**.
- Redraw chặn main thread lúc kéo slider (`waitUntilCompleted`) — ổn ở
  ~9 ms/frame trên Mac, chưa xác nhận trên iPhone chậm hơn.
- Pipeline phân tích mặt trên iPhone thật chậm hơn Mac ~15× (556.9 ms cold) —
  chưa tách được giai đoạn nào (Vision/BlazeFace/mesh/parsing) chiếm nhiều
  nhất, vì chưa có bench per-stage trên thiết bị thật.
