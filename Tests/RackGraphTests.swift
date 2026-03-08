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
}
