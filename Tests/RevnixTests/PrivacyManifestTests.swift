import Foundation
import XCTest

final class PrivacyManifestTests: XCTestCase {

    func testManifestShipsInTheResourceBundle() throws {
        let url = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Revnix_Revnix.bundle")
            .appendingPathComponent("PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any])

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyAccessedAPITypes"] as? [Any])?.count, 0)
        let types = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?
            .compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertEqual(
            types,
            [
                "NSPrivacyCollectedDataTypeUserID",
                "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypePurchaseHistory",
                "NSPrivacyCollectedDataTypeProductInteraction",
                "NSPrivacyCollectedDataTypeAdvertisingData",
            ])
    }
}
