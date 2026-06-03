//
//  GPGKeyParsingTests.swift
//  SimpleZip
//
//  回归测试：`gpg --list-secret-keys --with-colons` 里私钥状态在**第 15 字段（0-based index 14）**：
//    `+` = 本机完整私钥；`#` = 已 stripped；`<serial>` = 在智能卡上。
//  历史 bug 错读 index 13（恒空）→ 卡 stub 永远判不出「在卡上」、还被误当完整本机私钥；
//  插卡时靠 --card-status 兜回，一拔卡就退化。这里用真实形态的 colons 行钉住三种状态的判定。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct GPGKeyParsingTests {
    // 真实 gpg 2.5 输出形态：type 字段干净（无 `>`/`#` 后缀），状态在第 15 字段。
    // 卡 stub —— 第 15 字段是卡 token serial。
    private static let smartcardSecBlock = """
    sec:u:255:22:D8B041C2400FF8E3:1717753828:::u:::scESCA:::D276000124010304F1D00131337E0000::ed25519:::0:
    fpr:::::::::AEBB3BC588DCC8AF57845697D8B041C2400FF8E3:
    """
    // 本机完整私钥 —— 第 15 字段是 `+`。
    private static let fullLocalSecBlock = """
    sec:u:255:22:B914F3C50A3B34B1:1750000000:::u:::scESC:::+::ed25519:::0:
    fpr:::::::::1111222233334444555566667777888899990000:
    """
    // 已 stripped —— 第 15 字段是 `#`。
    private static let strippedSecBlock = """
    sec:u:255:22:C0FFEE0011223344:1750000000:::u:::scESC:::#::ed25519:::0:
    fpr:::::::::AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555:
    """
    // 子密钥在卡上 —— ssb 行第 15 字段是卡 serial。
    private static let smartcardSubkeyBlock = """
    ssb:u:255:18:3C4C9628983E3249:1717753884::::::e:::D276000124010304F1D00131337E0000::cv25519::
    fpr:::::::::4861636A31257655B6F9C3C13C4C9628983E3249:
    """

    @Test
    func smartcardPrimaryDetectedFromColonsSerialField() {
        let onCard = GPGBackend.parseFingerprints(in: Self.smartcardSecBlock, recordPrefix: "sec", mode: .smartcard)
        #expect(onCard == ["AEBB3BC588DCC8AF57845697D8B041C2400FF8E3"])
        // 卡 stub 不能被算成「完整本机私钥」。
        let fullSecret = GPGBackend.parseFingerprints(in: Self.smartcardSecBlock, recordPrefix: "sec", mode: .fullSecret)
        #expect(fullSecret.isEmpty)
        let stripped = GPGBackend.parseFingerprints(in: Self.smartcardSecBlock, recordPrefix: "sec", mode: .stripped)
        #expect(stripped.isEmpty)
    }

    @Test
    func fullLocalKeyNotMisreadAsSmartcard() {
        // `+` = 本机完整私钥：只能进 fullSecret，不能被误判成卡上 / stripped。
        let fullSecret = GPGBackend.parseFingerprints(in: Self.fullLocalSecBlock, recordPrefix: "sec", mode: .fullSecret)
        #expect(fullSecret == ["1111222233334444555566667777888899990000"])
        let onCard = GPGBackend.parseFingerprints(in: Self.fullLocalSecBlock, recordPrefix: "sec", mode: .smartcard)
        #expect(onCard.isEmpty)
        let stripped = GPGBackend.parseFingerprints(in: Self.fullLocalSecBlock, recordPrefix: "sec", mode: .stripped)
        #expect(stripped.isEmpty)
    }

    @Test
    func strippedKeyDetectedFromColonsHashField() {
        let stripped = GPGBackend.parseFingerprints(in: Self.strippedSecBlock, recordPrefix: "sec", mode: .stripped)
        #expect(stripped == ["AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555"])
        let onCard = GPGBackend.parseFingerprints(in: Self.strippedSecBlock, recordPrefix: "sec", mode: .smartcard)
        #expect(onCard.isEmpty)
        let fullSecret = GPGBackend.parseFingerprints(in: Self.strippedSecBlock, recordPrefix: "sec", mode: .fullSecret)
        #expect(fullSecret.isEmpty)
    }

    @Test
    func smartcardSubkeyDetectedFromColonsSerialField() {
        let onCard = GPGBackend.parseFingerprints(in: Self.smartcardSubkeyBlock, recordPrefix: "ssb", mode: .smartcard)
        #expect(onCard == ["4861636A31257655B6F9C3C13C4C9628983E3249"])
    }
}
