import CoreGraphics
import XCTest
@testable import MacAudio

@MainActor
final class RackGraphTests: XCTestCase {
    func testFirstRackBoxDefaultsInputToThatBox() {
        let viewModel = MainViewModel(scanPluginsOnInit: false)

        viewModel.addRackBox()
        let firstID = try! XCTUnwrap(viewModel.rackBoxes.first?.id)

        XCTAssertEqual(viewModel.inputRouteTarget, .box(firstID))
        XCTAssertEqual(viewModel.rackBoxes[0].routeTarget, .output)
    }

    func testMoveRackBoxClampsIntoCanvasBounds() {
        let viewModel = MainViewModel(scanPluginsOnInit: false)
        viewModel.addRackBox()
        let id = try! XCTUnwrap(viewModel.rackBoxes.first?.id)

        viewModel.moveRackBox(id, to: CGPoint(x: -100, y: -100), in: CGSize(width: 900, height: 500))

        let moved = try! XCTUnwrap(viewModel.rackBoxes.first)
        XCTAssertGreaterThan(moved.position.x, 0)
        XCTAssertGreaterThan(moved.position.y, 0)
    }

    func testRouteOptionsExcludeCycleTargets() {
        let viewModel = MainViewModel(scanPluginsOnInit: false)

        viewModel.addRackBox()
        viewModel.addRackBox()
        viewModel.addRackBox()

        let first = viewModel.rackBoxes[0].id
        let second = viewModel.rackBoxes[1].id
        let third = viewModel.rackBoxes[2].id

        viewModel.setRouteTarget(.box(second), for: first)
        viewModel.setRouteTarget(.box(third), for: second)

        let options = viewModel.routeOptions(for: third)

        XCTAssertFalse(options.contains(where: { $0.destination == .box(first) }))
        XCTAssertFalse(options.contains(where: { $0.destination == .box(second) }))
        XCTAssertTrue(options.contains(where: { $0.destination == .output }))
    }

    func testAddRackBoxAndChoosePluginOpensChooserForNewBox() {
        let viewModel = MainViewModel(scanPluginsOnInit: false)

        viewModel.addRackBoxAndChoosePlugin()

        let firstID = try! XCTUnwrap(viewModel.rackBoxes.first?.id)
        let target = try! XCTUnwrap(viewModel.pluginBrowserTarget)
        XCTAssertEqual(target.slotID, firstID)
        XCTAssertTrue(target.removeIfCancelled)
    }

    func testCancellingNewPluginChooserRemovesEmptyBox() {
        let viewModel = MainViewModel(scanPluginsOnInit: false)

        viewModel.addRackBoxAndChoosePlugin()
        let target = try! XCTUnwrap(viewModel.pluginBrowserTarget)

        viewModel.finishPluginBrowserSelection(for: target, committed: false)

        XCTAssertTrue(viewModel.rackBoxes.isEmpty)
        XCTAssertNil(viewModel.pluginBrowserTarget)
    }

    func testMatchedAudioUnitFallbackEnablesEditorButtonForVST() {
        let viewModel = MainViewModel(scanPluginsOnInit: false)
        let vst = PluginDescriptor(
            id: "vst3:/Library/Audio/Plug-Ins/VST3/TDR Nova.vst3",
            name: "TDR Nova",
            vendor: "com.TokyoDawnLabs.TDRNova",
            format: .vst3,
            category: "VST3 Plug-In",
            location: "VST3",
            bundlePath: "/Library/Audio/Plug-Ins/VST3/TDR Nova.vst3"
        )
        let au = PluginDescriptor(
            id: "au:1635083896.1415853409.1415869036",
            name: "TDR Nova",
            vendor: "Tokyo Dawn Labs",
            format: .audioUnit,
            category: "Audio Unit",
            location: "Components",
            bundlePath: "/Library/Audio/Plug-Ins/Components/TDR Nova.component"
        )

        viewModel.availablePlugins = [vst, au]
        viewModel.addRackBox()
        let boxID = try! XCTUnwrap(viewModel.rackBoxes.first?.id)
        viewModel.assignPlugin(vst, to: boxID)

        XCTAssertTrue(viewModel.canOpenPluginEditor(for: boxID))
        XCTAssertEqual(viewModel.editorButtonTitle(for: boxID), "AU UI")
    }

    func testRemovingRackBoxDismissesEditorSession() {
        let viewModel = MainViewModel(scanPluginsOnInit: false)
        let plugin = PluginDescriptor(
            id: "au:1.2.3",
            name: "Test EQ",
            vendor: "Vendor",
            format: .audioUnit,
            category: "Audio Unit",
            location: "Components",
            bundlePath: "/Library/Audio/Plug-Ins/Components/Test EQ.component"
        )

        viewModel.addRackBox()
        let box = try! XCTUnwrap(viewModel.rackBoxes.first)
        viewModel.assignPlugin(plugin, to: box.id)
        viewModel.pluginEditorSession = PluginEditorSession(
            boxID: box.id,
            boxTitle: box.title,
            assignedPlugin: plugin,
            editorPlugin: plugin,
            liveAudioUnit: nil
        )

        viewModel.removeRackBox(box.id)

        XCTAssertNil(viewModel.pluginEditorSession)
    }
}
