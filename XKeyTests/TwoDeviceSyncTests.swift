//
//  TwoDeviceSyncTests.swift
//  XKeyTests
//
//  Phase A device-to-device convergence harness. Models two Macs exchanging a single
//  per-entry-merge category through a shared "cloud" slot, exercising the REAL merge code
//  (SyncCollectionPayload.merged / prunedTombstones / liveEntries) and the REAL
//  SyncTombstoneStore against isolated UserDefaults.
//
//  The device's payload build/apply steps mirror iCloudSyncManager with source references:
//    - build  -> buildOutgoingEnvelope per-entry branch (iCloudSyncManager.swift L268-281)
//    - apply  -> applyEnvelope pull-merge (L343-365) + applyCollection (L414-435)
//  Echo-skip (deviceId match) is a manager-level optimization, not a convergence requirement:
//  applying one's own payload is idempotent, so the harness omits it without losing fidelity.
//
//  NOTE on timestamps: this harness assigns EXPLICIT per-entry timestamps and preserves them through
//  sync. Production instead RE-DERIVES each entry's updatedAt on every snapshot via a content-signature
//  cache (iCloudSyncManager.timestampProvider, L442-458) — the timestamp only bumps when the content
//  actually changes. The merge math is identical (SyncCollectionPayload.merged compares updatedAt), so
//  this harness faithfully exercises the CRDT/tombstone layer; the timestamp SOURCE and its wall-clock
//  / clock-skew behavior are a manager-level concern intentionally outside Phase A's scope.
//
//  Also: SyncTombstoneStore.prune and SyncCollectionPayload.prunedTombstones use `now = Date()`, so all
//  timestamps here are anchored near the current date via the at(seconds) helper. Using epoch dates
//  (e.g. 1970) would make every tombstone older than the 30-day retention and get pruned instantly.
//

import XCTest
@testable import XKey

// MARK: - Simulated device

/// One simulated Mac: an ordered live-entry store + its own tombstone store (isolated defaults).
private final class SyncDevice {
    let name: String
    let category: SyncCategory
    let tombstones: SyncTombstoneStore
    private var live: [SyncEntry] = []   // ordered; array position models rule cascade priority

    init(name: String, category: SyncCategory = .macros) {
        self.name = name
        self.category = category
        let suite = "XKeyTests.twoDevice.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        self.tombstones = SyncTombstoneStore(defaults: d)
    }

    // MARK: Local mutations

    /// Add a new entry or edit an existing one in place (preserving order). Clears any tombstone
    /// for the id so a re-add resurrects it — mirrors the UI add/edit path (updateMacro / updateCustomRule).
    func set(_ id: String, _ value: String, at: Date) {
        let entry = SyncEntry(id: id, updatedAt: at, deleted: false, data: Data(value.utf8))
        if let idx = live.firstIndex(where: { $0.id == id }) {
            live[idx] = entry
        } else {
            live.append(entry)
        }
        tombstones.remove(category: category, id: id)
    }

    /// Delete an entry: drop from live and record a tombstone — mirrors deleteMacro / deleteRule.
    func delete(_ id: String, at: Date) {
        live.removeAll { $0.id == id }
        tombstones.record(category: category, id: id, at: at)
    }

    /// Model drag-to-reorder the way the production fix does it: each rule's cascade position is
    /// written into its synced content (`sortIndex`, modeled here as the entry's data) and the
    /// entry timestamp is bumped. Because order now lives in synced content, it propagates by the
    /// same per-entry LWW as any edit — this is what makes reorder converge across devices.
    /// Mirrors AppBehaviorDetector.reorderCustomRules (writes index) + loadCustomRules (sorts on it).
    func reorder(_ ids: [String], at: Date) {
        for (index, id) in ids.enumerated() {
            set(id, String(index), at: at)
        }
    }

    // MARK: Payload build / apply

