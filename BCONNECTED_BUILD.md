# Personal libsignal and full-graph compilation

This workflow prepares dependencies and compiles the actual iPhone app and extensions. It does not produce a usable messenger, exercise live services, or establish release readiness.

## Pinned local native dependency

Check out the personal `rolyv/BConnected-libsignal` repository beside this repository as `../libsignal`, at the exact clean revision in `ThirdParty/BConnectedLibsignal.lock.json`. Install that checkout's Rust toolchain, its `llvm-tools` component, the arm64 iOS/device simulator targets, CMake and Xcode (including the Metal Toolchain component required by the app's shaders). Select Xcode explicitly, then run:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 Scripts/bconnected/prepare_libsignal.py
pod install
```

The preparation script checks the personal origin, clean revision and expected Cargo.lock hashes and the complete canonical Swift/header tree digest. It builds both native targets into the explicitly selected checkout `target` directory with `--locked` and `--target-dir` (overriding inherited Cargo target-directory settings), iOS 15 deployment target and the recorded per-target features, verifies the owned constructor export and target-specific native testing exports, and stages Swift/header/native inputs under ignored `.build/bconnected-libsignal`. The staged pod contains no download or upstream prebuilt fallback. The simulator archive includes the native testing bridge required by the pinned Swift simulator-only APIs. The device archive excludes it and is checked for absence of testing exports. The upstream libsignal test subspec is not installed.

Before compiling the pod, the repository-owned verifier checks the staged lock against the current repository-owned lock, current repository-owned podspec, complete pinned Swift/header tree, complete file inventory and SHA-256 hashes. Missing, stale, extra, modified or symlinked inputs fail the build. Re-run preparation after a reviewed source pin or packaging change. Other public CocoaPods dependencies retain their existing resolution behavior.

Native archive hashes are local build receipts, not independent binary attestations. The workflow verifies source selection, build inputs, ABI symbols and minimum OS, then detects archive changes against those receipts; a separately reproduced or signed release artifact remains a later distribution requirement.

The supported prepared architectures are arm64 iPhone and arm64 iPhone simulator. This is not a published binary dependency distribution or an Intel simulator/Catalyst build.

## Non-runnable graph validation

After pod installation:

```sh
bash Scripts/bconnected/build_graph.sh
```

This invokes `xcodebuild build` for the real `Signal` workspace scheme, including its extension and framework dependencies, with developer signing disabled. The Mach-O linker may still apply its automatic ad-hoc simulator signature; no Apple team or distribution identity is used. It opts into `BCONNECTED_COMPILE_VALIDATION` and `BCONNECTED_OWNED_LIBSIGNAL` for this command only. It never sets `BCONNECTED_MESSAGING_CONFIGURED`.

The normal backend release guard remains active. Compile-validation mode requires Debug, simulator, owned libsignal, no legacy transport and no messaging-configured flag. Release/device combinations fail Swift compilation; native verification also rejects archive/install actions. The validation app has an immediate fatal main entry, and AppSetup independently rejects startup, so it cannot be used as a messaging pilot. Do not install, launch, archive or distribute it.

A runnable owned build still requires explicit endpoint/port/trust inputs in the app and extensions, complete service routing and enrollment integration, Stories/media/group support, signing, and actual device acceptance. Compiler success alone does not satisfy these requirements.

## Focused packaging checks

```sh
python3 -m unittest discover -s Scripts/bconnected -p 'test_*.py'
python3 Scripts/bconnected/verify_libsignal.py .build/bconnected-libsignal --platform iphonesimulator
```

## Durable owned enrollment source

The owned registration coordinator now selects a dedicated BConnected screen before upstream registration-state restoration. Only `BCONNECTED_LEGACY_TRANSPORT` retains the original entry path. The screen reads an explicit `BConnectedEnrollmentOrigin` HTTPS origin; no value is supplied by this change and it never infers a REST origin from the messaging host. Missing configuration cannot construct the network client.

`BConnectedEnrollmentCoordinator.prepare` commits the original phone/password, private ACI/PNI identity and signed EC/KEM records, registration IDs, attempt nonce, public registration JSON and original metadata to a dedicated collection in the preregistration SQLCipher app DB before returning the public community-intent projection. Restarts reuse those bytes. Corruption or persistence failure stops progress, and there is no automatic erasure/replacement path. The community challenge binds once. Approval, phone verification, pending native confirmation and an active server observation remain distinct; none of this code marks the local Signal account registered or returns the navigation `.done` step.

All five enrollment calls use the published `/v1/bconnected/enrollment` contract. Request/response validation rejects duplicate/unknown fields, invalid encodings and mismatched operation/account identity. Native libsignal validates signed public key material. The dedicated ephemeral HTTPS client rejects redirects, cookies and response caching, bounds response bytes and time, and never automatically retries. An SMS dispatch marker is committed before the call; uncertain delivery, cancellation or response-persistence failure retains the marker across restart/status checks. A later resend requires an explicit user decision and still relies on server quotas.

The shared request, 15 invalid mutations and 15 response/error cases are copied verbatim from the personal server fork into `SignalServiceKit/tests/Registration/Resources`. Focused host tests exercise the native cryptography, byte-preserving restarts, failure ordering, actual URLSession with synthetic URLProtocol responses, and the actual app view model with missing configuration. These are not device navigation/lifecycle or SQLCipher crash-durability tests. The actual full app graph separately compiles the production DB adapter and screen.

Next prerequisites are the real community invitation/session/approval-intent UI adapter; an explicit verified REST origin; installing the preserved keys and account identity atomically into native stores only after an authoritative active observation; owned service routing; and the existing complete pilot/Stories/8,000-member acceptance gates. Fresh installs currently show an honest setup-unavailable state rather than a simulated signup. The release guard remains in force.
