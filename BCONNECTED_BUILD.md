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

Next prerequisites are explicit verified community/enrollment REST origins; releasing the installed native account only after the complete owned service graph is ready; owned service routing; and the existing complete pilot/Stories/8,000-member acceptance gates. Fresh installs remain setup-unavailable until both owned REST origins are configured; the source now contains the real invitation/approval flow described below. The release guard remains in force.

## Community invitation and approval integration

The actual owned registration screen now accepts name, graduation year and a single-use invitation, persists the community bearer session in a separate SQLCipher collection, refreshes approval, and connects the approved membership to the durably prepared device. The native preparation callback obtains APNs (or the existing explicit unsupported/manual-fetch result), persists the profile key, and derives the access key before freezing registration material. It runs only for a new attempt, never reconstructs metadata or private keys on retry, and never sends an SMS by itself.

`BConnectedCommunityOrigin` is a separate explicit HTTPS origin. The existing community `/v1/enroll`, `/v1/me` and `/v1/admission/intents` payloads are used exactly; there is no typed-credential-error inference from untyped community errors. The shared restricted HTTP layer retains redirect refusal, no-store validation, cookie/credential-cache exclusion, response caps and deadlines.

Both non-idempotent writes have durable dispatch markers. A lost single-use application response requires administrator assistance and cannot consume another invitation automatically. A lost intent response permits only a deliberate later retry after the service's existing maximum five-minute intent window, subject to its authoritative eligibility checks. That retry reuses original material. A returned binding is saved before updating the enrollment collection, allowing a crash between those two writes to recover locally without another intent request. An expired or unavailable binding never silently replaces the saved keys.

Only the initial-registration mode can open this flow. Re-registration and phone changes show an unavailable state before constructing any service; secondary-device linking is refused in owned mode. The legacy branch remains explicit. Active native lifecycle completion, live provider/device verification and the full release gates remain outstanding.


## Native account installation (services still gated)

After server activation, the real setup screen offers an explicit device-account save. The coordinator first fetches fresh authenticated status; a cached active observation alone cannot install anything. The SQLCipher adapter rechecks the exact immutable snapshot in one transaction and validates every native input and existing destination before mutation. It persists the original ACI/PNI identities, signed and last-resort KEM records, registration IDs, password, server identifiers, delivery/discoverability settings, and installation receipt atomically. Existing native account/key state is rejected rather than overwritten. Exact retries verify stored material and do not rotate keys or rewrite native metadata.

The identity and prekey metadata archives are prepared before any writes; archive failures cannot silently turn into nil writes through the upstream KeyValueStore convenience API. The owned path makes no eager account-cache updates and uses no transaction completion callbacks (those callbacks may also run after an explicit rollback). A durable pending-services flag makes both cached and freshly loaded account readers remain unregistered and withhold credentials and local identifiers. There is deliberately no flag-release method in this slice. Registration notifications, recipient merge, account entropy/remaining setup, service readiness, and navigation completion remain separate future integration work.

The host suite now includes fresh-status/suspension, installation-failure, immutable-account conflict and exact-key restart tests. For real storage/cache coverage, build the graph and run the standalone probe against a dedicated, already-booted arm64 iOS 27 simulator:

```sh
python3 Scripts/bconnected/probe_native_account_db.py --simulator <dedicated-simulator-UUID>
```

This compiles a separate executable against the actual built SignalServiceKit framework. It never launches Signal.app or initializes AppSetup. Four SQLCipher in-memory probes cover rollback of account/prekey/metadata/receipt writes, unchanged cached and recreated account readers, exact persisted bytes, conflicting identities, and key-counter safety. These tests do not exercise the entire native installer dependency graph, identity-manager lifecycle, encrypted-file crash recovery, production providers, or device acceptance. The framework must be rebuilt from the reviewed current source before running the probe. The normal app remains intentionally nonrunnable in compile-validation mode.


## Synchronous service factory gates

The main HTTP, storage/groups, updates and SVR URLSession factories now reject missing immutable capabilities before resolving upstream service constants, consulting fronting/DB state or constructing a session. Chat transport support is separate from `mainServiceHTTP`; having an authenticated chat connection does not implicitly enable a legacy HTTP origin. Direct endpoint and session entry points are checked as well. Existing explicitly selected legacy services retain their endpoint, trust and fronting behavior.

Storage/group authorization, group profile-credential loading, SGX handshake credentials, and periodic SVR credential refresh are gated before their respective fetches. The native websocket's existing failable constructor returns nil with a sanitized unavailable log; the SGX entry point preserves a typed unavailable error before reaching that constructor. AppSetup passes the already composed transport capabilities into SGX, with no default legacy capability. None of these gates enables an owned storage or group endpoint. Required pilot Groups/Stories still need separately validated owned routes and parameters before the account's pending-services barrier can be released.