    /// Mirror of buildOutgoingEnvelope per-entry branch (iCloudSyncManager.swift L268-281):
    /// live entries + tombstones that are NOT currently live, pruned by retention.
    func outgoingPayload() -> SyncCollectionPayload {
        let liveEntries = live
        let liveIDs = Set(liveEntries.map { $0.id })
        let tombs = tombstones.tombstoneEntries(for: category).filter { !liveIDs.contains($0.id) }
        tombstones.prune(category: category)
        return SyncCollectionPayload(entries: liveEntries + tombs)
            .prunedTombstones(retention: category.tombstoneRetention)
    }

    /// Mirror of applyEnvelope pull-merge (L343-365) + applyCollection (L414-435).
    func apply(_ incoming: SyncCollectionPayload) {
        let local = SyncCollectionPayload(
            entries: live + tombstones.tombstoneEntries(for: category)
        )
        let merged = local.merged(with: incoming)
        // applyCollection: live store becomes the merged live entries (order preserved on reassemble).
        live = merged.liveEntries
        // Adopt remote tombstones, preserving their original deletion timestamps.
        for entry in merged.entries where entry.deleted {
            tombstones.record(category: category, id: entry.id, at: entry.updatedAt)
        }
        tombstones.prune(category: category)
    }

    // MARK: Inspection

    /// id -> value map of live entries (order-independent), for convergence assertions.
    func liveMap() -> [String: String] {
        var out = [String: String]()
        for e in live { out[e.id] = String(decoding: e.data ?? Data(), as: UTF8.self) }
        return out
    }

    /// Ordered live ids (for cascade-order assertions).
    func liveOrder() -> [String] { live.map { $0.id } }

    /// Cascade order derived from the synced sortIndex (modeled as the entry's data), tie-broken
    /// by id. Mirrors AppBehaviorDetector.loadCustomRules' sort, which is what makes reorder
    /// converge: the order is a pure function of synced content, not local array position.
    func orderBySortIndex() -> [String] {
        live.sorted {
            let l = Int(String(decoding: $0.data ?? Data(), as: UTF8.self)) ?? Int.max
            let r = Int(String(decoding: $1.data ?? Data(), as: UTF8.self)) ?? Int.max
            return (l, $0.id) < (r, $1.id)
        }.map { $0.id }
    }
}

// MARK: - Fake cloud (single slot per category = KVS last-writer-wins)

private final class FakeCloud {
    private var slots: [SyncCategory: SyncCollectionPayload] = [:]
    func read(_ c: SyncCategory) -> SyncCollectionPayload? { slots[c] }
    /// Overwrite — models kvStore.setData replacing the whole category blob.
    func write(_ c: SyncCategory, _ p: SyncCollectionPayload) { slots[c] = p }
}

// MARK: - Sync operations

/// Push-only (the OLD "Đồng bộ ngay" button): overwrite the cloud with this device's payload.
private func pushOnly(_ d: SyncDevice, _ cloud: FakeCloud) {
    cloud.write(d.category, d.outgoingPayload())
}

/// Pull-merge: merge whatever the cloud currently holds into this device.
private func pull(_ d: SyncDevice, _ cloud: FakeCloud) {
    if let p = cloud.read(d.category) { d.apply(p) }
}

/// Bidirectional sync (the FIXED button / mergeAll): pull-merge first, then push the merged result.
private func syncNow(_ d: SyncDevice, _ cloud: FakeCloud) {
    pull(d, cloud)
    pushOnly(d, cloud)
}

// MARK: - Tests

final class TwoDeviceSyncTests: XCTestCase {

    private var cloud: FakeCloud!
    private var a: SyncDevice!
    private var b: SyncDevice!
    private var base: Date!

    override func setUp() {
        super.setUp()
        cloud = FakeCloud()
        a = SyncDevice(name: "A")
        b = SyncDevice(name: "B")
        base = Date()
    }

    override func tearDown() {
        a.tombstones.clearAll()
        b.tombstones.clearAll()
        cloud = nil; a = nil; b = nil; base = nil
        super.tearDown()
    }

