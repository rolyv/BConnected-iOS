//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

final class AppVersionTest: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppVersionTest.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testProductVersionResetPreservesCompatibilityAndLaunchHistory() throws {
        let firstVersion = "8.30.0.2"
        let previousVersion = "8.30.0.3"
        userDefaults.set(firstVersion, forKey: "kNSUserDefaults_FirstAppVersion")
        userDefaults.set(previousVersion, forKey: "kNSUserDefaults_LastVersion")
        userDefaults.set(previousVersion, forKey: "kNSUserDefaults_LastCompletedLaunchAppVersion_MainApp")

        let appVersion = try makeVersion(marketingVersion: "0.1.0", buildNumber: "4", baseVersion: "8.30.0")
        XCTAssertEqual(appVersion.prettyAppVersion, "0.1.0 (4)")
        XCTAssertEqual(appVersion.currentAppVersion, "8.30.0.4")
        XCTAssertGreaterThan(appVersion.currentAppVersion4, try AppVersionNumber4(AppVersionNumber(previousVersion)))
        XCTAssertEqual(appVersion.firstAppVersion, firstVersion)
        XCTAssertEqual(appVersion.lastAppVersionForCrashDetection, previousVersion)
        XCTAssertEqual(appVersion.lastCompletedLaunchMainAppVersion, previousVersion)

        appVersion.updateFirstVersionIfNeeded()
        appVersion.updateLastVersionForCrashDetection()
        appVersion.mainAppLaunchDidComplete()
        appVersion.nseLaunchDidComplete()
        appVersion.saeLaunchDidComplete()

        // A later launch continues to use the compatibility namespace, which
        // must not be mistaken for a pre-6.16 build by legacy log cleanup.
        let restoredVersion = try makeVersion(marketingVersion: "0.1.0", buildNumber: "4", baseVersion: "8.30.0")
        XCTAssertEqual(restoredVersion.firstAppVersion, firstVersion)
        XCTAssertEqual(restoredVersion.lastAppVersionForCrashDetection, "8.30.0.4")
        XCTAssertEqual(restoredVersion.lastCompletedLaunchAppVersion, "8.30.0.4")
        XCTAssertEqual(restoredVersion.lastCompletedLaunchMainAppVersion, "8.30.0.4")
        XCTAssertEqual(restoredVersion.lastCompletedLaunchNSEAppVersion, "8.30.0.4")
        XCTAssertEqual(restoredVersion.lastCompletedLaunchSAEAppVersion, "8.30.0.4")
        XCTAssertGreaterThanOrEqual(AppVersionNumber(restoredVersion.lastCompletedLaunchMainAppVersion!), AppVersionNumber("6.16.0.0"))
    }

    func testAbsentCompatibilityVersionPreservesUpstreamVersionFormatting() throws {
        let twoPartVersion = try makeVersion(marketingVersion: "8.30", buildNumber: "4", baseVersion: nil)
        XCTAssertEqual(twoPartVersion.currentAppVersion, "8.30.0.4")
        XCTAssertEqual(twoPartVersion.prettyAppVersion, "8.30 (4)")

        let threePartVersion = try makeVersion(marketingVersion: "8.30.1", buildNumber: "5", baseVersion: nil)
        XCTAssertEqual(threePartVersion.currentAppVersion, "8.30.1.5")
        XCTAssertEqual(threePartVersion.prettyAppVersion, "8.30.1 (5)")
    }

    func testExplicitInvalidCompatibilityVersionDoesNotFallBackToProductVersion() {
        let invalidVersions: [Any] = [
            "", "8.30", "8.30.0.4", "8.30.x", "8.30.-1", "8.30.+0", "8.030.0", " 8.30.0",
            "8.30.0\n", "$(BCONNECTED_SIGNAL_BASE_VERSION)", 830, NSNull(),
        ]
        for invalidVersion in invalidVersions {
            XCTAssertThrowsError(try makeVersion(marketingVersion: "0.1.0", buildNumber: "4", baseVersion: invalidVersion))
        }
        XCTAssertNil(userDefaults.string(forKey: "kNSUserDefaults_FirstAppVersion"))
        XCTAssertNil(userDefaults.string(forKey: "kNSUserDefaults_LastCompletedLaunchAppVersion"))
    }

    private func makeVersion(marketingVersion: String, buildNumber: String, baseVersion: Any?) throws -> AppVersionImpl {
        try AppVersionImpl(
            marketingVersion: marketingVersion,
            buildNumber: buildNumber,
            signalBaseVersion: baseVersion,
            userDefaults: userDefaults,
            buildDate: Date(timeIntervalSince1970: 1_790_000_000),
        )
    }
}
