#if os(iOS)

    import XCTest

    /// End-to-end test of "Mở với RetouchPro": Photos → Share Sheet → the
    /// extension → the app's editor, with the shared photo already in it
    /// (docs/PLAN.md §Phase 3B item 5, HANDOFF §4.1 item 5).
    ///
    /// **Why a UI test and not a device launch.** A Share Extension has no
    /// independently launchable bundle identifier — `devicectl device process
    /// launch`, which every other task in this project uses to verify on the
    /// real phone, cannot start one. The only way to run the extension is for a
    /// *host* app to present the Share Sheet, so the test drives Photos.
    ///
    /// The two cases are separate tests on purpose: the app not running at all
    /// and the app already in the background take different paths through
    /// SwiftUI's `onOpenURL`, and only the second one exercises a
    /// `RetouchProRootView` that is already on screen (with, in this test, a
    /// project already open — the case that can leave the user looking at the
    /// wrong project).
    final class ShareExtensionHandoffUITests: XCTestCase {
        private let appBundleID = "com.duynguyen.RetouchPro"
        private let photosBundleID = "com.apple.mobileslideshow"

        /// Only in the editor, never in the projects list — so finding it proves
        /// the hand-off did not stop at the library screen.
        private let editorOnlyButton = "Xuất"
        /// Only in the projects list.
        private let projectsListHeader = "Dự án"

        private var app: XCUIApplication { XCUIApplication(bundleIdentifier: appBundleID) }
        private var photos: XCUIApplication { XCUIApplication(bundleIdentifier: photosBundleID) }

        override func setUp() {
            super.setUp()
            continueAfterFailure = false
        }

        override func tearDown() {
            photos.terminate()
            super.tearDown()
        }

        // MARK: - The two cases

        /// Cold start: RetouchPro is not running when the user shares.
        func testColdStartOpensEditorOnTheSharedPhoto() throws {
            app.terminate()
            XCTAssertNotEqual(app.state, .runningForeground)

            try shareFirstPhotoToRetouchPro()
            try assertEditorOpenedOnSharedPhoto()
        }

        /// Warm start: the app is already running (and already inside a
        /// project) when the user shares from Photos.
        func testWarmStartOpensEditorOnTheSharedPhoto() throws {
            app.terminate()
            app.launch()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 30),
                "RetouchPro did not come to the foreground on a plain launch")
            // Give the projects list time to appear, then send the app to the
            // background — the state the warm-start path has to handle.
            _ = app.staticTexts[projectsListHeader].waitForExistence(timeout: 30)
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(
                app.wait(for: .runningBackground, timeout: 15)
                    || app.state == .runningBackgroundSuspended,
                "RetouchPro did not go to the background")

            try shareFirstPhotoToRetouchPro()
            try assertEditorOpenedOnSharedPhoto()
        }

        // MARK: - Steps

        private func assertEditorOpenedOnSharedPhoto() throws {
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 60),
                "The extension did not bring RetouchPro to the foreground")
            let landed = app.buttons[editorOnlyButton].waitForExistence(timeout: 60)
            if !landed { dumpHierarchy(of: app, named: "app-after-handoff") }
            XCTAssertTrue(
                landed,
                "RetouchPro came forward but did not land in the editor "
                    + "(no \"\(editorOnlyButton)\" button)")
            // `exists`, not `isHittable`, would be wrong here: the projects list
            // is the root of the same `NavigationStack`, so its title stays in
            // the accessibility tree behind the pushed editor. What must be true
            // is that it is not what the user is looking at.
            XCTAssertFalse(
                app.staticTexts[projectsListHeader].isHittable,
                "The hand-off stopped at the projects list instead of the editor")
        }

        /// Photos → first photo → Share → RetouchPro.
        private func shareFirstPhotoToRetouchPro() throws {
            photos.terminate()
            photos.launch()
            XCTAssertTrue(
                photos.wait(for: .runningForeground, timeout: 30), "Photos did not launch")
            dismissPhotosInterstitials()
            returnToLibraryGrid()

            let photo = try newestPhotoTile()
            // The grid tiles report `isHittable == false` on iOS 26 (they are
            // one drawn layer, not real subviews), so tap the point.
            tap(photo)

            let share = try element(
                in: photos, labelled: ["Share", "Chia sẻ"], kinds: [.button])
            share.tap()

            let target = try shareSheetItemForRetouchPro()
            target.tap()
        }

        /// The newest photo in the library grid — the one a run just put there.
        ///
        /// iOS 26's library is not a collection view of cells: the tiles are
        /// `Image` elements identified `PXGGridLayout-Info`, laid out oldest
        /// first, so the last one is the newest. The collection-view lookup is
        /// kept as the fallback for older layouts.
        private func newestPhotoTile() throws -> XCUIElement {
            let tiles = photos.images.matching(identifier: "PXGGridLayout-Info")
            if tiles.element(boundBy: 0).waitForExistence(timeout: 20), tiles.count > 0 {
                return tiles.element(boundBy: tiles.count - 1)
            }
            let cells = photos.collectionViews.cells
            if cells.element(boundBy: 0).waitForExistence(timeout: 10), cells.count > 0 {
                return cells.element(boundBy: cells.count - 1)
            }
            dumpHierarchy(of: photos, named: "photos-without-a-grid")
            throw XCTSkip(
                "This device's Photos library is empty — put at least one photo on it "
                    + "(Research/data has real files) and run again.")
        }

        private func shareSheetItemForRetouchPro() throws -> XCUIElement {
            // The activity row scrolls, and RetouchPro is a newly installed
            // extension, so it can start off screen.
            // "Retouch", not "RetouchPro": the row shows the *display* name,
            // which is "Retouch Pro" with a space (INFOPLIST_KEY_CFBundleDisplayName
            // on both the app and the extension).
            for attempt in 0..<4 {
                for kind in [XCUIElement.ElementType.cell, .button, .other] {
                    let matches = photos.descendants(matching: kind)
                        .matching(NSPredicate(format: "label CONTAINS[c] %@", "Retouch"))
                    let element = matches.firstMatch
                    if element.waitForExistence(timeout: attempt == 0 ? 10 : 2),
                        element.isHittable
                    {
                        return element
                    }
                }
                photos.swipeLeft()
            }
            dumpHierarchy(of: photos, named: "share-sheet-without-RetouchPro")
            XCTFail(
                "\"RetouchPro\" is not in the Share Sheet. The extension is either not installed "
                    + "or its NSExtensionActivationRule did not match one image.")
            throw XCTSkip("Share Sheet item not found")
        }

        /// Photos restores its last screen, so a second run can start already
        /// inside the one-up view of the photo the previous run shared. Back out
        /// of it, so "the newest tile" means the same thing every time.
        private func returnToLibraryGrid() {
            let done = photos.buttons["PUOneUpBarButtonItemIdentifierDone"]
            if done.waitForExistence(timeout: 3), done.isHittable {
                done.tap()
            }
        }

        private func dismissPhotosInterstitials() {
            // "What's New in Photos" and friends. Tapping Continue if it is
            // there is cheaper than the flakiness of not doing it.
            for label in ["Continue", "Tiếp tục", "Get Started", "Bắt đầu"] {
                let button = photos.buttons[label]
                if button.waitForExistence(timeout: 2), button.isHittable {
                    button.tap()
                }
            }
        }

        private func element(
            in application: XCUIApplication,
            labelled labels: [String],
            kinds: [XCUIElement.ElementType]
        ) throws -> XCUIElement {
            // By identifier or accessibility label first — Photos names its
            // toolbar share control "Share" on an English device and "Chia sẻ"
            // on a Vietnamese one.
            for kind in kinds {
                for label in labels {
                    let byIdentifier = application.descendants(matching: kind)[label]
                    if byIdentifier.waitForExistence(timeout: 5), byIdentifier.isHittable {
                        return byIdentifier
                    }
                }
            }
            // Then anything whose label merely contains the word. iOS 26's
            // Photos draws the share control inside a toolbar whose exact
            // element type has moved between releases, so do not insist on one.
            for kind in kinds + [.any] {
                for label in labels {
                    let match = application.descendants(matching: kind)
                        .matching(NSPredicate(format: "label CONTAINS[c] %@", label))
                        .firstMatch
                    if match.exists, match.isHittable { return match }
                }
            }
            dumpHierarchy(of: application, named: "no-\(labels.first ?? "element")")
            throw XCTSkip(
                "Could not find \(labels.joined(separator: " / ")) in "
                    + "\(application.description) — the host app's UI differs from what this "
                    + "test knows about. The element tree is attached.")
        }

        /// Taps an element that exists but does not advertise itself as
        /// hittable — Photos' drawn grid tiles, for one.
        private func tap(_ element: XCUIElement) {
            if element.isHittable {
                element.tap()
            } else {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }

        /// Writes the whole element tree into the test report. Without it a skip
        /// says only "not found", which is not enough to fix the selector.
        private func dumpHierarchy(of application: XCUIApplication, named name: String) {
            let attachment = XCTAttachment(string: application.debugDescription)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[uitest] \(name):\n\(application.debugDescription)")
        }
    }

#endif
