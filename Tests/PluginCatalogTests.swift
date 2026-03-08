import XCTest
@testable import MacAudio

final class PluginCatalogTests: XCTestCase {
    func testNormalizedManualPathsTrimDeduplicateAndSort() {
        let paths = ManualPluginPathStore.normalizedPaths([
            "  /tmp/Beta  ",
            "/tmp/Alpha",
            "/tmp/Alpha/..//Alpha"
        ])

        XCTAssertEqual(paths, ["/tmp/Alpha", "/tmp/Beta"])
    }

    func testScanBundlePluginsFindsLegacyVSTAndVST3Bundles() throws {
        let tempRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vst2 = try makeFakePluginBundle(at: tempRoot.appendingPathComponent("VintageVerb.vst"), name: "VintageVerb", identifier: "com.example.vintageverb")
        let vst3 = try makeFakePluginBundle(at: tempRoot.appendingPathComponent("ModernComp.vst3"), name: "ModernComp", identifier: "com.example.moderncomp")

        let vst2Plugins = PluginCatalog.scanBundlePlugins(in: [tempRoot], format: .vst2)
        let vst3Plugins = PluginCatalog.scanBundlePlugins(in: [tempRoot], format: .vst3)

        XCTAssertEqual(vst2Plugins.count, 1)
        XCTAssertEqual(vst3Plugins.count, 1)
        XCTAssertEqual(vst2Plugins.first?.bundlePath, vst2.path)
        XCTAssertEqual(vst3Plugins.first?.bundlePath, vst3.path)
        XCTAssertEqual(vst2Plugins.first?.name, "VintageVerb")
        XCTAssertEqual(vst3Plugins.first?.name, "ModernComp")
    }

    func testScanAvailablePluginsHonorsManualBundlePaths() throws {
        let tempRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let directVST2 = try makeFakePluginBundle(at: tempRoot.appendingPathComponent("DirectEQ.vst"), name: "DirectEQ", identifier: "com.example.directeq")
        let nestedDir = tempRoot.appendingPathComponent("CustomRack", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        _ = try makeFakePluginBundle(at: nestedDir.appendingPathComponent("DirectLimiter.vst3"), name: "DirectLimiter", identifier: "com.example.directlimiter")

        let plugins = PluginCatalog.scanAvailablePlugins(manualPaths: [directVST2.path, nestedDir.path, directVST2.path])
        let names = Set(plugins.map(\.name))

        XCTAssertTrue(names.contains("DirectEQ"))
        XCTAssertTrue(names.contains("DirectLimiter"))
        XCTAssertEqual(plugins.filter { $0.name == "DirectEQ" }.count, 1)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeFakePluginBundle(at url: URL, name: String, identifier: String) throws -> URL {
        let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleName": name,
            "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return url.standardizedFileURL
    }
}
