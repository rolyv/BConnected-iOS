// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum Brand {
    static let navy = Color(red:0.055,green:0.16,blue:0.27)
    static let gold = Color(red:0.88,green:0.67,blue:0.25)
    static let paper = Color(red:0.98,green:0.97,blue:0.95)
}

@main
struct BConnectedApp: App {
    @StateObject private var model = CommunityModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(Brand.navy)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--preview") { model.preview() }
                    else { await model.restore() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: CommunityModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if let member = model.member {
                if member.status == "approved" { CommunityTabs() }
                else { ApprovalView(member: member) }
            } else { WelcomeView() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.restore() } }
        }
        .alert("BConnected", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: CommunityModel
    @State private var applying = false
    var body: some View {
        ZStack {
            Brand.navy.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image("BrandMark").resizable().frame(width:54,height:54).clipShape(RoundedRectangle(cornerRadius:13))
                    VStack(alignment:.leading,spacing:2) {
                        Text("BConnected").font(.system(size:25,weight:.semibold))
                        Text("CHAT").font(.system(size:11,weight:.medium)).tracking(3).foregroundStyle(Brand.gold)
                    }
                }
                Spacer()
                Text("A Belen connection.\nFor life.").font(.system(size:46,weight:.regular,design:.serif)).lineSpacing(2).fixedSize(horizontal:false,vertical:true)
                Text("Find your people. Share your stories.\nKeep the conversation going.").font(.system(size:18)).lineSpacing(5).foregroundStyle(.white.opacity(0.75))
                HStack(spacing:8) { Image(systemName:"checkmark.seal"); Text("A home for verified alumni") }.font(.subheadline).foregroundStyle(Brand.gold).padding(.top,10)
                Spacer()
                Button { applying = true } label: {
                    HStack { Spacer(); Text("Join BConnected").fontWeight(.semibold); Spacer(); Image(systemName:"arrow.right") }.padding(19)
                }.background(Brand.gold,in:RoundedRectangle(cornerRadius:17)).foregroundStyle(Brand.navy)
                Button("Preview the pilot") { model.preview() }.frame(maxWidth:.infinity).foregroundStyle(.white.opacity(0.85)).padding(6)
                Text("BELEN JESUIT · ALUMNI PILOT").font(.system(size:10,weight:.medium)).tracking(2).frame(maxWidth:.infinity).foregroundStyle(.white.opacity(0.5)).padding(.bottom,10)
            }.padding(28)
        }.foregroundStyle(.white)
            .sheet(isPresented:$applying) { EnrollmentView() }
    }
}

