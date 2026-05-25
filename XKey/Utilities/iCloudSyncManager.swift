//
//  iCloudSyncManager.swift
//  XKey
//
//  Syncs settings to/from iCloud via NSUbiquitousKeyValueStore
//

import Foundation

enum iCloudSyncStatus: Equatable {
    case disabled
    case idle
    case pushing
    case pulling
    case synced
    case error(String)
}

protocol KeyValueStoreProtocol: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStoreProtocol {
    func setData(_ data: Data?, forKey key: String) {
        set(data, forKey: key)
    }
}

class iCloudSyncManager {

    static let shared = iCloudSyncManager()

    private let kvStore: KeyValueStoreProtocol
    private let syncKey = "XKey.syncedSettings"
    private var pushTimer: Timer?
    private var isPulling = false
    private var isObserving = false

    private let enabledKey = "XKey.iCloudSyncEnabled"

    private(set) var status: iCloudSyncStatus = .disabled

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            let wasEnabled = isEnabled
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue && !wasEnabled {
                status = .idle
                startObserving()
                pushToCloud()
            } else if !newValue && wasEnabled {
                stopObserving()
                status = .disabled
                notifyStatusChanged()
            }
        }
    }

    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: "XKey.lastCloudSyncDate") as? Date
    }

    var syncDataSizeBytes: Int? {
        kvStore.data(forKey: syncKey)?.count
    }

    private init() {
        self.kvStore = NSUbiquitousKeyValueStore.default
    }

    init(store: KeyValueStoreProtocol) {
        self.kvStore = store
    }

    func setup() {
        guard isEnabled else {
            status = .disabled
            return
        }
        status = .idle
        startObserving()
        kvStore.synchronize()
    }

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvStoreDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localSettingsDidChange),
            name: .sharedSettingsDidChange,
            object: nil
        )
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false

        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .sharedSettingsDidChange,
            object: nil
        )
        pushTimer?.invalidate()
        pushTimer = nil
    }

    @objc private func localSettingsDidChange() {
        schedulePush()
    }

    private func schedulePush() {
        guard isEnabled, !isPulling else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pushTimer?.invalidate()
            self.pushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.pushToCloud()
            }
        }
    }

    func pushToCloud() {
        guard isEnabled, !isPulling else { return }
        guard let data = SharedSettings.shared.exportSettingsForSync() else {
            status = .error(String(localized: "Không thể đọc thiết lập"))
            notifyStatusChanged()
            return
        }
        status = .pushing
        notifyStatusChanged()
        kvStore.setData(data, forKey: syncKey)
        kvStore.synchronize()
        UserDefaults.standard.set(Date(), forKey: "XKey.lastCloudSyncDate")
        status = .synced
        sharedLogSuccess("Settings pushed to iCloud (\(data.count) bytes)")
        notifyStatusChanged()
    }

    @objc private func kvStoreDidChange(_ notification: Notification) {
        guard isEnabled else { return }

        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }

        guard changedKeys.contains(syncKey) else { return }

        switch reason {
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange:
            pullFromCloud()
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            status = .error(String(localized: "Vượt giới hạn 1MB iCloud"))
            sharedLogWarning("iCloud KVS quota exceeded — sync paused")
            notifyStatusChanged()
        default:
            break
        }
    }

    func pullFromCloud() {
        guard let data = kvStore.data(forKey: syncKey) else { return }

        let apply = { [weak self] in
            guard let self = self else { return }
            self.isPulling = true
            self.status = .pulling
            self.notifyStatusChanged()
            SharedSettings.shared.importSettingsForSync(from: data)
            self.isPulling = false
            UserDefaults.standard.set(Date(), forKey: "XKey.lastCloudSyncDate")
            self.status = .synced
            sharedLogSuccess("Settings pulled from iCloud (\(data.count) bytes)")
            self.notifyStatusChanged()
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func exportCloudData() -> Data? {
        guard let binary = kvStore.data(forKey: syncKey),
              let dict = try? PropertyListSerialization.propertyList(from: binary, format: nil) as? [String: Any] else {
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func notifyStatusChanged() {
        NotificationCenter.default.post(name: .iCloudSyncStatusDidChange, object: nil)
    }
}

extension Notification.Name {
    static let iCloudSyncStatusDidChange = Notification.Name("XKey.iCloudSyncStatusDidChange")
}
