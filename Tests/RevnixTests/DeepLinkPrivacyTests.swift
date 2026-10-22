import XCTest

@testable import Revnix

final class DeepLinkPrivacyTests: XCTestCase {
    private func reduce(_ s: String) -> String { RevnixClient.reportableDeepLink(s) }

    func testKeepsAllowlistedInOrderAndCase() {
        XCTAssertEqual(
            reduce("https://x.com:8080/p?UTM_Source=Mail&b=1&gclid=AbC&c=z"),
            "https://x.com:8080/p?UTM_Source=Mail&gclid=AbC&c=z")
    }

    func testDropsOthersFragmentAndUserinfo() {
        XCTAssertEqual(
            reduce("https://u:pw@x.com/p?token=1&pid=7#frag"), "https://x.com/p?pid=7")
    }

    func testNoAllowedQueryDropsQuestionMark() {
        XCTAssertEqual(reduce("https://x.com/p?token=1"), "https://x.com/p")
    }

    func testPercentEncodingPreserved() {
        XCTAssertEqual(
            reduce("https://x.com/p?utm_campaign=a%2Bb&t=1"), "https://x.com/p?utm_campaign=a%2Bb")
    }

    func testKeepsUtmIdAndCampaignId() {
        XCTAssertEqual(
            reduce("https://x.com/p?utm_id=5&campaign_id=6&z=1"),
            "https://x.com/p?utm_id=5&campaign_id=6")
    }

    func testMacroEncodedNameSpaceAndLeadingWhitespace() {
        XCTAssertEqual(
            reduce("  https://x.com/p?utm_campaign={{macro}}&x=1"),
            "https://x.com/p?utm_campaign={{macro}}")
        XCTAssertEqual(
            reduce("https://x.com/p?utm%5Fsource=a&k=1"), "https://x.com/p?utm%5Fsource=a")
        XCTAssertEqual(
            reduce("https://x.com/p?utm_term=a b&k=1"), "https://x.com/p?utm_term=a b")
    }

    func testCustomScheme() {
        XCTAssertEqual(
            reduce("myapp://promo?utm_source=x&token=y"), "myapp://promo?utm_source=x")
    }

    func testUnparseableCutsAtQueryOrFragment() {
        XCTAssertEqual(reduce("not a url?token=1"), "not a url")
        XCTAssertEqual(reduce("bad host#x?y"), "bad host")
    }
}
