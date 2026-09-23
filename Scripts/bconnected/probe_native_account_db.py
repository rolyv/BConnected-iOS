#!/usr/bin/env python3
"""Bounded simulator DB probe. Requires an already-built compile-validation framework.
Runs a separate executable, never Signal.app. No registration/network/provider operations.
The file-recovery probe uses encrypted SQLCipher/WAL across SIGKILL/restart boundaries.
Other probes use in-memory storage. None launches Signal.app or contacts providers.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="UUID of an already booted dedicated simulator")
    parser.add_argument("--probe", choices=["native-account", "http-services", "local-account", "account-attributes", "file-recovery", "cryptographic-inputs", "group-avatar-form", "group-manifest"], default="native-account")
    parser.add_argument("--group-public-params-file", type=Path, help="Public-only binary parameters file for cryptographic-inputs; never a server configuration or private key")
    parser.add_argument("--public-authorities-file", type=Path, help="Optional public-only JSON with senderTrustRoot and senderCertificate; never a private key")
    args = parser.parse_args()
    if not os.environ.get("DEVELOPER_DIR"):
        parser.error("Set DEVELOPER_DIR to the reviewed Xcode installation")
    if (args.probe == "cryptographic-inputs") != (args.group_public_params_file is not None):
        parser.error("Only cryptographic-inputs requires --group-public-params-file")
    if args.public_authorities_file is not None and args.probe != "cryptographic-inputs":
        parser.error("Public authorities are only supported by cryptographic-inputs")
    products = ROOT / ".build/CompileValidation/Build/Products/Debug-iphonesimulator"
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    # Simulator processes cannot reliably read macOS-protected Documents folders.
    with tempfile.TemporaryDirectory(prefix="bconnected-db-probe-", dir="/private/tmp") as temporary:
        work = Path(temporary)
        bundle = work / "DBValidation.app"
        bundle.mkdir()
        if args.probe == "group-manifest":
            fixture = (ROOT / "SignalServiceKit/tests/Groups/bconnected-group-manifest-v1.json").read_bytes()
            if len(fixture) > 131072:
                parser.error("Manifest interoperability fixture exceeds bound")
            (bundle / "manifest-fixture.json").write_bytes(fixture)
        bundle_info = {
            "CFBundleExecutable": "native-db", "CFBundleIdentifier": "com.bconnected.validation.db",
            "CFBundleName": "DBValidation", "CFBundlePackageType": "APPL", "OWSBundleIDPrefix": "com.bconnected.validation",
        }
        if args.probe == "cryptographic-inputs":
            public = args.group_public_params_file.read_bytes()
            if not 0 < len(public) <= 4096:
                parser.error("Expected a bounded public-only binary parameters file")
            fixture = json.loads((ROOT / "SignalServiceKit/tests/Registration/registration-key-commitment-v1.json").read_text())
            bundle_info["BConnectedGroupPublicParamsBase64"] = base64.b64encode(public).decode("ascii")
            # This is a known public test-fixture key, NOT a production sender trust root.
            bundle_info["BConnectedSenderCertificateTrustRootsBase64"] = [fixture["aciIdentityKey"]]
            if args.public_authorities_file is not None:
                raw = args.public_authorities_file.read_bytes()
                if len(raw) > 8192:
                    parser.error("Public authorities file exceeds bound")
                authorities = json.loads(raw)
                if set(authorities) != {"senderCertificate", "senderTrustRoot", "senderCertificateId", "groupsServerPublic"}:
                    parser.error("Expected exact public-only authority fields")
                if base64.b64decode(authorities["groupsServerPublic"], validate=True) != public:
                    parser.error("Group public authority mismatch")
                bundle_info["BConnectedSenderCertificateTrustRootsBase64"] = [authorities["senderTrustRoot"]]
                bundle_info["BConnectedProbeServerCertificateBase64"] = authorities["senderCertificate"]
                bundle_info["BConnectedProbeServerCertificateId"] = authorities["senderCertificateId"]
        (bundle / "Info.plist").write_bytes(plistlib.dumps(bundle_info))
        subprocess.run(["cp", "-cR", str(products / "Signal.app/Frameworks"), str(work / "Frameworks")], check=True)
        command = ["xcrun", "--sdk", "iphonesimulator", "swiftc", "-target", "arm64-apple-ios27.0-simulator", "-sdk", sdk,
                   "-F", str(products), "-framework", "SignalServiceKit"]
        for directory in sorted(products.iterdir()):
            if directory.is_dir() and directory.suffix != ".framework":
                command += ["-F", str(directory)]
        # Explicit main.swift makes this a standalone top-level test executable.
        source = {"native-account": "NativeAccountDatabaseProbe.swift", "http-services": "HTTPServiceFactoryProbe.swift", "local-account": "LocalAccountSetupProbe.swift", "account-attributes": "AccountAttributesProbe.swift", "file-recovery": "EnrollmentFileRecoveryProbe.swift", "cryptographic-inputs": "OwnedCryptographicInputsProbe.swift", "group-avatar-form": "GroupAvatarFormProbe.swift", "group-manifest": "GroupManifestProbe.swift"}[args.probe]
        (work / "main.swift").write_bytes((ROOT / "Scripts/bconnected/tests" / source).read_bytes())
        command += ["-Xcc", "-I" + str(ROOT / "Pods/Headers/Public"), "-o", str(bundle / "native-db"), str(work / "main.swift")]
        subprocess.run(command, check=True, timeout=120)
        env = dict(os.environ, SIMCTL_CHILD_DYLD_FRAMEWORK_PATH=str(work / "Frameworks"))
        launch = ["xcrun", "simctl", "spawn", args.simulator, str(bundle / "native-db")]
        if args.probe not in {"file-recovery", "group-manifest"}:
            subprocess.run(launch, env=env, check=True, timeout=60)
            return
        database = work / "enrollment.sqlite"
        key = work / "synthetic-key"
        with key.open("xb") as handle:
            os.chmod(key, 0o600)
            handle.write(secrets.token_bytes(48))
        phases = ["initialize", "wrong-key", "install-crash", "verify-uninstalled",
                  "install-commit-crash", "verify-installed", "local-crash", "verify-installed",
                  "local-commit-crash", "verify-local", "retry-local", "verify-local",
                  "entropy-crash", "verify-local", "entropy-commit-crash", "verify-entropy",
                  "retry-entropy", "verify-entropy",
                  "publication-crash", "verify-unpublished", "publication-commit-crash", "verify-prepared",
                  "dispatch-crash", "verify-prepared", "dispatch-commit-crash", "verify-dispatched",
                  "ack-crash", "verify-dispatched", "ack-commit-crash", "verify-attributes",
                  "profile-acknowledge", "prekeys-crash", "verify-no-prekeys", "prekeys-commit-crash", "verify-prekeys",
                  "prekeys-dispatch-crash", "verify-prekeys", "prekeys-dispatch-commit-crash", "verify-prekeys-dispatched",
                  "prekeys-ack-crash", "verify-prekeys-dispatched", "prekeys-ack-commit-crash", "verify-prekeys-aci-ack",
                  "prekeys-finish", "verify-prekeys-complete", "prekeys-conflicts", "prekeys-legacy"]
        if args.probe == "group-manifest":
            phases = ["initialize", "remember-crash", "verify-absent", "remember-commit-crash", "verify-saved",
                      "advance-crash", "verify-saved", "advance-commit-crash", "verify-advanced"]
        marker = Path(str(database) + ".kill-point")
        for phase in phases:
            marker.unlink(missing_ok=True)
            result = subprocess.run(launch + [phase, str(database), str(key)], env=env, timeout=60)
            if phase.endswith("crash"):
                if result.returncode not in (-9, 9, 137) or not marker.exists() or marker.read_text() != phase:
                    raise RuntimeError(f"{phase}: expected deliberate SIGKILL at the verified phase")
                if "commit" in phase:
                    wal = Path(str(database) + "-wal")
                    if not wal.exists() or wal.stat().st_size <= 32:
                        raise RuntimeError(f"{phase}: committed WAL was absent before restart")
                print(f"PASS {phase}: deliberate SIGKILL observed", flush=True)
            else:
                result.check_returncode()
        print(f"{len(phases)} encrypted-file process phases passed; {sum(p.endswith('crash') for p in phases)} verified SIGKILL boundaries; no service readiness release")

if __name__ == "__main__":
    main()
