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

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, true)
        XCTAssertNil(plist["NSPrivacyTrackingDomains"])
        XCTAssertEqual((plist["NSPrivacyAccessedAPITypes"] as? [Any])?.count, 0)
        let types = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let tracking = Dictionary(
            uniqueKeysWithValues: types.map {
                ($0["NSPrivacyCollectedDataType"] as? String ?? "",
                    $0["NSPrivacyCollectedDataTypeTracking"] as? Bool)
            })
        XCTAssertEqual(
            tracking,
            [
                "NSPrivacyCollectedDataTypeUserID": false,
                "NSPrivacyCollectedDataTypeDeviceID": true,
                "NSPrivacyCollectedDataTypePurchaseHistory": true,
                "NSPrivacyCollectedDataTypeProductInteraction": false,
                "NSPrivacyCollectedDataTypeAdvertisingData": false,
            ])
        for type in types {
            let purposes = type["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            XCTAssertEqual(
                purposes.contains("NSPrivacyCollectedDataTypePurposeDeveloperAdvertising"),
                type["NSPrivacyCollectedDataTypeTracking"] as? Bool)
        }
    }
}
