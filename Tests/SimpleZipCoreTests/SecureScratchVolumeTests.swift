import Foundation
import Testing
@testable import SimpleZipCore

/// 覆盖 `SecureScratchVolume` 的**纯逻辑**：随机密码生成 + `hdiutil attach -plist` 挂载点解析。
/// 真正的 create/attach/detach 走 hdiutil，是集成行为，不在单测范围（CI 无交互、避免挂卷）。
struct SecureScratchVolumeTests {
    @Test func passwordIs32BytesBase64AndUnique() throws {
        let a = try SecureScratchVolume.generatePassword()
        let b = try SecureScratchVolume.generatePassword()
        // 32 字节 base64 → 44 字符（含一个 `=` padding）。
        #expect(a.count == 44)
        #expect(Data(base64Encoded: a)?.count == 32)
        // 两次生成必须不同（随机）。
        #expect(a != b)
    }

    @Test func parseMountPointFromAttachPlist() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>system-entities</key>
          <array>
            <dict>
              <key>dev-entry</key><string>/dev/disk7</string>
            </dict>
            <dict>
              <key>dev-entry</key><string>/dev/disk7s1</string>
              <key>mount-point</key><string>/private/tmp/SimpleZip-Scratch-mnt-ABC</string>
            </dict>
          </array>
        </dict>
        </plist>
        """
        let mp = SecureScratchVolume.parseMountPoint(from: plist)
        #expect(mp?.path == "/private/tmp/SimpleZip-Scratch-mnt-ABC")
    }

    @Test func parseMountPointReturnsNilWhenNoMount() {
        // 没有任何 mount-point（如 -nomount）→ nil。
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>system-entities</key><array>
          <dict><key>dev-entry</key><string>/dev/disk7</string></dict>
        </array></dict>
        </plist>
        """
        #expect(SecureScratchVolume.parseMountPoint(from: plist) == nil)
        #expect(SecureScratchVolume.parseMountPoint(from: "not a plist") == nil)
    }
}
