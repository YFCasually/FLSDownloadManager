import XCTest
@testable import FLSDownloadManager

final class FLSDownloadManagerTests: XCTestCase {
    func testRequestDefaultsAndProgressClamp() {
        let request = FLSDownloadRequest(url: URL(string: "https://example.com/file")!, priority: 2)
        XCTAssertEqual(request.cacheKey, request.url.absoluteString)
        XCTAssertEqual(request.priority, 1)
        XCTAssertEqual(FLSDownloadProgress(fractionCompleted: 2).fractionCompleted, 1)
    }

    func testCacheUsesSeparatedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = FLSDownloadCache(rootURL: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.filesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.resumeDataURL.path))
        try? FileManager.default.removeItem(at: root)
    }
}
