import XCTest
@testable import Ech0Mac

@MainActor
final class MainWindowPresenterTests: XCTestCase {
    private final class TestWindow: MainWindowPresenting {
        enum Event: Equatable {
            case restoreFromDock
            case moveToActiveSpace
            case present
        }

        let isMiniaturizedForPresentation: Bool
        let isVisibleOnAllSpaces: Bool
        private(set) var events: [Event] = []

        init(isMiniaturized: Bool = false, isVisibleOnAllSpaces: Bool = false) {
            isMiniaturizedForPresentation = isMiniaturized
            self.isVisibleOnAllSpaces = isVisibleOnAllSpaces
        }

        func restoreFromDock() {
            events.append(.restoreFromDock)
        }

        func moveToActiveSpace() {
            events.append(.moveToActiveSpace)
        }

        func presentMainWindow() {
            events.append(.present)
        }
    }

    func testRequestsWindowRecreationWhenNoWindowExists() {
        let presenter = MainWindowPresenter()
        var recreationRequests = 0
        presenter.registerRecreationAction {
            recreationRequests += 1
        }

        presenter.show(existingWindow: nil)

        XCTAssertEqual(recreationRequests, 1)
    }

    func testShowsExistingWindowWithoutRequestingRecreation() {
        let presenter = MainWindowPresenter()
        var recreationRequests = 0
        presenter.registerRecreationAction {
            recreationRequests += 1
        }
        let window = TestWindow()

        presenter.show(existingWindow: window)

        XCTAssertEqual(window.events, [.moveToActiveSpace, .present])
        XCTAssertEqual(recreationRequests, 0)
    }

    func testRestoresMiniaturizedWindowBeforePresenting() {
        let presenter = MainWindowPresenter()
        let window = TestWindow(isMiniaturized: true)

        presenter.show(existingWindow: window)

        XCTAssertEqual(window.events, [.restoreFromDock, .moveToActiveSpace, .present])
    }

    func testKeepsAllSpacesWindowBehaviorWhenPresenting() {
        let presenter = MainWindowPresenter()
        let window = TestWindow(isVisibleOnAllSpaces: true)

        presenter.show(existingWindow: window)

        XCTAssertEqual(window.events, [.present])
    }
}
