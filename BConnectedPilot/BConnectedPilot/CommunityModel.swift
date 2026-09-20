// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security
import SwiftUI

struct Member: Codable {
    let id: String
    let fullName: String
    let graduationYear: Int
    let status: String
}

struct DirectoryGroup: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let category: String
    let ownerId: String
    let status: String
    let createdAt: Double

    var symbol: String {
        switch category {
        case "Professional": "briefcase"
        case "Class years": "graduationcap"
        case "Sports": "sportscourt"
        case "Service": "hands.sparkles"
        default: "person.3"
        }
    }
}

private struct Enrollment: Decodable { let token: String; let expiresAt: Double; let member: Member }
private struct DirectoryResponse: Decodable { let groups: [DirectoryGroup] }
private struct APIError: Decodable { let error: String }

enum TokenVault {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "BConnectedPilot", kSecAttrAccount as String: "membership"]
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ token: String) throws {
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary, nil)
        if result == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
        } else if result != errSecSuccess { throw URLError(.cannotWriteToFile) }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

@MainActor
final class CommunityModel: ObservableObject {
    @Published var member: Member?
    @Published var groups: [DirectoryGroup] = []
    @Published var busy = false
    @Published var error: String?
    @Published var isPreview = false
    @Published var selectedGroups = Set<String>()
    private var token: String? = TokenVault.read()

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "BCONNECTED_API_URL") as? String,
              let url = URL(string: base + path), url.scheme == "https", url.host != nil else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method; req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 401 { TokenVault.clear(); token = nil; member = nil }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data).error) ?? "The service is unavailable. Please try again."
            throw NSError(domain: "BConnected", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func restore() async {
        guard token != nil, !isPreview else { return }
        await refresh()
    }

    func enroll(name: String, year: String, invite: String) async {
        guard let year = Int(year), !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let enrollment: Enrollment = try await request("/v1/enroll", method: "POST", body: ["fullName":name,"graduationYear":year,"inviteCode":invite])
            try TokenVault.write(enrollment.token)
            token = enrollment.token; member = enrollment.member
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !isPreview, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let current: Member = try await request("/v1/me")
            member = current
            if current.status == "approved" {
                let result: DirectoryResponse = try await request("/v1/groups")
                groups = result.groups
            } else { groups = [] }
        } catch { self.error = error.localizedDescription }
    }

    func signOut() async {
        guard !busy else { return }
        if !isPreview && token != nil {
            struct Result: Decodable { let signedOut: Bool }
            do { let _: Result = try await request("/v1/signout",method:"POST") }
            catch { self.error = "Could not sign out securely. Please reconnect and try again."; return }
        }
        TokenVault.clear(); token = nil; member = nil; groups = []; isPreview = false; selectedGroups = []; error = nil
    }

    func preview() {
        guard token == nil, !busy else { return }
        isPreview = true; error = nil
        member = Member(id:"preview",fullName:"Alex Rivera",graduationYear:2004,status:"approved")
        groups = [
            DirectoryGroup(id:"announcements",name:"Belen announcements",description:"The news that brings us all together. Updates from the Alumni Association.",category:"Community",ownerId:"preview",status:"approved",createdAt:0),
            DirectoryGroup(id:"law",name:"Belen Lawyers",description:"Good counsel. Lasting connections. Meet fellow alumni working in law.",category:"Professional",ownerId:"preview",status:"approved",createdAt:0),
            DirectoryGroup(id:"class",name:"Class of 2004",description:"Pick up where you left off. Reunions, memories, and everything in between.",category:"Class years",ownerId:"preview",status:"approved",createdAt:0),
            DirectoryGroup(id:"service",name:"Men for Others",description:"Find your next opportunity to give back alongside fellow alumni.",category:"Service",ownerId:"preview",status:"approved",createdAt:0),
            DirectoryGroup(id:"sports",name:"Wolverine Sports",description:"From Friday night lights to the next alumni game. Always blue and gold.",category:"Sports",ownerId:"preview",status:"approved",createdAt:0),
        ]
        selectedGroups = ["announcements", "class"]
    }
}
