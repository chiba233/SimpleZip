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

    // MARK: - Shortcuts 反哺:extract / hash / create(多文件 + format)

    @Test func parsesExtractHashCreate() {
        // 单文件 / 多文件(重复 path query,按出现顺序)。
        #expect(SimpleZipURLCommand.parse(url("simplezip://extract?path=/tmp/a.zip")) == .extract(paths: ["/tmp/a.zip"]))
        #expect(SimpleZipURLCommand.parse(url("simplezip://extract?path=/tmp/a.zip&path=/tmp/b.7z"))
            == .extract(paths: ["/tmp/a.zip", "/tmp/b.7z"]))
        #expect(SimpleZipURLCommand.parse(url("simplezip://hash?path=/tmp/a.bin&path=/tmp/b.bin"))
            == .hash(paths: ["/tmp/a.bin", "/tmp/b.bin"]))
        // 百分号编码空格照常解。
        #expect(SimpleZipURLCommand.parse(url("simplezip://extract?path=/tmp/My%20File.zip")) == .extract(paths: ["/tmp/My File.zip"]))
        // 混入相对路径被过滤,只留绝对路径。
        #expect(SimpleZipURLCommand.parse(url("simplezip://extract?path=rel.zip&path=/tmp/ok.zip")) == .extract(paths: ["/tmp/ok.zip"]))
    }

    @Test func parsesCreateFormatAndAliases() {
        // 无 format 默认 zip。
        #expect(SimpleZipURLCommand.parse(url("simplezip://create?path=/tmp/a&path=/tmp/b"))
            == .create(format: .zip, inputs: ["/tmp/a", "/tmp/b"]))
        // rawValue 与别名。
        #expect(SimpleZipURLCommand.parse(url("simplezip://create?path=/tmp/a&format=7z")) == .create(format: .sevenZip, inputs: ["/tmp/a"]))
        #expect(SimpleZipURLCommand.parse(url("simplezip://create?path=/tmp/a&format=targz")) == .create(format: .tarGzip, inputs: ["/tmp/a"]))
        #expect(SimpleZipURLCommand.parse(url("simplezip://create?path=/tmp/a&format=tgz")) == .create(format: .tarGzip, inputs: ["/tmp/a"]))
        // 无法识别的 format 回落 zip(绝不静默失败)。
        #expect(SimpleZipURLCommand.parse(url("simplezip://create?path=/tmp/a&format=bogus")) == .create(format: .zip, inputs: ["/tmp/a"]))
    }

    @Test func rejectsExtractHashCreateWithoutAbsolutePaths() {
        // 缺 path / 仅相对路径 → nil(不退化成空动作)。
        #expect(SimpleZipURLCommand.parse(url("simplezip://extract")) == nil)
        #expect(SimpleZipURLCommand.parse(url("simplezip://extract?path=rel.zip")) == nil)
        #expect(SimpleZipURLCommand.parse(url("simplezip://hash?path=rel")) == nil)
        #expect(SimpleZipURLCommand.parse(url("simplezip://create?format=zip")) == nil)
    }
}
