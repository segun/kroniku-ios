import XCTest
@testable import Kroniku

final class AuthServiceTests: XCTestCase {
    override func tearDownWithError() throws {
        try KeychainService.shared.deleteAll()
    }

    func testGetOrCreateClientDeviceIdIsStableAcrossCalls() throws {
        let service = AuthService.shared

        let first = try service.getOrCreateClientDeviceId()
        let second = try service.getOrCreateClientDeviceId()

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(try KeychainService.shared.retrieve(.clientDeviceId), first)
    }

    func testSaveAuthResponsePersistsSessionData() throws {
        let service = AuthService.shared
        let response = AuthResponse(
            accessToken: "jwt-token",
            user: User(id: "user-123", email: "me@example.com", retrievalOptIn: true),
            device: Device(id: "device-456", clientDeviceId: "client-device-789")
        )

        try service.saveAuthResponse(response, clientDeviceId: "client-device-789")

        XCTAssertEqual(try service.getAccessToken(), "jwt-token")
        XCTAssertEqual(try service.getUserId(), "user-123")
        XCTAssertEqual(try service.getUserEmail(), "me@example.com")
        XCTAssertTrue(try service.getRetrievalOptIn())
        XCTAssertEqual(try KeychainService.shared.retrieve(.clientDeviceId), "client-device-789")
        XCTAssertEqual(try KeychainService.shared.retrieve(.deviceId), "device-456")
    }
}
