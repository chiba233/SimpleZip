import XCTest
@testable import SimpleZipCore

final class SensitiveFileScanTests: XCTestCase {
    func testCategorizesByNameAndExtension() {
        let result = SensitiveFileScan.scan([
            "project/LICENSE",
            "project/src/id_rsa",
            "project/config/server.yaml",
            "project/scripts/build.sh",
            "project/keys/server.pem",
            "project/README.md",
            "project/.env",
            "project/dir/",            // 目录,不计
        ])
        XCTAssertEqual(result.scannedFileCount, 7)
        func paths(_ c: SensitiveFileCategory) -> [String] {
            result.groups.first { $0.category == c }?.paths ?? []
        }
        XCTAssertTrue(paths(.secretsKeys).contains("project/src/id_rsa"))
        XCTAssertTrue(paths(.secretsKeys).contains("project/keys/server.pem"))
        XCTAssertTrue(paths(.secretsKeys).contains("project/.env"))
        XCTAssertEqual(paths(.license), ["project/LICENSE"])
        XCTAssertEqual(paths(.config), ["project/config/server.yaml"])
        XCTAssertEqual(paths(.scripts), ["project/scripts/build.sh"])
        // README 不进任何分类。
        XCTAssertFalse(result.groups.flatMap { $0.paths }.contains("project/README.md"))
    }

    func testEmptyWhenNothingSensitive() {
        let result = SensitiveFileScan.scan(["a/photo.jpg", "b/notes.md", "c/data.bin"])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.scannedFileCount, 3)
    }

    func testSecretWinsOverConfigForEnv() {
        // ".env" 既像配置又是机密 —— 优先级里机密更高。
        let result = SensitiveFileScan.scan([".env"])
        XCTAssertEqual(result.groups.first?.category, .secretsKeys)
    }

    func testGroupsAreSeverityOrdered() {
        let result = SensitiveFileScan.scan(["build.sh", "LICENSE", "app.conf", "id_ed25519"])
        XCTAssertEqual(result.groups.map { $0.category }, [.secretsKeys, .license, .config, .scripts])
    }
}