    /// Offset helper so LWW ordering is explicit while staying within the retention window.
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private func assertConverged(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.liveMap(), b.liveMap(), "devices did not converge", file: file, line: line)
    }

    /// Seed both devices with the same entry and get them into a synced steady state.
    private func seedShared(_ id: String, _ value: String) {
        a.set(id, value, at: at(0))
        syncNow(a, cloud)
        syncNow(b, cloud)
    }

    // MARK: #1 / #2 — delete propagates both directions

    func testDeleteOnAPropagatesToB() {
        seedShared("test", "v")
        XCTAssertEqual(b.liveMap()["test"], "v")

        a.delete("test", at: at(2))
        syncNow(a, cloud)
        syncNow(b, cloud)

        XCTAssertNil(a.liveMap()["test"])
        XCTAssertNil(b.liveMap()["test"], "delete on A must remove it on B")
        assertConverged()
    }

    func testDeleteOnBPropagatesToA() {
        seedShared("test", "v")

        b.delete("test", at: at(2))
        syncNow(b, cloud)
        syncNow(a, cloud)

        XCTAssertNil(a.liveMap()["test"], "delete on B must remove it on A")
        XCTAssertNil(b.liveMap()["test"])
        assertConverged()
    }

    // MARK: #3 — edit propagates

    func testEditPropagates() {
        seedShared("x", "1")

        a.set("x", "2", at: at(2))
        syncNow(a, cloud)
        syncNow(b, cloud)

        XCTAssertEqual(b.liveMap()["x"], "2", "edit on A must reach B")
        assertConverged()
    }

    // MARK: #4 — disjoint adds union

    func testDisjointAddsUnion() {
        a.set("x", "A", at: at(1))
        b.set("y", "B", at: at(1))

        syncNow(a, cloud)   // cloud: x
        syncNow(b, cloud)   // b pulls x, pushes x+y
        syncNow(a, cloud)   // a pulls y

        XCTAssertEqual(a.liveMap(), ["x": "A", "y": "B"])
        assertConverged()
    }

    // MARK: #5 / #12 — concurrent edit/add, last-write-wins

    func testConcurrentEditLastWriteWins() {
        seedShared("x", "0")

        a.set("x", "fromA", at: at(1))
        b.set("x", "fromB", at: at(2))   // B is newer

        syncNow(a, cloud)
        syncNow(b, cloud)
        syncNow(a, cloud)

        XCTAssertEqual(a.liveMap()["x"], "fromB", "newer write must win")
        assertConverged()
    }

    func testConcurrentAddSameKeyDifferentValue() {
        a.set("x", "A", at: at(1))
        b.set("x", "B", at: at(2))       // B newer

        syncNow(a, cloud)
        syncNow(b, cloud)
        syncNow(a, cloud)

        XCTAssertEqual(a.liveMap()["x"], "B")
        assertConverged()
    }

    // MARK: #6 / #7 — delete vs edit races

    func testDeleteBeatsOlderEdit() {
        seedShared("x", "1")

        b.set("x", "2", at: at(2))
        a.delete("x", at: at(3))         // delete is newer

        syncNow(b, cloud)
        syncNow(a, cloud)
        syncNow(b, cloud)                // extra round for eventual consistency

        XCTAssertNil(a.liveMap()["x"], "newer delete must win over older edit")
        XCTAssertNil(b.liveMap()["x"])
        assertConverged()
    }

    func testEditBeatsOlderDelete() {
        seedShared("x", "1")

        a.delete("x", at: at(2))
        b.set("x", "2", at: at(3))       // edit is newer

        syncNow(b, cloud)
        syncNow(a, cloud)
        syncNow(b, cloud)

        XCTAssertEqual(a.liveMap()["x"], "2", "newer edit must win over older delete")
        assertConverged()
    }

    // MARK: #8 — delete then re-add resurrects

    func testReAddAfterDeleteResurrects() {
        seedShared("x", "1")

        a.delete("x", at: at(2))
        syncNow(a, cloud)
        syncNow(b, cloud)
        XCTAssertNil(b.liveMap()["x"])   // delete landed

        b.set("x", "2", at: at(4))       // re-add on B, newer than the tombstone
        syncNow(b, cloud)
        syncNow(a, cloud)

        XCTAssertEqual(a.liveMap()["x"], "2", "re-add newer than tombstone must resurrect")
        assertConverged()
    }

    // MARK: #9 — reorder DOES converge cross-device (synced sortIndex)

    func testReorderConvergesCrossDevice() {
        let rulesA = SyncDevice(name: "rA", category: .rules)
        let rulesB = SyncDevice(name: "rB", category: .rules)
        let sky = FakeCloud()
        // Seed identical synced order via sortIndex (data = index string), then steady-state sync.
        rulesA.reorder(["r1", "r2", "r3"], at: at(0))
        syncNow(rulesA, sky)
        syncNow(rulesB, sky)
        XCTAssertEqual(rulesB.orderBySortIndex(), ["r1", "r2", "r3"])

        // Each device reorders differently; B's reorder is strictly newer, so it wins by LWW.
        rulesA.reorder(["r1", "r2", "r3"], at: at(10))
        rulesB.reorder(["r3", "r2", "r1"], at: at(20))
        syncNow(rulesA, sky)
        syncNow(rulesB, sky)
        syncNow(rulesA, sky)   // extra round for eventual consistency

        // Order is now encoded in synced content, so it converges to the newer write on both devices.
        XCTAssertEqual(rulesA.orderBySortIndex(), rulesB.orderBySortIndex(), "order must converge")
        XCTAssertEqual(rulesB.orderBySortIndex(), ["r3", "r2", "r1"], "newer reorder must win")
        XCTAssertEqual(rulesA.orderBySortIndex(), ["r3", "r2", "r1"], "A adopts the newer order")
        rulesA.tombstones.clearAll(); rulesB.tombstones.clearAll()
    }

    // MARK: #10 — tombstone past retention is pruned (entry may resurrect from a peer)

    func testStaleTombstonePrunedAllowsResurrection() {
        // B holds x live, set long ago. A deleted x AFTER that (a NEWER tombstone) but the delete is
        // now older than the 30-day retention window. Pruning drops A's stale tombstone, so on the
        // next sync B's live x resurrects on A. Without pruning the newer tombstone would suppress it
        // by last-write-wins — this isolates pruning as the cause, not LWW.
        b.set("x", "1", at: at(-50 * 24 * 3600))
        syncNow(b, cloud)                          // cloud: x live @ -50d
        a.delete("x", at: at(-40 * 24 * 3600))     // tombstone newer than the live entry, but > 30d old

        syncNow(a, cloud)   // a prunes its stale tombstone during apply/build
        syncNow(b, cloud)   // b re-pushes x live
        syncNow(a, cloud)   // a pulls x live -> resurrects (the retention tradeoff)

        XCTAssertEqual(a.liveMap()["x"], "1",
                       "a stale (pruned) tombstone must not suppress a peer's live entry")
        assertConverged()
    }

    // MARK: #11 — bidirectional syncNow vs push-only button

    func testSyncNowPropagatesPeerDelete() {
        seedShared("test", "v")

        a.delete("test", at: at(2))
        syncNow(a, cloud)            // cloud now carries the tombstone

        syncNow(b, cloud)            // FIXED button: B pulls the tombstone first
        XCTAssertNil(b.liveMap()["test"], "syncNow must adopt the peer's delete")
    }

    func testPushOnlyButtonClobbersPeerDelete_documentsOldBug() {
        seedShared("test", "v")

        a.delete("test", at: at(2))
        syncNow(a, cloud)            // cloud carries the tombstone

        // OLD push-only behavior: B overwrites the cloud with its still-live entry, erasing the
        // tombstone — the delete never reaches B and is undone for everyone. This is the bug the
        // bidirectional syncNow() fix addresses; asserted here to lock in the rationale.
        pushOnly(b, cloud)
        XCTAssertEqual(b.liveMap()["test"], "v", "push-only leaves B's stale entry in place")
        XCTAssertEqual(cloud.read(.macros)?.liveEntries.first?.id, "test",
                       "push-only resurrected the entry in the cloud")
    }
}