struct EnrollmentView: View {
    @EnvironmentObject private var model: CommunityModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var year = ""
    @State private var invite = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Once a Wolverine.\nAlways connected.").font(.system(size:30,design:.serif)).padding(.vertical,8)
                    Text("An alumni administrator will review your name and graduation year before you can enter.").foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
                Section("Your alumni profile") {
                    TextField("Full name",text:$name).textContentType(.name)
                    TextField("Graduation year",text:$year).keyboardType(.numberPad)
                    TextField("Pilot invitation code",text:$invite).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button {
                        Task { await model.enroll(name:name,year:year,invite:invite.trimmingCharacters(in:.whitespacesAndNewlines)); if model.member != nil { dismiss() } }
                    } label: {
                        HStack { Text("Request access"); Spacer(); if model.busy { ProgressView() } else { Image(systemName:"arrow.right") } }
                    }.disabled(name.trimmingCharacters(in:.whitespaces).count < 2 || Int(year) == nil || invite.isEmpty || model.busy)
                } footer: { Text("Invitation codes are issued individually for this small pilot. Receiving one does not bypass alumni approval.") }
            }.navigationTitle("Join BConnected").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct ApprovalView: View {
    @EnvironmentObject private var model: CommunityModel
    let member: Member
    var body: some View {
        VStack(spacing:24) {
            Spacer()
            Image(systemName:member.status == "pending" ? "clock.badge.checkmark" : "person.crop.circle.badge.exclamationmark").font(.system(size:56)).foregroundStyle(Brand.gold)
            Text(member.status == "pending" ? "You're on the list." : "Access needs a review.").font(.system(size:34,design:.serif))
            Text("\(member.fullName) · Class of \(String(member.graduationYear))").font(.headline)
            Text(member.status == "pending" ? "Your alumni profile is waiting for an administrator's approval. Check back here for your invitation into the community." : "Your account isn't approved for access. Please contact the pilot administrator.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { Task { await model.refresh() } } label: { Label("Check approval",systemImage:"arrow.clockwise") }.buttonStyle(.borderedProminent).disabled(model.busy)
            Spacer()
            Button("Sign out") { Task { await model.signOut() } }
        }.padding(30).frame(maxWidth:.infinity).background(Brand.paper)
    }
}

struct CommunityTabs: View {
    @EnvironmentObject private var model: CommunityModel
    var body: some View {
        VStack(spacing:0) {
            if model.isPreview {
                HStack { Text("PREVIEW · SAMPLE CONTENT").font(.system(size:10,weight:.semibold)).tracking(1); Spacer(); Button("Exit") { Task { await model.signOut() } }.font(.caption) }
                    .padding(.horizontal,18).padding(.vertical,9).foregroundStyle(Brand.navy).background(Brand.gold.opacity(0.18))
            }
            TabView {
                GroupsView().tabItem { Label("Groups",systemImage:"person.3.fill") }
                PilotFeatureView(title:"DMs",symbol:"bubble.left.and.bubble.right",message:"Personal conversations, lasting connections.").tabItem { Label("DMs",systemImage:"bubble.left.and.bubble.right.fill") }
                PilotFeatureView(title:"Stories",symbol:"circle.dashed",message:"A little window into life after Belen.").tabItem { Label("Stories",systemImage:"circle.dashed") }
            }
        }
    }
}

struct GroupsView: View {
    @EnvironmentObject private var model: CommunityModel
    @State private var segment = "Discover"
    @State private var search = ""
    @State private var category = "All"
    @State private var creating = false
    @State private var selected: DirectoryGroup?
    private var filtered: [DirectoryGroup] {
        model.groups.filter { group in
            (segment == "Discover" || model.selectedGroups.contains(group.id)) &&
            (category == "All" || group.category == category) &&
            (search.isEmpty || (group.name + " " + group.description).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text("GOOD TO BE CONNECTED").font(.system(size:10,weight:.semibold)).tracking(1.8).foregroundStyle(.secondary)
                            Text("Your people. Your place.").font(.system(size:29,design:.serif)).foregroundStyle(Brand.navy)
                        }
                        Spacer()
                        Image("BrandMark").resizable().frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:12))
                    }
                    Picker("Groups view",selection:$segment) { Text("My groups").tag("My groups"); Text("Discover").tag("Discover") }.pickerStyle(.segmented)
                    HStack { Image(systemName:"magnifyingglass"); TextField("Find a group or interest",text:$search) }.padding(13).background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:13)).foregroundStyle(.secondary)
                    if segment == "Discover" {
                        ScrollView(.horizontal,showsIndicators:false) {
                            HStack(spacing:8) {
                                ForEach(["All","Professional","Class years","Service","Sports"],id:\.self) { value in
                                    Button { category = value } label: { Text(value).font(.system(size:12,weight:.medium)).padding(.horizontal,15).padding(.vertical,10).background(category == value ? Brand.navy : Color(.secondarySystemGroupedBackground),in:Capsule()).foregroundStyle(category == value ? .white : Brand.navy) }
                                }
                            }
                        }
                    }
                    HStack { Text(segment == "Discover" ? "Find your next connection" : "Keep the conversation going").font(.headline); Spacer(); Text("\(filtered.count)").font(.caption).foregroundStyle(.secondary) }
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Your next connection is ahead" : "No matching groups",systemImage:"person.3",description:Text(search.isEmpty ? "Approved groups will appear here as the pilot grows." : "Try another name or interest."))
                    } else {
                        ForEach(filtered) { group in
                            Button { selected = group } label: { GroupRow(group:group,joined:model.selectedGroups.contains(group.id)) }.buttonStyle(.plain)
                        }
                    }
                    Label("Private groups are invitation-only and never appear in Discover.",systemImage:"lock").font(.caption).foregroundStyle(.secondary).padding(.vertical,4)
                }.padding(20)
            }.background(Brand.paper)
                .navigationTitle("Groups").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarTrailing) { Button { creating = true } label: { Image(systemName:"plus") }.accessibilityLabel("Create a group") }
                    ToolbarItem(placement:.topBarLeading) { Menu { Button("Sign out") { Task { await model.signOut() } } } label: { Image(systemName:"person.crop.circle") } }
                }
                .refreshable { await model.refresh() }
                .sheet(isPresented:$creating) { GroupCreationView() }
                .sheet(item:$selected) { GroupDetailView(group:$0) }
        }
    }
}

