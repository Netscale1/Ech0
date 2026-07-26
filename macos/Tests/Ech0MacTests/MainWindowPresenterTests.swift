import XCTest
@testable import Ech0Mac

@MainActor
final class MainWindowPresenterTests: XCTestCase {
    private final class TestWindow: MainWindowPresenting {
        private(set) var presentationCount = 0

        func presentMainWindow() {
            presentationCount += 1
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

        XCTAssertEqual(window.presentationCount, 1)
        XCTAssertEqual(recreationRequests, 0)
    }
}
