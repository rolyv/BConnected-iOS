#!/usr/bin/env python3
"""Bounded simulator DB probe. Requires an already-built compile-validation framework.
Runs a separate executable, never Signal.app. No registration/network/provider operations.
The test uses SQLCipher's in-memory DB; it does not test encrypted-file crash recovery.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="UUID of an already booted dedicated simulator")
    parser.add_argument("--probe", choices=["native-account", "http-services", "local-account"], default="native-account")
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
        source = {"native-account": "NativeAccountDatabaseProbe.swift", "http-services": "HTTPServiceFactoryProbe.swift", "local-account": "LocalAccountSetupProbe.swift"}[args.probe]
        (work / "main.swift").write_bytes((ROOT / "Scripts/bconnected/tests" / source).read_bytes())
        command += ["-Xcc", "-I" + str(ROOT / "Pods/Headers/Public"), "-o", str(bundle / "native-db"), str(work / "main.swift")]
        subprocess.run(command, check=True, timeout=120)
        env = dict(os.environ, SIMCTL_CHILD_DYLD_FRAMEWORK_PATH=str(work / "Frameworks"))
        subprocess.run(["xcrun", "simctl", "spawn", args.simulator, str(bundle / "native-db")], env=env, check=True, timeout=60)

if __name__ == "__main__":
    main()
