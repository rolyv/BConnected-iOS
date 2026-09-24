// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import SignalServiceKit
import Combine
import SwiftUI
import UIKit
import Network
import libPhoneNumber_iOS

/// Owned enrollment has no escape into legacy registration, linking, or recovery.
class BConnectedEnrollmentViewController: UIHostingController<BConnectedEnrollmentView> {
    private let pathMonitor = NWPathMonitor()
    private let model: BConnectedEnrollmentViewModel
    private let notificationCenter: NotificationCenter
    private let applicationIsActive: () -> Bool
    private var isVisible = false
    private var appIsActive: Bool
    private var forwardedActive = false

    convenience init(initialRegistration: Bool, makeCoordinator: @MainActor (BConnectedEnrollmentEndpoint) -> BConnectedEnrollmentCoordinator,
         makeCommunity: @escaping @MainActor (BConnectedEnrollmentEndpoint, BConnectedEnrollmentEndpoint, BConnectedEnrollmentCoordinator) -> BConnectedCommunityEnrollmentCoordinator,
         makePreparation: @escaping @MainActor (String) async throws -> BConnectedEnrollmentPreparation,
         onCompleted: @escaping @MainActor () -> Void) {
        let model = BConnectedEnrollmentViewModel(initialRegistration: initialRegistration, makeCoordinator: makeCoordinator,
            makeCommunity: makeCommunity, makePreparation: makePreparation, onCompleted: onCompleted)
        self.init(model: model)
        pathMonitor.pathUpdateHandler = { [weak model] path in
            Task { @MainActor in model?.setOnline(path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "BConnected.signup.connectivity"))
    }

    /// UIKit owns this screen's lifecycle; no SwiftUI App/Scene supplies its activation.
    /// Dependency injection also lets lifecycle regression tests avoid a real path monitor.
    init(model: BConnectedEnrollmentViewModel, notificationCenter: NotificationCenter = .default,
         applicationIsActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.model = model
        self.notificationCenter = notificationCenter
        self.applicationIsActive = applicationIsActive
        self.appIsActive = applicationIsActive()
        super.init(rootView: BConnectedEnrollmentView(model: model))
        notificationCenter.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(applicationWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        appIsActive = applicationIsActive()
        forwardActivity()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Compact landscape can adapt our sheet to full screen and hide its presenter.
        // Its controls still drive signup, so keep that foreground presentation active.
        // Background notifications and actual navigation/removal always cancel intent.
        let ownsModal = presentedViewController != nil || navigationController?.presentedViewController != nil
        let remainsTop = navigationController.map { $0.topViewController === self } ?? true
        let isLeaving = isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true || navigationController?.isMovingFromParent == true
        if ownsModal && remainsTop && !isLeaving { return }
        isVisible = false
        forwardActivity()
    }

    @objc private func applicationDidBecomeActive() {
        appIsActive = true
        forwardActivity()
    }

    @objc private func applicationWillResignActive() {
        appIsActive = false
        forwardActivity()
    }

    private func forwardActivity() {
        // UIKit application notifications are delivered synchronously on the main thread.
        // Cancel pending explicit intent before any suspended request can resume.
        let active = isVisible && appIsActive
        guard active != forwardedActive else { return }
        forwardedActive = active
        model.setActive(active)
    }

    deinit {
        notificationCenter.removeObserver(self)
        pathMonitor.cancel()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Unavailable") }
}

private enum SignupStyle {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let background = color(0xFAF9F6, 0x101827)
    static let surface = color(0xFFFFFF, 0x192337)
    static let ink = color(0x101E42, 0xF5F3EE)
    static let secondary = color(0x606778, 0xB4BDCC)
    static let stroke = color(0x8791A3, 0x758093)
    static let error = color(0xA42E2A, 0xFFB4AB)
    static let tint = color(0xEEEFF4, 0x243049)
    static let gold = Color(red: 242/255, green: 170/255, blue: 0)
    static let navy = Color(red: 16/255, green: 30/255, blue: 66/255)
}

struct BConnectedEnrollmentView: View {
    @ObservedObject var model: BConnectedEnrollmentViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @FocusState private var field: BConnectedEnrollmentViewModel.Field?
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var countrySheet = false
    @State private var helpSheet = false
    @State private var correctionSheet = false
    @State private var correctionCountrySheet = false
    @State private var correctionPhoneFocused = false
    @State private var confirmResend = false
    @State private var phoneFocused = false
    @State private var previousField: BConnectedEnrollmentViewModel.Field?
    @State private var query = ""
    @State private var copiedHelp = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.screen == .details { details }
                        else if model.screen == .verifying { verification }
                        else { stateContent }
                    }
                    .frame(maxWidth: 480, alignment: .leading)
                    .padding(.horizontal, geometry.size.width < 375 ? 20 : 24)
                    .padding(.top, model.screen == .details ? 28 : 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.invalidField) { value in
                    focus(value)
                    if let value { scroll.scrollTo(value, anchor: .center) }
                }
            }
        }
        .background(SignupStyle.background.ignoresSafeArea())
        .foregroundStyle(SignupStyle.ink)
        .tint(SignupStyle.ink)
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(field == .phone || field == .name ? "Next" : "Done") {
                    field = field == .phone ? .name : field == .name ? .year : nil
                }
            }
        }
        .onReceive(timer) { model.tick($0) }
        .onChange(of: model.screen) { _ in
            phoneFocused = false; field = nil; headingFocused = true
        }
        .onChange(of: field) { value in
            if value != nil { phoneFocused = false }
            if let old = previousField, old != .code { _ = model.validate(old) }
            previousField = value
        }
        .onChange(of: model.phone) { _ in model.saveDraft() }
        .onChange(of: model.region) { _ in model.saveDraft() }
        .onChange(of: model.name) { _ in model.saveDraft() }
        .onChange(of: model.year) { _ in model.saveDraft() }
        .onChange(of: model.errors) { errors in
            if let message = errors[model.invalidField ?? .code] { UIAccessibility.post(notification: .announcement, argument: message) }
        }
        .sheet(isPresented: $countrySheet) { countryPicker }
        .sheet(isPresented: $helpSheet) { help }
        .sheet(isPresented: $correctionSheet) { correction }
        .confirmationDialog("Send another code?", isPresented: $confirmResend, titleVisibility: .visible) {
            Button("Send another code") { model.sendCode(confirmedUncertain: true) }
            Button("Keep waiting", role: .cancel) {}
        } message: { Text("Your previous text may still arrive. Sending again will request another code.") }
    }

    private func focus(_ value: BConnectedEnrollmentViewModel.Field?) {
        phoneFocused = value == .phone
        field = value == .phone ? nil : value
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(.largeTitle, design: .default).weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
    }
    private func secondary(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(SignupStyle.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
    }
    private func primary(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).multilineTextAlignment(.center)
                .padding(.vertical, 16).padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(SignupStyle.navy)
        .background(SignupStyle.gold.opacity(disabled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 12))
        .disabled(disabled)
    }
    private func error(_ field: BConnectedEnrollmentViewModel.Field) -> some View {
        Group {
            if let message = model.errors[field] {
                Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(SignupStyle.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func inputSurface<V: View>(_ view: V, vertical: CGFloat = 12) -> some View {
        view.font(.body).padding(.horizontal, 14).padding(.vertical, vertical).frame(minHeight: 54)
            .background(SignupStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(SignupStyle.stroke, lineWidth: 1))
    }
    private var details: some View {
        Group {
            HStack(spacing: 14) {
                Image("bconnected-launch-logo").resizable().scaledToFit().frame(width: 56, height: 56).accessibilityHidden(true)
                Text("BConnected Chat").font(.subheadline.weight(.semibold))
            }.padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 12) {
                heading("Your Belen\ncommunity awaits.")
                secondary("A private messenger for Belen Jesuit alumni.")
            }
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Phone number").font(.footnote.weight(.semibold))
                    inputSurface(phoneRow, vertical: 5).id(BConnectedEnrollmentViewModel.Field.phone)
                    error(.phone)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Full name").font(.footnote.weight(.semibold))
                    inputSurface(TextField("Your full name", text: $model.name)
                        .textContentType(.name).textInputAutocapitalization(.words).autocorrectionDisabled()
                        .focused($field, equals: .name).submitLabel(.next).onSubmit { field = .year }
                        .accessibilityLabel("Full name").accessibilityIdentifier("bconnected.signup.name"))
                        .id(BConnectedEnrollmentViewModel.Field.name)
                    error(.name)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Graduation year").font(.footnote.weight(.semibold))
                    inputSurface(TextField("e.g. 2008", text: $model.year).keyboardType(.numberPad)
                        .focused($field, equals: .year).onChange(of: model.year) { value in model.year = BConnectedPhoneEntry.normalized(value) }
                        .accessibilityLabel("Graduation year").accessibilityIdentifier("bconnected.signup.year"))
                        .id(BConnectedEnrollmentViewModel.Field.year)
                    error(.year)
                }
            }
            if !model.isOnline { notice("You’re offline. Connect to the internet, then continue.") }
            VStack(spacing: 12) {
                primary("Continue", disabled: model.busy || !model.isOnline) {
                    model.submitDetails()
                    if let invalid = model.invalidField { focus(invalid) }
                }.accessibilityIdentifier("bconnected.signup.continue")
                Text("We’ll send a text to verify your number.").font(.footnote).foregroundStyle(SignupStyle.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }.padding(.top, 12)
            Label("A private space to stay connected", systemImage: "lock")
                .font(.caption).foregroundStyle(SignupStyle.secondary).frame(maxWidth: .infinity).padding(.top, 4)
        }
    }
    @ViewBuilder private var phoneRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { countryButton; phoneField }
        } else {
            HStack(spacing: 12) { countryButton; Rectangle().fill(SignupStyle.stroke).frame(width: 1, height: 30); phoneField }
        }
    }
    private var countryButton: some View {
        Button { phoneFocused = false; field = nil; query = ""; countrySheet = true } label: {
            HStack(spacing: 4) {
                Text("\(model.region) +\(SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: model.region))")
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(minHeight: 44)
        }.buttonStyle(.plain)
            .accessibilityLabel("Country or region, \(PhoneNumberUtil.countryName(fromCountryCode: model.region)), plus \(SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: model.region))")
    }
    private var phoneField: some View {
        SignupPhoneField(text: $model.phone, region: $model.region, wantsFocus: phoneFocused,
            onFocus: { phoneFocused = true; field = nil }, onBlur: { phoneFocused = false; _ = model.validate(.phone) }, onNext: { focus(.name) })
            .frame(minHeight: max(30, UIFont.preferredFont(forTextStyle: .body).lineHeight))
    }
    private var verification: some View {
        Group {
            Button { field = nil; model.preparePhoneCorrection(); correctionSheet = true } label: {
                Label("Edit number", systemImage: "chevron.left").font(.body).frame(minHeight: 44)
            }.disabled(model.busy)
            Text("One quick check").font(.subheadline.weight(.semibold)).foregroundStyle(SignupStyle.secondary)
            heading("Verify your phone number.")
            VStack(alignment: .leading, spacing: 6) {
                secondary(model.message == "Sending your code…" ? "Sending your code to" : "Enter the code for")
                Text(model.phoneDestination).font(.body.weight(.semibold)).accessibilityLabel(Text(model.phoneDestination.map(String.init).joined(separator: " ")))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Verification code").font(.footnote.weight(.semibold))
                inputSurface(TextField("Verification code", text: $model.code).textContentType(.oneTimeCode)
                    .keyboardType(.numberPad).focused($field, equals: .code).accessibilityIdentifier("bconnected.signup.code"))
                Text("You can paste your code or use AutoFill.").font(.footnote).foregroundStyle(SignupStyle.secondary)
                error(.code)
                if let text = model.checkNotice { Text(text).font(.footnote).foregroundStyle(SignupStyle.secondary) }
            }
            if !model.isOnline { notice("You’re offline. Connect to the internet, then continue.") }
            else if model.uncertainSMS { notice("Your text may still be on its way. Enter the code if it arrives.") }
            else if let message = model.message { notice(message) }
            if model.codeExpired {
                primary("Send a new code", disabled: !model.canSend, action: requestCode)
                if !model.canSend { secondary(model.resendTitle) }
            } else {
                primary(model.busy ? (model.message == "Sending your code…" ? "Sending…" : "Checking…") : "Verify & continue", disabled: !model.canCheck) { model.verifyCode() }
                Button(model.resendTitle, action: requestCode)
                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44).disabled(!model.canSend)
            }
            helpButton
        }
    }

    private func requestCode() {
        if model.uncertainSMS { confirmResend = true } else { model.sendCode() }
    }

    private var showsOfflineSetup: Bool {
        !model.isOnline && model.hasSavedSetup && !model.stateUnreadable
            && [.returning, .correctingPhone, .resolvingMembership, .settingUp, .continuation].contains(model.screen)
    }
    private var title: String {
        if showsOfflineSetup { return "You’re offline." }
        if model.screen == .help && model.phoneSetupExpired && model.canCorrectPhone { return "Let’s verify your number again." }
        switch model.screen {
        case .returning: return "Welcome back."
        case .correctingPhone: return "Updating your number."
        case .resolvingMembership: return "One quick check."
        case .pending: return "You’re on the list for review."
        case .settingUp: return model.slow ? "Taking a little longer." : "Making room for you."
        case .continuation: return (model.intentWait ?? 0) > 0 ? "Your progress is saved." : "Let’s finish getting you set up."
        case .declined: return "Your request wasn’t approved."
        case .accessPaused: return "Your access is paused."
        case .ready: return "You’re ready to connect"
        default: return "Let’s get you some help."
        }
    }
    private var detail: String {
        if showsOfflineSetup { return "Your progress is saved. We’ll check where you left off when you’re connected again." }
        if model.screen == .help && model.phoneSetupExpired && model.canCorrectPhone {
            return "Your previous verification expired. Your name and graduation year are saved. Confirm your number to request a new code."
        }
        switch model.screen {
        case .returning: return "We’re checking where you left off."
        case .correctingPhone: return "Your name and graduation year stay saved. We’re finishing your number update before a new code can be requested."
        case .resolvingMembership: return "We’re checking your membership."
        case .pending: return "An alumni administrator will review your details. Your place is saved."
        case .settingUp: return model.slow ? "We’re still getting your account ready. You can close the app and come back." : "We’re getting your account ready. This usually takes a moment."
        case .continuation: return (model.intentWait ?? 0) > 0 ? "We need a little more time before setup can continue. You can leave and come back." : "We couldn’t finish setting up your account. Your progress is saved."
        case .declined: return "BConnected Chat is for Belen Jesuit alumni. If this doesn’t look right, the alumni team can help."
        case .accessPaused: return "Your membership is no longer approved for messaging. Contact the alumni team for help."
        case .ready: return "Your Belen community awaits."
        default: return model.stateUnreadable ? "We can’t read your saved setup right now. The alumni team can help." : model.hasSavedSetup ? "We can’t continue setup right now. Your progress is saved. The alumni team can help with the next step." : "Signup isn’t available in this build. The alumni team can help with the next step."
        }
    }
    private var stateContent: some View {
        Group {
            Image("bconnected-launch-logo").resizable().scaledToFit().frame(width: 104, height: 104)
                .accessibilityHidden(true).padding(.top, 32).padding(.bottom, 16)
            heading(title)
            secondary(detail)
            if model.screen == .pending {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.memberName) · Class of \(model.memberYear)").font(.body.weight(.semibold))
                    Label("Waiting for approval", systemImage: "clock").font(.footnote).foregroundStyle(SignupStyle.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(SignupStyle.tint, in: RoundedRectangle(cornerRadius: 12))
                secondary("You can close the app. We’ll check for an update when you return.")
                if !model.isOnline { notice("You’re offline. We’ll check when you reconnect.") }
                else if let message = model.message { notice(message) }
                helpButton
            } else if model.screen == .help && model.phoneSetupExpired && model.canCorrectPhone {
                primary("Confirm phone number", disabled: !model.isOnline) { model.preparePhoneCorrection(); correctionSheet = true }
                helpButton
            } else if [.declined, .accessPaused, .help].contains(model.screen) {
                primary("Contact the alumni team") { helpSheet = true }
            } else if !model.isOnline {
                status("Waiting for a connection", spinning: false); helpButton
            } else if model.screen == .continuation {
                if let seconds = model.intentWait, seconds > 0 { status("You can continue in \(BConnectedEnrollmentViewModel.duration(seconds)).", spinning: false) }
                else { secondary("We’ll check where you left off before continuing.") }
                primary("Continue setup", disabled: !model.canContinue) { model.continueSetup() }
                helpButton
            } else {
                status(model.screen == .returning ? "Resuming your signup…" : model.screen == .correctingPhone ? "Updating your number…" : model.screen == .resolvingMembership ? "Checking your membership…" : model.slow ? "Your progress is saved" : "Finishing setup…", spinning: !model.slow)
                if model.slow { helpButton }
            }
        }
    }
    private func status(_ text: String, spinning: Bool) -> some View {
        HStack(spacing: 12) {
            if spinning && !reduceMotion { ProgressView().accessibilityHidden(true) }
            else { Image(systemName: "clock").accessibilityHidden(true) }
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(SignupStyle.secondary).padding(.vertical, 16)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.footnote).fixedSize(horizontal: false, vertical: true)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(SignupStyle.tint, in: RoundedRectangle(cornerRadius: 12))
    }
    private var helpButton: some View {
        Button("Get help") { helpSheet = true }.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
    }
    private var help: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading("The alumni team can help")
                    secondary("Contact the alumni administrator who shared BConnected Chat with you.")
                    if model.hasSavedSetup && !model.stateUnreadable { secondary("Your progress is saved. There’s no need to start over.") }
                    primary("Email the alumni team") { openURL(URL(string: "mailto:alumni@belenjesuit.org")!) }
                    Button(copiedHelp ? "Help summary copied" : "Copy help summary") {
                        // No number, name, OTP, raw IDs, credentials, keys, or transport errors.
                        UIPasteboard.general.string = "BConnected Chat signup\nScreen: \(model.screen)\nSaved setup readable: \(!model.stateUnreadable)\nApp version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")"
                        copiedHelp = true
                    }.frame(minHeight: 44)
                }.padding(24)
            }.background(SignupStyle.background).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { helpSheet = false } } }
        }.navigationViewStyle(.stack)
    }
    private var correction: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading("Edit your number")
                    if model.canCorrectPhone {
                        secondary("We’ll send a code to your updated number. Your name and graduation year stay saved.")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Phone number").font(.footnote.weight(.semibold))
                            Button {
                                correctionPhoneFocused = false; query = ""; correctionCountrySheet = true
                            } label: {
                                HStack {
                                    Text(PhoneNumberUtil.countryName(fromCountryCode: model.correctionRegion))
                                    Spacer()
                                    Text("+\(SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: model.correctionRegion))")
                                    Image(systemName: "chevron.down")
                                }.frame(minHeight: 44)
                            }.accessibilityLabel("Country or region, \(PhoneNumberUtil.countryName(fromCountryCode: model.correctionRegion)), plus \(SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: model.correctionRegion))")
                            inputSurface(SignupPhoneField(text: $model.correctionPhone, region: $model.correctionRegion,
                                wantsFocus: correctionPhoneFocused, onFocus: { correctionPhoneFocused = true },
                                onBlur: { correctionPhoneFocused = false }, onNext: { correctionPhoneFocused = false })
                                .frame(minHeight: max(30, UIFont.preferredFont(forTextStyle: .body).lineHeight)))
                            if let error = model.correctionError { notice(error) }
                        }
                        if !model.isOnline { notice("You’re offline. Connect to the internet, then continue.") }
                        primary("Send code to this number", disabled: !model.isOnline) {
                            correctionPhoneFocused = false
                            if model.submitPhoneCorrection() { correctionSheet = false }
                        }
                    } else {
                        secondary("The alumni team can help with this number. Your saved signup will stay intact.")
                        primary("Contact the alumni team") { correctionSheet = false; openURL(URL(string: "mailto:alumni@belenjesuit.org")!) }
                    }
                }.padding(24)
            }.background(SignupStyle.background).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { correctionSheet = false } } }
                .sheet(isPresented: $correctionCountrySheet) { correctionCountryPicker }
        }.navigationViewStyle(.stack)
    }
    private var correctionCountryPicker: some View {
        NavigationView {
            List(countries, id: \.self) { region in
                Button {
                    model.correctionRegion = region; correctionCountrySheet = false
                } label: {
                    HStack {
                        Text(PhoneNumberUtil.countryName(fromCountryCode: region))
                        Spacer()
                        Text("+\(SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: region))")
                    }.frame(minHeight: 44)
                }
            }.searchable(text: $query, prompt: "Country, region, or calling code")
                .navigationTitle("Country or region").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { correctionCountrySheet = false } } }
        }
    }
    private var countryPicker: some View {
        NavigationView {
            List {
                ForEach(countries, id: \.self) { region in
                    Button {
                        model.region = region; countrySheet = false
                    } label: {
                        HStack {
                            Text(PhoneNumberUtil.countryName(fromCountryCode: region))
                            Spacer()
                            Text("+\(SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: region))").foregroundStyle(SignupStyle.secondary)
                            if region == model.region { Image(systemName: "checkmark") }
                        }.frame(minHeight: 44)
                    }
                }
            }.searchable(text: $query, prompt: "Country, region, or calling code")
                .navigationTitle("Country or region").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { countrySheet = false } } }
        }
    }
    private static let supportedRegions: [String] = {
        let metadata = NBPhoneNumberUtil(metadataHelper: NBMetadataHelper())
        return Array(Set(Locale.isoRegionCodes + (metadata?.getSupportedRegions() as? [String] ?? [])))
    }()
    private var countries: [String] {
        Self.supportedRegions.filter { region in
            let code = SSKEnvironment.shared.phoneNumberUtilRef.getCallingCode(forRegion: region)
            return code > 0 && (query.isEmpty || PhoneNumberUtil.countryName(fromCountryCode: region).localizedCaseInsensitiveContains(query) || region.localizedCaseInsensitiveContains(query) || "+\(code)".contains(query))
        }.sorted { PhoneNumberUtil.countryName(fromCountryCode: $0).localizedStandardCompare(PhoneNumberUtil.countryName(fromCountryCode: $1)) == .orderedAscending }
    }
}

