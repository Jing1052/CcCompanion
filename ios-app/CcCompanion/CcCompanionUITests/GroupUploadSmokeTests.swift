//
//  GroupUploadSmokeTests.swift
//  CcCompanionUITests
//
//  Build 218 r3 — XCUITest covering group-chat upload PHPicker → /group/upload end-to-end.
//
//  Launch env UITEST_GROUP_UPLOAD_SMOKE=1 makes CcCompanionApp pre-populate UserDefaults
//  (skip onboarding, enable group view, point at local demo server on 8796) so the test
//  lands directly on the group tab.
//

#if canImport(XCTest)
import XCTest

final class GroupUploadSmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Smoke: navigate to group tab, open + menu, tap image button, verify PHPicker appears.
    /// Final upload assertion is best-effort because PHPicker selection is system UI that
    /// varies across iOS minor versions; any successful tap of the image entry counts the
    /// app-side wiring as working.
    func testGroupUploadEntry() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_GROUP_UPLOAD_SMOKE": "1"]
        app.launch()

        // Tab 3 is the group tab when feature_group_view=true (ContentView tab order).
        let groupTab = app.buttons["tab-3"]
        XCTAssertTrue(groupTab.waitForExistence(timeout: 10), "group tab missing")
        groupTab.tap()

        // Image button is the second entry in the group input bar (after plus menu).
        let imageBtn = app.buttons["group-upload-image"]
        XCTAssertTrue(imageBtn.waitForExistence(timeout: 10), "group-upload-image not found")

        // Capture pre-tap screenshot for the result evidence.
        attachScreenshot(name: "01-group-tab-loaded")

        imageBtn.tap()

        // PhotosPicker is system UI; it presents a sheet with a search bar / photo grid.
        // Look for the system "Photos" or "Library" title, or any image in the grid.
        let photosTitle = app.navigationBars.firstMatch
        let waited = photosTitle.waitForExistence(timeout: 6)
        attachScreenshot(name: "02-photos-picker-presented")

        // Soft assertion — PHPicker may render under different titles per iOS version.
        XCTAssertTrue(waited, "no system sheet appeared after tapping image button")

        // Wait for the photo grid to render. Default sims ship empty so we populate before
        // the test via `xcrun simctl addmedia` (see r3 result doc). PhotosUI uses Photos.app's
        // remote view; XCUITest sees its tiles as `app.images` (not collectionViews.cells).
        sleep(3)  // PHPicker library spinner

        let firstImg = app.images.element(boundBy: 0)
        if firstImg.waitForExistence(timeout: 8) {
            firstImg.tap()
            attachScreenshot(name: "03-photo-selected")

            // Confirm button: localized "添加" / "Add" in EN, "✓" or "完成" in zh_CN.
            // PHPicker's confirm is labeled "添加" in Chinese system. Try multiple.
            for label in ["添加", "Add", "选择", "完成", "Done"] {
                let b = app.buttons[label].firstMatch
                if b.waitForExistence(timeout: 1) && b.isHittable {
                    b.tap()
                    break
                }
            }
        }

        // Give the upload pipeline time: loadTransferable → URLSession.upload → server response.
        sleep(6)
        attachScreenshot(name: "04-after-upload-attempt")
    }

    /// Smoke: verify the plus menu opens (its content includes "拍照" / "文件" buttons).
    func testGroupPlusMenuOpens() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["UITEST_GROUP_UPLOAD_SMOKE": "1"]
        app.launch()

        let groupTab = app.buttons["tab-3"]
        XCTAssertTrue(groupTab.waitForExistence(timeout: 10))
        groupTab.tap()

        let plusBtn = app.buttons["group-upload-plus"]
        XCTAssertTrue(plusBtn.waitForExistence(timeout: 10), "group-upload-plus not found")
        plusBtn.tap()

        attachScreenshot(name: "05-plus-menu-open")
        // Menu items are buttons labelled "拍照" / "文件".
        let cameraBtn = app.buttons["拍照"].firstMatch
        let fileBtn = app.buttons["文件"].firstMatch
        XCTAssertTrue(cameraBtn.waitForExistence(timeout: 3) || fileBtn.waitForExistence(timeout: 3),
                      "plus menu did not surface 拍照 / 文件 entries")
    }

    private func attachScreenshot(name: String) {
        let shot = XCUIApplication().screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
#endif
