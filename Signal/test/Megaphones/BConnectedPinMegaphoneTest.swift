// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import Signal
@testable import SignalServiceKit

final class BConnectedPinMegaphoneTest: XCTestCase {
    private let store = ExperienceUpgradeStore()
    private let pinManifests: Set<ExperienceUpgradeManifest> = [.introducingPins, .pinReminder]

    func testUnsupportedPinPromptsAreNotCandidatesForNewAccount() {
        let db = makeInMemoryDB()

        let selected = candidates(db: db, capabilities: .chatOnly)

        XCTAssertEqual(Set(selected.map(\.manifest)),
                       ExperienceUpgradeManifest.wellKnownLocalUpgradeManifests.subtracting(pinManifests))
        XCTAssertTrue(storedUpgrades(db: db).isEmpty, "Filtering must not persist completed or snoozed prompts.")
    }

    func testSavedPinPromptsAndPreferencesSurviveUnsupportedTransport() throws {
        let db = makeInMemoryDB()
        let pinPreferences = NewKeyValueStore(collection: "2FA")
        try db.write { tx in
            for manifest in pinManifests {
                let upgrade = ExperienceUpgrade.makeNew(withManifest: manifest)
                upgrade.firstViewedTimestamp = 100
                upgrade.lastSnoozedTimestamp = 200
                upgrade.snoozeCount = 2
                try upgrade.upsert(tx: tx)
            }
            pinPreferences.writeValue("2468", forKey: "PinCode", tx: tx)
            pinPreferences.writeValue(true, forKey: "HasEverHadPin", tx: tx)
            pinPreferences.writeValue(true, forKey: "AreRemindersEnabled", tx: tx)
            pinPreferences.writeValue(604800.0, forKey: "RepetitionInterval", tx: tx)
        }

        XCTAssertTrue(Set(candidates(db: db, capabilities: .chatOnly).map(\.manifest)).isDisjoint(with: pinManifests))

        let stored = storedUpgrades(db: db)
        XCTAssertEqual(Set(stored.map(\.manifest)), pinManifests)
        for upgrade in stored {
            XCTAssertFalse(upgrade.isComplete)
            XCTAssertEqual(upgrade.firstViewedTimestamp, 100)
            XCTAssertEqual(upgrade.lastSnoozedTimestamp, 200)
            XCTAssertEqual(upgrade.snoozeCount, 2)
        }
        db.read { tx in
            XCTAssertEqual(pinPreferences.fetchValue(String.self, forKey: "PinCode", tx: tx), "2468")
            XCTAssertEqual(pinPreferences.fetchValue(Bool.self, forKey: "HasEverHadPin", tx: tx), true)
            XCTAssertEqual(pinPreferences.fetchValue(Bool.self, forKey: "AreRemindersEnabled", tx: tx), true)
            XCTAssertEqual(pinPreferences.fetchValue(Double.self, forKey: "RepetitionInterval", tx: tx), 604800)
        }

        let restored = candidates(db: db, capabilities: .legacy).filter { pinManifests.contains($0.manifest) }
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.allSatisfy { !$0.isComplete && $0.firstViewedTimestamp == 100 && $0.snoozeCount == 2 })
    }

    func testLegacyCandidatesChangeOnlyWhenSecureValueRecoveryIsRemoved() {
        let db = makeInMemoryDB()
        let legacy = candidates(db: db, capabilities: .legacy)
        XCTAssertEqual(Set(legacy.map(\.manifest)), ExperienceUpgradeManifest.wellKnownLocalUpgradeManifests)

        let withoutSvr = BConnectedTransportCapabilities.legacy.restricted(
            to: Set(BConnectedTransportCapability.allCases).subtracting([.secureValueRecovery]),
        )
        let restricted = candidates(db: db, capabilities: withoutSvr)
        XCTAssertEqual(restricted.map(\.manifest), legacy.filter { !pinManifests.contains($0.manifest) }.map(\.manifest))
        XCTAssertTrue(storedUpgrades(db: db).isEmpty)
    }

    private func candidates(db: InMemoryDB, capabilities: BConnectedTransportCapabilities) -> [ExperienceUpgrade] {
        db.read { tx in
            ExperienceUpgradeManager.experienceUpgradeCandidates(
                experienceUpgradeStore: store,
                transportCapabilities: capabilities,
                tx: tx,
            )
        }
    }

    private func storedUpgrades(db: InMemoryDB) -> [ExperienceUpgrade] {
        db.read { tx in
            var upgrades = [ExperienceUpgrade]()
            store.enumerateExperienceUpgrades(tx: tx) { upgrades.append($0) }
            return upgrades
        }
    }

    private func makeInMemoryDB() -> InMemoryDB {
        let originalContext = CurrentAppContext()
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        defer { SetCurrentAppContext(originalContext, isRunningTests: true) }
        return InMemoryDB()
    }
}
