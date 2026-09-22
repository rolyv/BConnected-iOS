#!/usr/bin/env python3
"""Bounded simulator DB probe. Requires an already-built compile-validation framework.
Runs a separate executable, never Signal.app. No registration/network/provider operations.
The file-recovery probe uses encrypted SQLCipher/WAL across SIGKILL/restart boundaries.
Other probes use in-memory storage. None launches Signal.app or contacts providers.
"""
import argparse
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
    parser.add_argument("--probe", choices=["native-account", "http-services", "local-account", "account-attributes", "file-recovery"], default="native-account")
    args = parser.parse_args()
    if not os.environ.get("DEVELOPER_DIR"):
        parser.error("Set DEVELOPER_DIR to the reviewed Xcode installation")
    products = ROOT / ".build/CompileValidation/Build/Products/Debug-iphonesimulator"
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    # Simulator processes cannot reliably read macOS-protected Documents folders.
    with tempfile.TemporaryDirectory(prefix="bconnected-db-probe-", dir="/private/tmp") as temporary:
        work = Path(temporary)
        bundle = work / "DBValidation.app"
        bundle.mkdir()
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "native-db", "CFBundleIdentifier": "com.bconnected.validation.db",
            "CFBundleName": "DBValidation", "CFBundlePackageType": "APPL", "OWSBundleIDPrefix": "com.bconnected.validation",
        }))
        subprocess.run(["cp", "-cR", str(products / "Signal.app/Frameworks"), str(work / "Frameworks")], check=True)
        command = ["xcrun", "--sdk", "iphonesimulator", "swiftc", "-target", "arm64-apple-ios27.0-simulator", "-sdk", sdk,
                   "-F", str(products), "-framework", "SignalServiceKit"]
        for directory in sorted(products.iterdir()):
            if directory.is_dir() and directory.suffix != ".framework":
                command += ["-F", str(directory)]
        # Explicit main.swift makes this a standalone top-level test executable.
        source = {"native-account": "NativeAccountDatabaseProbe.swift", "http-services": "HTTPServiceFactoryProbe.swift", "local-account": "LocalAccountSetupProbe.swift", "account-attributes": "AccountAttributesProbe.swift", "file-recovery": "EnrollmentFileRecoveryProbe.swift"}[args.probe]
        (work / "main.swift").write_bytes((ROOT / "Scripts/bconnected/tests" / source).read_bytes())
        command += ["-Xcc", "-I" + str(ROOT / "Pods/Headers/Public"), "-o", str(bundle / "native-db"), str(work / "main.swift")]
        subprocess.run(command, check=True, timeout=120)
        env = dict(os.environ, SIMCTL_CHILD_DYLD_FRAMEWORK_PATH=str(work / "Frameworks"))
        launch = ["xcrun", "simctl", "spawn", args.simulator, str(bundle / "native-db")]
        if args.probe != "file-recovery":
            subprocess.run(launch, env=env, check=True, timeout=60)
            return
        database = work / "enrollment.sqlite"
        key = work / "synthetic-key"
        with key.open("xb") as handle:
            os.chmod(key, 0o600)
            handle.write(secrets.token_bytes(48))
        phases = ["initialize", "wrong-key", "install-crash", "verify-uninstalled",
                  "install-commit-crash", "verify-installed", "local-crash", "verify-installed",
                  "local-commit-crash", "verify-local", "retry-local", "verify-local"]
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
        print("12 encrypted-file process phases passed; four verified SIGKILL boundaries; no service readiness release")

if __name__ == "__main__":
    main()
