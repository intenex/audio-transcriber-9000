import XCTest
@testable import AudioTranscriber

private final class FakeUbiquitousStore: UbiquitousStore {
    var storage: [String: Any] = [:]
    var synchronizeCount = 0

    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    @discardableResult func synchronize() -> Bool { synchronizeCount += 1; return true }
}

final class SyncedDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var cloud: FakeUbiquitousStore!
    private var synced: SyncedDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SyncedDefaults-\(UUID().uuidString)")!
        cloud = FakeUbiquitousStore()
        synced = SyncedDefaults(defaults: defaults, cloud: cloud)
    }

    func testInitialSyncPrefersLocalAndFillsMissingFromRemote() {
        defaults.set("MiniMax-M3", forKey: "miniMaxModel")        // local value exists
        cloud.storage["miniMaxModel"] = "MiniMax-M2-from-cloud"   // stale remote
        cloud.storage["openAIChatModel"] = "gpt-4o"               // no local value

        synced.activate()

        XCTAssertEqual(cloud.storage["miniMaxModel"] as? String, "MiniMax-M3",
                       "local wins the initial reconcile (pushed up)")
        XCTAssertEqual(defaults.string(forKey: "openAIChatModel"), "gpt-4o",
                       "remote fills keys the device never set")
    }

    func testLocalEditsPushToCloud() {
        synced.activate()
        defaults.set("aacCompact", forKey: "recordingFormat")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(cloud.storage["recordingFormat"] as? String, "aacCompact")
    }

    func testRemoteChangesPullIntoDefaults() {
        synced.activate()
        cloud.storage["diarizationClusteringThreshold"] = 0.9
        synced.pullRemoteChanges(Notification(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: ["diarizationClusteringThreshold"]]))
        XCTAssertEqual(defaults.double(forKey: "diarizationClusteringThreshold"), 0.9, accuracy: 0.001)
    }

    func testDeviceLocalKeysNeverSync() {
        defaults.set("/Users/someone/Library", forKey: "storageDirectory")
        defaults.set(true, forKey: "iCloudSyncEnabled")
        defaults.set(21.5, forKey: "rtf.local-fluidaudio")
        synced.activate()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertNil(cloud.storage["storageDirectory"])
        XCTAssertNil(cloud.storage["iCloudSyncEnabled"])
        XCTAssertNil(cloud.storage["rtf.local-fluidaudio"])
    }
}
