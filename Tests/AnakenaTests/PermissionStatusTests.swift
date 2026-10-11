import XCTest
@testable import Anakena

final class PermissionStatusTests: XCTestCase {
    func testNotTrustedWinsOverEverything() {
        XCTAssertEqual(permissionStatus(axTrusted: false, tapInstalled: false, secureInput: true), .needsAccessibility)
    }

    func testTrustedButNoTap() {
        XCTAssertEqual(permissionStatus(axTrusted: true, tapInstalled: false, secureInput: true), .needsInputMonitoring)
    }

    func testTapInstalledButSecureInput() {
        XCTAssertEqual(permissionStatus(axTrusted: true, tapInstalled: true, secureInput: true), .secureInput)
    }

    func testAllGood() {
        XCTAssertEqual(permissionStatus(axTrusted: true, tapInstalled: true, secureInput: false), .ok)
    }
}
