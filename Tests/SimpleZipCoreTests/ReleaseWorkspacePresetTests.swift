import Foundation
import Testing
@testable import SimpleZipCore

/// #18 工作区预设:store CRUD round-trip + 同名覆盖 + 排序确定性。
struct ReleaseWorkspacePresetTests {

    private func makeStore() -> (ReleaseWorkspacePresetStore, UserDefaults, String) {
        let suite = "SimpleZip-WorkspacePresetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ReleaseWorkspacePresetStore(defaults: defaults), defaults, suite)
    }

    private func preset(_ name: String, fileName: String = "out") -> ReleaseWorkspacePreset {
        ReleaseWorkspacePreset(
            name: name, sourceFolderPath: "/tmp/src", fileName: fileName,
            formatRawValue: "zip", destinationFolderPath: "/tmp/dst",
            excludeJunk: true, reproducible: true, runInspection: true,
            writeChecksums: true, createSignedManifest: false
        )
    }

    @Test func roundTripUpsertAndDelete() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.save(preset("beta"))
        store.save(preset("alpha"))
        var all = store.loadAll()
        #expect(all.map(\.name) == ["alpha", "beta"])

        // 同名覆盖:同一项目重存 = 更新而非追加。
        store.save(preset("beta", fileName: "renamed"))
        all = store.loadAll()
        #expect(all.count == 2)
        #expect(all.first { $0.name == "beta" }?.fileName == "renamed")

        if let alpha = all.first(where: { $0.name == "alpha" }) {
            store.delete(id: alpha.id)
        }
        #expect(store.loadAll().map(\.name) == ["beta"])
    }
}