Focused tests exercise both owned/default policy modes and the actual service protocol factory source. The separate simulator framework probe checks concrete HTTP factories and SGX before configuration, DB/session, credential or socket effects:

```sh
python3 Scripts/bconnected/probe_native_account_db.py --simulator <dedicated-simulator-UUID> --probe http-services
```

This is a bounded factory/credential boundary, not a claim that all UI/background, profile publication, account attributes, media or extension paths are ready. Owned attribute publication must omit recoveryPassword under the one-iPhone pilot policy. No live origin, upstream fallback, services-ready transition or backend release flag is added.


## Local self-recipient setup (services still gated)

After native account installation, the setup screen offers a separate local-account preparation action. The production SQLCipher transaction revalidates native material, the existing profile key-derived access key and all candidate ACI/PNI/phone recipient records before its first write. It creates or reuses one exact primary self-recipient, then atomically saves a receipt bound to the original attempt, key commitment, installed account, profile identity/access-key hash and recipient row/unique ID. It preserves the profile key, access key and display name. Partial, split, mismatched, unregistered or blocked candidate recipients fail closed; no block is cleared.

An exact repeat validates both receipt and native/recipient/profile state and writes nothing. The general enrollment store also avoids rewriting unchanged records. This slice calls no merge observers, remote services or omnibus registration lifecycle. It does not set account entropy, publish attributes/profile data, release pending-services, or complete navigation.

Validation for this slice: the actual unsigned compile-validation workspace build succeeded; 32 focused host tests passed (21 enrollment/community/installation/local preparation, two app view-model, nine native crypto). The separate actual-framework SQLCipher in-memory probe has six groups covering first insert, byte-preserving read-only retry/store recreation, rollback after the recipient and receipt writes, six partial/split/device identity conflicts including separate ACI/PNI/phone rows, preservation of all blocks, exact-row reuse and changed-profile-key rejection. Cached and recreated account readers remain unregistered with credentials withheld.

```sh
python3 Scripts/bconnected/probe_native_account_db.py --simulator <dedicated-simulator-UUID> --probe local-account
```

The probe invokes the production local setup transaction and real account staging validation. It does not instantiate the complete identity-manager dependency graph or test encrypted-file process-crash recovery; recreation means new store/account-reader objects over the same in-memory SQLCipher database. The app remains intentionally nonrunnable in compile-validation mode, and the pending-services and normal backend release guards remain intact.

## Ordinary attributes and encrypted-file process recovery

Owned/default account-attribute generation no longer derives a registration recovery password. The shared Codable wire boundary also omits `recoveryPassword`, including values supplied directly or decoded from earlier cached attributes. Explicit `BCONNECTED_LEGACY_TRANSPORT` retains its existing encoding. This applies to the ordinary `PUT v1/accounts/attributes` request without enabling that request, releasing account readiness, or adding account recovery.