/// UIKit owns selection and IME composition. Formatting maps the caret through a
/// linear digit-relative mapper instead of replacing a SwiftUI binding at the end of every edit.
struct SignupPhoneField: UIViewRepresentable {
    @Binding var text: String
    @Binding var region: String
    let wantsFocus: Bool
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onNext: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.compositionChanged(_:)), for: .editingChanged)
        field.keyboardType = .phonePad; field.textContentType = .telephoneNumber
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(SignupStyle.ink)
        field.placeholder = "(305) 555-0123"
        field.accessibilityLabel = "Phone number"; field.accessibilityIdentifier = "bconnected.signup.phone"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "Next", style: .done, target: context.coordinator, action: #selector(Coordinator.nextField))]
        field.inputAccessoryView = toolbar
        return field
    }
    func updateUIView(_ view: UITextField, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange == nil && (view.text != text || context.coordinator.region != region) {
            let formatted = context.coordinator.format(text)
            view.text = formatted
            context.coordinator.region = region
        }
        view.placeholder = region == "US" ? "(305) 555-0123" : "Phone number"
        if wantsFocus && !view.isFirstResponder { view.becomeFirstResponder() }
        if !wantsFocus && view.isFirstResponder { view.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SignupPhoneField
        var region: String
        private let phoneUtil = NBPhoneNumberUtil(metadataHelper: NBMetadataHelper())
        private let utility = PhoneNumberUtil()
        init(_ parent: SignupPhoneField) { self.parent = parent; region = parent.region }
        @objc func compositionChanged(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            // AutoFill and committed IME edits can bypass shouldChangeCharactersIn.
            // Normalize only after composition ends and retain both selection endpoints.
            let raw = field.text ?? ""
            let selection = field.selectedTextRange.map {
                (field.offset(from: field.beginningOfDocument, to: $0.start), field.offset(from: field.beginningOfDocument, to: $0.end))
            }
            updateRegion(for: BConnectedPhoneEntry.normalized(raw))
            let formatted = format(raw)
            field.text = formatted; parent.text = formatted; region = parent.region
            if let selection,
               let start = field.position(from: field.beginningOfDocument, offset: BConnectedPhoneEntry.cursorOffset(from: raw, offset: selection.0, to: formatted, preferRight: true)),
               let end = field.position(from: field.beginningOfDocument, offset: BConnectedPhoneEntry.cursorOffset(from: raw, offset: selection.1, to: formatted, preferRight: true)) {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
        }
        @objc func nextField() { parent.onNext() }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.onFocus() }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.onBlur() }
        private func updateRegion(for input: String) {
            guard input.trimmingCharacters(in: .whitespaces).hasPrefix("+"),
                  let parsed = BConnectedPhoneEntry.parse(input, region: parent.region, using: utility) else { return }
            if let detected = phoneUtil?.getRegionCode(for: parsed.nbPhoneNumber), detected != "ZZ", detected != "001" {
                parent.region = detected
            } else if let callingCode = parsed.getCallingCode(), utility.getCallingCode(forRegion: parent.region) != callingCode {
                // Keep an explicit selection for shared codes; use the metadata's
                // primary region when a possible/new range has no precise region.
                let primary = utility.getRegionCodeForCallingCode(callingCode)
                if primary != "ZZ" && primary != "001" { parent.region = primary }
            }
        }
        func format(_ input: String) -> String {
            let normalized = BConnectedPhoneEntry.normalized(input)
            // Preserve oversized/invalid pastes for correction without feeding them into
            // as-you-type regex work. Never silently truncate user input.
            guard normalized.utf16.count <= 256, BConnectedPhoneEntry.digits(normalized).count <= 16 else { return normalized }
            if let number = BConnectedPhoneEntry.parse(normalized, region: parent.region, using: utility) {
                return utility.formattedNationalNumber(for: number) ?? normalized
            }
            guard normalized.allSatisfy({ "0123456789 ()-.".contains($0) }) else { return normalized }
            guard let formatter = NBAsYouTypeFormatter(regionCode: parent.region) else { return normalized }
            var result = ""
            for digit in BConnectedPhoneEntry.digits(normalized) { result = formatter.inputDigit(String(digit)) }
            return result
        }
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard field.markedTextRange == nil else { return true }
            let old = field.text ?? ""
            guard let swiftRange = Range(range, in: old) else { return false }
            let replacement = BConnectedPhoneEntry.normalized(string)
            var raw = old.replacingCharacters(in: swiftRange, with: replacement)
            var cursor = range.location + (replacement as NSString).length
            // Full international paste replaces the whole national field even over a partial selection.
            if replacement.trimmingCharacters(in: .whitespaces).hasPrefix("+") {
                raw = replacement; cursor = (raw as NSString).length
            } else if string.isEmpty && range.length == 1 && BConnectedPhoneEntry.digits(String(old[swiftRange])).isEmpty {
                // Separator deletion consumes the nearest digit in the actual deletion direction.
                let caret = field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) } ?? range.location + 1
                let backwards = range.location < caret
                let chars = Array(old.utf16)
                let indices = backwards ? Array((0..<range.location).reversed()) : Array((range.location + range.length)..<chars.count)
                if let digitIndex = indices.first(where: { (48...57).contains(chars[$0]) }), let deletion = Range(NSRange(location: digitIndex, length: 1), in: old) {
                    raw = old.replacingCharacters(in: deletion, with: "")
                    cursor = backwards ? digitIndex : range.location
                }
            }
            updateRegion(for: raw)
            let formatted = format(raw)
            let translated = BConnectedPhoneEntry.cursorOffset(from: raw, offset: cursor, to: formatted, preferRight: !string.isEmpty)
            field.text = formatted; parent.text = formatted; region = parent.region
            if let position = field.position(from: field.beginningOfDocument, offset: Int(translated)) { field.selectedTextRange = field.textRange(from: position, to: position) }
            return false
        }
    }
}
