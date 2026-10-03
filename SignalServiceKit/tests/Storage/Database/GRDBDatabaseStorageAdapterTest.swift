//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import XCTest

final class GRDBDatabaseStorageAdapterTest: XCTestCase {
    func testWalFileUrl() throws {
        let input = URL(fileURLWithPath: "/tmp/foo.db")
        let expected = URL(fileURLWithPath: "/tmp/foo.db-wal")
        let actual = GRDBDatabaseStorageAdapter.walFileUrl(for: input)
        XCTAssertEqual(actual, expected)
    }

    func testShmFileUrl() throws {
        let input = URL(fileURLWithPath: "/tmp/foo.db")
        let expected = URL(fileURLWithPath: "/tmp/foo.db-shm")
        let actual = GRDBDatabaseStorageAdapter.shmFileUrl(for: input)
        XCTAssertEqual(actual, expected)
    }

    func testDiagnosticIsReadOnlyAndDoesNotDiscloseNamesPathsOrDatabaseContents() throws {
        try withDiagnosticDirectory { base in
            let folder = "grdb_00000000-1111-2222-3333-444444444444"
            let secret = Data("private-token +13055550123 Private Alumni Name".utf8)
            try makeDiagnosticDatabase(base, folder: folder, contents: secret)
            try makeDiagnosticDatabase(base, folder: "grdb", contents: Data(repeating: 0, count: 1_048_576))
            try FileManager.default.createDirectory(at: base.appendingPathComponent("grdb_empty"), withIntermediateDirectories: false)
            try Data(folder.utf8).write(to: base.appendingPathComponent("storedPrimaryFolderName.txt"))
            let before = try diagnosticSnapshot(base)

            let report = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: folder)

            XCTAssertEqual(report.selectedFolder, .customFolder)
            XCTAssertEqual(report.selectorSource, .file)
            XCTAssertEqual(report.selectorFile, .valid)
            XCTAssertEqual(report.defaultsSelectorMatchesFile, true)
            XCTAssertEqual(report.selectedDatabase.state, .present)
            XCTAssertEqual(report.selectedDatabase.sizeBytes, UInt64(secret.count))
            XCTAssertEqual(report.alternateDirectoryCount, 2)
            XCTAssertTrue(report.alternateDatabases.contains { $0.state == .missing })
            XCTAssertTrue(report.alternateDatabases.contains { $0.sizeCategory == .oneToTenMiB })
            XCTAssertTrue(report.alternateDatabases.allSatisfy { $0.sizeBytes == nil })
            for value in [base.path, folder, "00000000-1111-2222-3333-444444444444", "private-token", "+13055550123", "Private Alumni Name"] {
                XCTAssertFalse(report.sanitizedDescription.contains(value))
            }
            XCTAssertNoThrow(try JSONDecoder().decode(BConnectedDatabaseDiagnostics.Report.self,
                from: Data(report.sanitizedDescription.utf8)))
            let disagreeingDefaults = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: "grdb")
            XCTAssertEqual(disagreeingDefaults.defaultsSelectorMatchesFile, false)
            XCTAssertEqual(disagreeingDefaults.selectorSource, .file)
            XCTAssertEqual(disagreeingDefaults.selectedDatabase.sizeBytes, UInt64(secret.count))
            XCTAssertEqual(try diagnosticSnapshot(base), before)
        }
    }

    func testDiagnosticDefaultsFallbackDoesNotRepairMissingSelectorOrCreateDatabase() throws {
        try withDiagnosticDirectory { base in
            let before = try diagnosticSnapshot(base)
            let report = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: "grdb_custom")
            XCTAssertEqual(report.selectorFile, .missing)
            XCTAssertEqual(report.selectorSource, .defaults)
            XCTAssertEqual(report.selectedFolder, .customFolder)
            XCTAssertEqual(report.defaultsSelectorPresent, true)
            XCTAssertEqual(report.defaultsSelectorValid, true)
            XCTAssertNil(report.defaultsSelectorMatchesFile)
            XCTAssertEqual(report.selectedDatabase.state, .missing)
            XCTAssertEqual(try diagnosticSnapshot(base), before)

            let fallback = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: nil)
            XCTAssertEqual(fallback.selectorSource, .defaultFallback)
            XCTAssertEqual(fallback.selectedFolder, .defaultFolder)
            XCTAssertEqual(try diagnosticSnapshot(base), before)
        }
    }

    func testDiagnosticUnavailableReadsAreNotSuccessfulEmptyScans() throws {
        try withDiagnosticDirectory { base in
            let empty = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: nil)
            XCTAssertEqual(empty.alternateScan, .complete)
            XCTAssertEqual(empty.alternateDirectoryCount, 0)

            let files = DiagnosticFileManager()
            files.failListing = true
            let unavailable = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: nil, fileManager: files)
            XCTAssertEqual(unavailable.alternateScan, .unavailable)
            XCTAssertNil(unavailable.alternateDirectoryCount)
            XCTAssertFalse(unavailable.sanitizedDescription.contains("private-error-path"))

            files.failListing = false
            files.failSelectorMetadata = true
            let unreadable = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: "grdb", fileManager: files)
            XCTAssertEqual(unreadable.selectorFile, .unreadable)
            XCTAssertEqual(unreadable.selectorSource, .unavailable)
            XCTAssertEqual(unreadable.selectedDatabase.state, .notInspected)

            let missingBase = BConnectedDatabaseDiagnostics.report(baseDirectory: base.appendingPathComponent("missing"), defaultsSelector: nil)
            XCTAssertEqual(missingBase.baseDirectory, .missing)
            XCTAssertEqual(missingBase.alternateScan, .notInspected)
            XCTAssertNil(missingBase.alternateDirectoryCount)
        }
    }

    func testDiagnosticRejectsTraversalOversizedAndNonUtf8Selectors() throws {
        try withDiagnosticDirectory { base in
            let selector = base.appendingPathComponent("storedPrimaryFolderName.txt")
            for content in [Data("grdb/../../private-token".utf8), Data(repeating: 97, count: 1025), Data([0xff]), Data()] {
                try content.write(to: selector)
                let report = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: "grdb")
                XCTAssertEqual(report.selectorFile, .invalid)
                XCTAssertEqual(report.selectedDatabase.state, .notInspected)
                XCTAssertFalse(report.sanitizedDescription.contains("private-token"))
                XCTAssertEqual(try Data(contentsOf: selector), content)
            }
            try FileManager.default.removeItem(at: selector)
            for name in ["../grdb", "grdb/other", "grdb\\other", "grdb" + String(repeating: "x", count: 1024)] {
                let report = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: name)
                XCTAssertEqual(report.defaultsSelectorValid, false)
                XCTAssertEqual(report.selectedFolder, .unsafe)
                XCTAssertEqual(report.selectedDatabase.state, .notInspected)
            }
        }
    }

    func testDiagnosticDoesNotFollowSelectorDirectoryOrDatabaseSymlinks() throws {
        try withDiagnosticDirectory { base in
            let target = base.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try Data("private-token".utf8).write(to: target.appendingPathComponent("signal.sqlite"))
            try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("grdb_link"), withDestinationURL: target)
            let linkedBase = BConnectedDatabaseDiagnostics.report(baseDirectory: base.appendingPathComponent("grdb_link"), defaultsSelector: nil)
            XCTAssertEqual(linkedBase.baseDirectory, .unsafe)
            XCTAssertEqual(linkedBase.selectorFile, .notInspected)
            XCTAssertEqual(linkedBase.alternateScan, .notInspected)
            let linkedDirectory = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: "grdb_link")
            XCTAssertEqual(linkedDirectory.selectedDatabase.state, .unsafe)

            let selector = base.appendingPathComponent("storedPrimaryFolderName.txt")
            try FileManager.default.createSymbolicLink(at: selector, withDestinationURL: target.appendingPathComponent("signal.sqlite"))
            let linkedSelector = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: nil)
            XCTAssertEqual(linkedSelector.selectorFile, .unsafe)
            XCTAssertEqual(linkedSelector.selectedDatabase.state, .notInspected)
            XCTAssertEqual(linkedSelector.alternateScan, .incomplete)
            XCTAssertNil(linkedSelector.alternateDirectoryCount)
            try FileManager.default.removeItem(at: selector)

            let folder = base.appendingPathComponent("grdb")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("signal.sqlite"),
                withDestinationURL: target.appendingPathComponent("signal.sqlite"))
            let linkedDatabase = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: nil)
            XCTAssertEqual(linkedDatabase.selectedDatabase.state, .unsafe)
            XCTAssertNil(linkedDatabase.selectedDatabase.sizeBytes)
        }
    }

    func testDiagnosticBoundsAlternateMetadataAndOutput() throws {
        try withDiagnosticDirectory { base in
            for index in 0..<70 {
                try FileManager.default.createDirectory(at: base.appendingPathComponent("grdb_\(index)"), withIntermediateDirectories: false)
            }
            let report = BConnectedDatabaseDiagnostics.report(baseDirectory: base, defaultsSelector: nil)
            XCTAssertEqual(report.alternateScan, .incomplete)
            XCTAssertNil(report.alternateDirectoryCount)
            XCTAssertEqual(report.alternateDatabases.count, 64)
            XCTAssertTrue(report.alternateDatabases.allSatisfy { $0.state == .missing })
        }
    }

    private func withDiagnosticDirectory(_ body: (URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    private func makeDiagnosticDatabase(_ base: URL, folder: String, contents: Data) throws {
        let directory = base.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try contents.write(to: directory.appendingPathComponent("signal.sqlite"))
    }

    private func diagnosticSnapshot(_ base: URL) throws -> [String: Data] {
        var result = [String: Data]()
        for path in try FileManager.default.subpathsOfDirectory(atPath: base.path) {
            let url = base.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            result["\(path)/modified"] = Data(String(describing: attributes[.modificationDate]).utf8)
            if attributes[.type] as? FileAttributeType == .typeRegular {
                result[path] = try Data(contentsOf: url)
            }
        }
        return result
    }
}

private final class DiagnosticFileManager: FileManager, @unchecked Sendable {
    var failListing = false
    var failSelectorMetadata = false

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if failListing { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSFilePathErrorKey: "private-error-path"]) }
        return try super.contentsOfDirectory(atPath: path)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if failSelectorMetadata && path.hasSuffix("/storedPrimaryFolderName.txt") {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        return try super.attributesOfItem(atPath: path)
    }
}