Three host checks compile the exact production attribute type in owned, default and explicit legacy modes. A separate actual-framework simulator probe constructs the ordinary request and checks supplied and decoded recovery values, preserved account fields, and withheld account credentials:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -m unittest Scripts/bconnected/test_account_attributes.py -v
python3 Scripts/bconnected/probe_native_account_db.py --simulator <dedicated-simulator-UUID> --probe account-attributes
```

The new `file-recovery` probe uses an encrypted SQLCipher file and WAL with production database-key formatting and connection preparation. It launches 12 separate simulator processes, kills only its own probe process at four verified points, and reopens the file in later processes. The kill points cover uncommitted and committed native account/prekey/receipt writes and uncommitted and committed self-recipient/receipt preparation. Committed-WAL presence is checked before recovery; a different encryption key is rejected. Each recovery checks the original enrollment material, profile and relevant native key records, and confirms that credentials and identifiers remain hidden. A post-restart local-setup retry performs zero SQLite row changes and preserves receipt bytes.

```sh
python3 Scripts/bconnected/probe_native_account_db.py --simulator <dedicated-simulator-UUID> --probe file-recovery
```

On 2026-09-22 the actual unsigned compile-validation workspace graph, all three host checks, the actual request-factory probe and all 12 encrypted-file process phases passed. The probe stages native account and ACI/PNI signed/last-resort key stores using the production methods, then invokes the production local-account transaction; it does not instantiate the full native identity-manager installer, AppSetup or Signal.app. Keychain storage is replaced with a synthetic key loaded from a private temporary file. This establishes these bounded process-termination/restart properties, not device power-loss, iOS Keychain/file-protection, full installer lifecycle, provider or device messaging acceptance. Temporary files, including the synthetic key and enrollment database, are removed by the driver. No SMS, push or remote service is invoked.

Account entropy/remaining setup, owned profile/account publication, verified endpoint/trust/ZK inputs, complete service routing and navigation remain outstanding. Neither this probe nor the wire omission releases pending-services or the normal backend build guard.

## Local account entropy (services still gated)

The next source checkpoint adds “Finish local setup” to the actual signup screen after the local self-recipient has been prepared. Its production SQLCipher transaction revalidates native account/key material, the original profile/UAK and the exact unblocked self-recipient before saving a newly generated account entropy key and a hash receipt bound to the previous local-setup receipt. The key and receipt commit together. Exact retries verify the stored key and perform no writes. Missing, malformed, changed or unrelated prior keys are rejected; existing media-backup, backup settings, local-backup or key-sync state also stops first-install initialization and is preserved.

This deliberately avoids the upstream setter's logging-key completion callback and the entropy manager's recovery, backup, storage and sync lifecycle. It writes only the initial account entropy and its receipt; no backup key, backup ID, callback, request, credential publication or readiness notification is produced. Logging initialization and all services-ready effects remain part of a later, separately validated lifecycle. The existing account and ordinary attribute wire policy continue to withhold credentials and omit recoveryPassword.

Validation on 2026-09-22: the actual unsigned app/extensions/framework compile-validation graph built successfully. All **33 focused host tests** passed (22 enrollment/community/lifecycle, two actual app view-model and nine native cryptography). The actual-framework `local-account` probe now has **12 SQLCipher groups**, adding first entropy initialization, exact read-only retry, atomic rollback, seven conflict classes, missing/changed key rejection, preserved self-recipient blocks, receipt validation and absence of completion callbacks. The `file-recovery` probe now runs **18 fresh-process phases with six verified SIGKILL boundaries**, including uncommitted and committed entropy/receipt recovery. Post-restart entropy validation/retry preserves exact receipt bytes with zero SQLite row changes.

Rebuild with `build_graph.sh`, then run the `local-account` and `file-recovery` commands above against a dedicated simulator. The same bounded-probe limitations apply: the native identity-manager installer, real Keychain/file protection, device power loss, app startup, provider calls and device messaging are not covered. Owned profile/account publication, verified service routes/trust/ZK parameters, services-ready release, navigation and complete pilot acceptance remain outstanding. No normal messaging-configured build flag is enabled.

## Explicit owned group and sender-certificate authorities

Owned app and extension bundles now require two independent public configuration inputs:

- `BConnectedGroupPublicParamsBase64`: canonical base64 of the owned group's native `ServerPublicParams` serialization.
- `BConnectedSenderCertificateTrustRootsBase64`: one to eight distinct canonical base64 native `PublicKey` serializations, in the intended trust-root rotation order.

Native libsignal validates both formats and exact serialization round trips. Wrong types, missing inputs, duplicate/oversized roots, malformed native encodings and noncanonical base64 fail with a sanitized configuration error. These authorities are independent of the messaging host, TLS mode and certificate; none can supply or imply another. Parsing confirms format, not ownership or authorization. No deployment value is added to the production app or extension Info.plists by this source change.

Actual AppSetup checks the cryptographic inputs before constructing owned chat transport. Owned `TSConstants` accessors and their concrete production/staging instances use the supplied parameters and sender roots. Upstream group and sender authority constants are compiled only under explicit `BCONNECTED_LEGACY_TRANSPORT`. This reaches the real GroupsV2/profile and unidentified-delivery consumers; absent inputs never select upstream authorities. Other still-disabled service constants and routes are outside this bounded checkpoint.

The actual unsigned compile-validation graph passed. **69 owned-mode and 65 default-mode host tests** passed, including five new public-authority configuration cases per mode. A standalone actual-framework probe validated byte-preserving consumption through `TSConstants` (static, shared and both concrete environments), `GroupsV2Protos` and `OWSUDManagerImpl` using the public group parameters projected from the local runtime configuration and a clearly synthetic public sender-root fixture. The group parameter serialization was 673 bytes, SHA-256 `01c34eb26581889fb3e0023eac06616e1b023eee61fcad85b046910a39fd3aac`. The probe proves native parsing and configuration selection, not live group credentials, actual sender-certificate trust or remote service acceptance. No private sender-root secret is needed by this workflow.

```sh
python3 Scripts/bconnected/probe_native_account_db.py --simulator <dedicated-simulator-UUID> \
  --probe cryptographic-inputs --group-public-params-file /path/to/public-only-params.bin
```

The driver accepts only a bounded public-only binary parameters file and supplies the synthetic sender root solely inside its temporary test bundle. Do not point it at a whole server configuration or a secret. Real owned sender roots still require authoritative verification and explicit app/extension configuration, along with final verified endpoint/port/TLS inputs, service routing, profile/account publication, readiness lifecycle and pilot/device acceptance. Pending-services and the normal backend release guard remain intact.
