//
//  iCloudSyncManagerTests.swift
//  XKeyTests
//

import XCTest
@testable import XKey

class MockKeyValueStore: KeyValueStoreProtocol {
    private var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? { storage[key] }

    func setData(_ data: Data?, forKey key: String) {
        storage[key] = data
    }

    @discardableResult func synchronize() -> Bool { true }
}

class iCloudSyncManagerTests: XCTestCase {

    private var mockStore: MockKeyValueStore!
    private var sut: iCloudSyncManager!

    override func setUp() {
        super.setUp()
        mockStore = MockKeyValueStore()
        sut = iCloudSyncManager(store: mockStore)
        UserDefaults.standard.removeObject(forKey: "XKey.iCloudSyncEnabled")
        UserDefaults.standard.removeObject(forKey: "XKey.lastCloudSyncDate")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "XKey.iCloudSyncEnabled")
        UserDefaults.standard.removeObject(forKey: "XKey.lastCloudSyncDate")
        sut = nil
        mockStore = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStatusIsDisabled() {
        XCTAssertEqual(sut.status, .disabled)
    }

    func testIsEnabledDefaultsFalse() {
        XCTAssertFalse(sut.isEnabled)
    }

    func testLastSyncDateDefaultsNil() {
        XCTAssertNil(sut.lastSyncDate)
    }

    // MARK: - Enable / Disable

    func testEnableSetsStatusToSyncedAfterPush() {
        sut.isEnabled = true
        XCTAssertEqual(sut.status, .synced)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "XKey.iCloudSyncEnabled"))
    }

    func testDisableSetsStatusToDisabled() {
        sut.isEnabled = true
        sut.isEnabled = false
        XCTAssertEqual(sut.status, .disabled)
    }

    func testEnableWritesDataToStore() {
        sut.isEnabled = true
        let data = mockStore.data(forKey: "XKey.syncedSettings")
        XCTAssertNotNil(data, "Enabling sync should push settings data to the store")
    }

    // MARK: - Push

    func testPushToCloudUpdatesLastSyncDate() {
        sut.isEnabled = true
        sut.pushToCloud()
        XCTAssertNotNil(sut.lastSyncDate)
    }

    func testPushToCloudSetsStatusSynced() {
        sut.isEnabled = true
        sut.pushToCloud()
        XCTAssertEqual(sut.status, .synced)
    }

    func testPushDoesNothingWhenDisabled() {
        sut.pushToCloud()
        XCTAssertEqual(sut.status, .disabled)
        XCTAssertNil(mockStore.data(forKey: "XKey.syncedSettings"))
    }

    // MARK: - Pull

    func testPullFromCloudImportsSettings() {
        sut.isEnabled = true
        sut.pushToCloud()

        sut.pullFromCloud()

        let exp = expectation(description: "main queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(sut.status, .synced)
    }

    func testPullUpdatesLastSyncDate() {
        sut.isEnabled = true
        sut.pushToCloud()
        let beforePull = sut.lastSyncDate

        Thread.sleep(forTimeInterval: 0.01)
        sut.pullFromCloud()

        let exp = expectation(description: "main queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertNotNil(sut.lastSyncDate)
        if let before = beforePull, let after = sut.lastSyncDate {
            XCTAssertGreaterThanOrEqual(after, before)
        }
    }

    // MARK: - Data Size

    func testSyncDataSizeBytesReturnsNilWhenEmpty() {
        XCTAssertNil(sut.syncDataSizeBytes)
    }

    func testSyncDataSizeBytesReturnsValueAfterPush() {
        sut.isEnabled = true
        sut.pushToCloud()
        XCTAssertNotNil(sut.syncDataSizeBytes)
        XCTAssertGreaterThan(sut.syncDataSizeBytes ?? 0, 0)
    }

    // MARK: - Setup

    func testSetupWhenDisabledStaysDisabled() {
        sut.setup()
        XCTAssertEqual(sut.status, .disabled)
    }

    func testSetupWhenEnabledSetsIdle() {
        UserDefaults.standard.set(true, forKey: "XKey.iCloudSyncEnabled")
        sut.setup()
        XCTAssertEqual(sut.status, .idle)
    }

    // MARK: - Round-trip

    func testRoundTripDataIsValidPlist() {
        sut.isEnabled = true
        sut.pushToCloud()

        let data = mockStore.data(forKey: "XKey.syncedSettings")
        XCTAssertNotNil(data)

        if let data = data {
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            XCTAssertNotNil(dict, "Pushed data should be a valid plist dictionary")
        }
    }

    // MARK: - Double Enable

    func testDoubleEnableDoesNotCrash() {
        sut.isEnabled = true
        sut.isEnabled = true
        XCTAssertEqual(sut.status, .synced)
    }
}
