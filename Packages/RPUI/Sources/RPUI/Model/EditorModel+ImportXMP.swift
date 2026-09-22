import Foundation
import RPCore
import RPEngine

/// Importing Lightroom `.xmp` sidecars — Lightroom's own develop-settings
/// files, read here instead of written.
///
/// **Straight into "Của tôi", at full strength, no intermediate step**
/// (2026-09-22, user request after an earlier version previewed it on the
/// open photo with its own intensity slider first: *"import thì mặc định vào
/// luôn list presets … chứ đéo phải chờ nhấn lưu hay gì nữa. import thì
/// preset được đưa vào list nhưng chưa áp vào ảnh, khi nào click vào preset
/// vừa import thì mới áp vào ảnh"*). The open photo is **never** touched by
/// import — applying a freshly-imported Look afterwards is exactly like
/// applying any other preset in the list: select the row
/// (``EditorModel/selectPresetForApply(_:)``), the "Cường độ" slider in the
/// panel's footer dials the strength, release commits. Import does not need
/// its own copy of that machinery.
///
/// **One file, several files, or a whole folder** (2026-09-22, user request:
/// *"cho phép import theo folder hoặc nhiều file preset 1 lúc"*): several
/// loose files each become their own preset in the default "Của tôi" bucket,
/// exactly like importing them one at a time would; a folder's sidecars are
/// grouped under the folder's own name instead (``Preset/collection``, read
/// back out by ``PresetLibraryModel/mineGroupedByCollection``), because *"nếu
/// import folder thì sẽ tạo 1 group"*.
///
/// Kept out of `EditorModel.swift` for the same reason `EditorModel+CopySettings`
/// is: one self-contained feature.
extension EditorModel {

    /// Parses `url` and saves it as a Look in `library`'s "Của tôi", named
    /// after the file. Returns `nil` (and sets ``lastImportMessage``) on
    /// anything that goes wrong — a bad file, or one with none of the fields
    /// this app reads.
    ///
    /// - Parameter collection: passed straight to
    ///   ``PresetLibraryModel/saveXMPPreset(named:colorSection:collection:)`` —
    ///   `nil` for a single file picked on its own, the folder's name when
    ///   called from ``importXMPPresets(fromFolder:in:)``.
    @discardableResult
    public func importXMPAsPreset(
        from url: URL, in library: PresetLibraryModel, collection: String? = nil
    ) -> Preset? {
        let name = url.deletingPathExtension().lastPathComponent
        let settings: LightroomXMPSettings
        do {
            settings = try LightroomXMPSettings.parse(contentsOf: url)
        } catch LightroomXMPError.noDevelopSettings {
            lastImportMessage =
                "\(url.lastPathComponent) không có thiết lập nào RetouchPro đọc được (Exposure, Contrast, WB, Vibrance, Saturation, HSL)."
            return nil
        } catch LightroomXMPError.invalidXML {
            lastImportMessage = "\(url.lastPathComponent) không phải file .xmp hợp lệ."
            return nil
        } catch {
            // A permission failure (outside the sandbox, moved, deleted
            // mid-read) lands here — distinct from the two cases above so it
            // is not mistaken for "the file itself is bad" (2026-09-22: a
            // sandbox-access bug hid behind exactly that confusion once).
            lastImportMessage = "\(url.lastPathComponent) không đọc được: \(error.localizedDescription)"
            return nil
        }
        let overrides = settings.colorSliderOverrides()
        guard !overrides.isEmpty else {
            lastImportMessage = "\(url.lastPathComponent) không có thiết lập màu nào để nhập."
            return nil
        }
        var section = EditSection()
        for (key, value) in overrides {
            section.setSlider(key, to: value, range: Slider.range(for: key, in: EditState.SectionKey.color))
        }
        guard
            let preset = library.saveXMPPreset(
                named: name, colorSection: section, collection: collection)
        else {
            lastImportMessage = library.lastErrorMessage
            return nil
        }
        // No success banner (2026-09-22, user request: *"tao không cần thông
        // báo này!"*) — the preset showing up in the list already says it
        // worked; only a failure needs a line telling the user something did
        // not happen.
        return preset
    }

    /// Several loose `.xmp` files picked at once — each lands in the default
    /// "Của tôi" bucket independently, the same as picking them one at a
    /// time would; nothing groups them together, which is what tells them
    /// apart from ``importXMPPresets(fromFolder:in:)``.
    public func importXMPPresets(fromFiles urls: [URL], in library: PresetLibraryModel) {
        for url in urls {
            importXMPAsPreset(from: url, in: library)
        }
    }

    /// A folder of `.xmp` sidecars, imported together under the folder's own
    /// name (``Preset/collection``) — only its direct children, not
    /// subfolders, matching how a folder of exported Lightroom presets is
    /// normally laid out flat.
    public func importXMPPresets(fromFolder url: URL, in library: PresetLibraryModel) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            lastImportMessage =
                "Không đọc được thư mục \"\(url.lastPathComponent)\": \(error.localizedDescription)"
            return
        }
        let xmpFiles =
            children
            .filter { $0.pathExtension.lowercased() == "xmp" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !xmpFiles.isEmpty else {
            lastImportMessage = "Không có file .xmp nào trong \"\(url.lastPathComponent)\"."
            return
        }
        let collectionName = url.lastPathComponent
        var failedCount = 0
        for file in xmpFiles where importXMPAsPreset(from: file, in: library, collection: collectionName) == nil {
            failedCount += 1
        }
        if failedCount > 0 {
            lastImportMessage =
                "\(failedCount)/\(xmpFiles.count) file trong \"\(collectionName)\" không nhập được."
        }
    }
}