struct GroupRow: View {
    let group: DirectoryGroup
    let joined: Bool
    var body: some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:group.id == "announcements" ? "megaphone" : group.symbol).font(.system(size:21)).foregroundStyle(Brand.navy).frame(width:49,height:49).background(Brand.gold.opacity(0.17),in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:6) {
                HStack { Text(group.name).font(.system(size:17,weight:.semibold)); Spacer(); if joined { Image(systemName:"checkmark.circle.fill").font(.caption).foregroundStyle(Brand.navy) } }
                Text(group.description).font(.system(size:13)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                Text(group.category.uppercased()).font(.system(size:9,weight:.semibold)).tracking(1).foregroundStyle(Brand.navy).padding(.top,4)
            }
        }.padding(17).background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:19))
    }
}

struct GroupDetailView: View {
    @EnvironmentObject private var model: CommunityModel
    @Environment(\.dismiss) private var dismiss
    let group: DirectoryGroup
    var body: some View {
        NavigationStack {
            VStack(spacing:22) {
                Image(systemName:group.symbol).font(.system(size:42)).foregroundStyle(Brand.gold).padding(.top,35)
                Text(group.name).font(.system(size:32,design:.serif))
                Text(group.description).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if model.isPreview {
                    Button(model.selectedGroups.contains(group.id) ? "Added to My groups" : "Try joining this group") { model.selectedGroups.insert(group.id); dismiss() }.buttonStyle(.borderedProminent)
                    Text("Preview only. This does not join a live chat.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Chat invitations will open here when messaging is available in the pilot.").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(28).navigationTitle("About this group").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct GroupCreationView: View {
    @EnvironmentObject private var model: CommunityModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var visibility = "Listed"
    var body: some View {
        NavigationStack {
            Form {
                Section("Start a connection") { TextField("Group name",text:$name) }
                Section("Who can discover this group?") {
                    Picker("Visibility",selection:$visibility) { Text("Listed").tag("Listed"); Text("Private").tag("Private") }.pickerStyle(.segmented)
                    Text(visibility == "Listed" ? "Any approved alumnus can create a group. An administrator must approve its listing before it appears in Discover." : "Only invited members can find this group. Its name and membership never appear in the directory.").font(.callout).foregroundStyle(.secondary)
                }
                Section { Text("Group creation will become available when messaging is activated. This screen previews the visibility choices.").font(.callout).foregroundStyle(.secondary) }
            }.navigationTitle("New group").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct PilotFeatureView: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        NavigationStack {
            VStack(spacing:23) {
                Spacer()
                Image(systemName:symbol).font(.system(size:58,weight:.light)).foregroundStyle(Brand.gold)
                Text(message).font(.system(size:30,design:.serif)).multilineTextAlignment(.center)
                Text("Coming in the messaging pilot").font(.headline).foregroundStyle(Brand.navy)
                Text("This build lets you explore the community and request alumni approval. Messages and stories aren't active yet.").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
            }.padding(30).frame(maxWidth:.infinity).background(Brand.paper).navigationTitle(title)
        }
    }
}
