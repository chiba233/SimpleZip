import Foundation
import Testing
@testable import SimpleZipCore

/// #16 simplezip:// URL scheme 解析:check/compare/open,只收绝对路径,异形输入一律 nil。
struct SimpleZipURLCommandTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func parsesSupportedVerbs() {
        #expect(SimpleZipURLCommand.parse(url("simplezip://check?path=/tmp/a.zip")) == .check(path: "/tmp/a.zip"))
        #expect(SimpleZipURLCommand.parse(url("simplezip://test?path=/tmp/a.zip")) == .check(path: "/tmp/a.zip"))
        #expect(SimpleZipURLCommand.parse(url("simplezip://compare?left=/a.zip&right=/b.zip"))
            == .compare(left: "/a.zip", right: "/b.zip"))
        #expect(SimpleZipURLCommand.parse(url("simplezip://open?path=/Users/me/Downloads")) == .open(path: "/Users/me/Downloads"))
        // 百分号编码照常解(空格路径)。
        #expect(SimpleZipURLCommand.parse(url("simplezip://check?path=/tmp/My%20File.7z")) == .check(path: "/tmp/My File.7z"))
    }

    @Test func rejectsMalformedInput() {
        // 相对路径 / 缺参数 / 未知动词 / 其他 scheme / 内部管道 host 一律不解析。
        #expect(SimpleZipURLCommand.parse(url("simplezip://check?path=relative.zip")) == nil)
        #expect(SimpleZipURLCommand.parse(url("simplezip://check")) == nil)
        #expect(SimpleZipURLCommand.parse(url("simplezip://compare?left=/a.zip")) == nil)
        #expect(SimpleZipURLCommand.parse(url("simplezip://delete?path=/tmp/a.zip")) == nil)
        #expect(SimpleZipURLCommand.parse(url("https://check?path=/tmp/a.zip")) == nil)
        #expect(SimpleZipURLCommand.parse(url("simplezip://finder-action?action=extract&payload=/tmp/x.json")) == nil)
    }

    @Test func identifiesAppOwnedURLsEvenWhenMalformed() {
        #expect(SimpleZipURLCommand.isAppOwnedURL(url("simplezip://finder-action?action=extract&payload=/tmp/missing.json")))
        #expect(SimpleZipURLCommand.isAppOwnedURL(url("SimpleZip://delete?path=/tmp/a.zip")))
        #expect(!SimpleZipURLCommand.isAppOwnedURL(url("https://check?path=/tmp/a.zip")))
        #expect(!SimpleZipURLCommand.isAppOwnedURL(URL(fileURLWithPath: "/tmp/a.zip")))
    }
}
