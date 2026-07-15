//
//  AppBundleInstallTests.swift
//  SimpleZipCoreTests
//
//  「移到应用程序」确定性检测:真 .app(带 Info.plist)才建议;应用程序目录里的、非 .app、
//  符号链接、残缺包(无 Info.plist / 无可执行名)都不建议。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct AppBundleInstallTests {

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-AppBundleInstallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeApp(named name: String, at dir: URL, plist: [String: Any]?) throws -> URL {
        let app = dir.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let plist {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return app
    }

    @Test func detectsAppWithNameAndVersion() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(named: "Demo.app", at: dir, plist: [
            "CFBundleExecutable": "Demo", "CFBundleName": "Demo", "CFBundleShortVersionString": "2.1"])
        let s = AppBundleInstallSuggestion.detect(url: app, isDirectory: true, isSymbolicLink: false)
        #expect(s?.displayName == "Demo 2.1")
    }

    @Test func prefersDisplayNameAndOmitsMissingVersion() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(named: "Internal.app", at: dir, plist: [
            "CFBundleExecutable": "Internal", "CFBundleName": "Internal", "CFBundleDisplayName": "Pretty Name"])
        let s = AppBundleInstallSuggestion.detect(url: app, isDirectory: true, isSymbolicLink: false)
        #expect(s?.displayName == "Pretty Name")
    }

    @Test func fallsBackToFileNameWhenPlistLacksNames() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(named: "Bare.app", at: dir, plist: ["CFBundleExecutable": "Bare"])
        let s = AppBundleInstallSuggestion.detect(url: app, isDirectory: true, isSymbolicLink: false)
        #expect(s?.displayName == "Bare")
    }

    @Test func rejectsBrokenBundleWithoutPlistOrExecutable() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let noPlist = try makeApp(named: "NoPlist.app", at: dir, plist: nil)
        #expect(AppBundleInstallSuggestion.detect(url: noPlist, isDirectory: true, isSymbolicLink: false) == nil)
        let noExec = try makeApp(named: "NoExec.app", at: dir, plist: ["CFBundleName": "NoExec"])
        #expect(AppBundleInstallSuggestion.detect(url: noExec, isDirectory: true, isSymbolicLink: false) == nil)
    }

    @Test func rejectsNonAppNonDirectoryAndSymlink() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(named: "Real.app", at: dir, plist: ["CFBundleExecutable": "Real"])
        #expect(AppBundleInstallSuggestion.detect(url: app, isDirectory: false, isSymbolicLink: false) == nil)
        #expect(AppBundleInstallSuggestion.detect(url: app, isDirectory: true, isSymbolicLink: true) == nil)
        let folder = dir.appendingPathComponent("Plain", isDirectory: true)
        #expect(AppBundleInstallSuggestion.detect(url: folder, isDirectory: true, isSymbolicLink: false) == nil)
    }

    @Test func rejectsAppsAlreadyInApplications() {
        // /Applications 前缀在读 plist 之前就挡下 → 不存在的路径也能测门槛本身。
        let system = URL(fileURLWithPath: "/Applications/Anything.app")
        #expect(AppBundleInstallSuggestion.detect(url: system, isDirectory: true, isSymbolicLink: false) == nil)
        let nested = URL(fileURLWithPath: "/Applications/Utilities/Nested.app")
        #expect(AppBundleInstallSuggestion.detect(url: nested, isDirectory: true, isSymbolicLink: false) == nil)
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/HomeApp.app")
        #expect(AppBundleInstallSuggestion.detect(url: home, isDirectory: true, isSymbolicLink: false) == nil)
    }
}
