#!/usr/bin/env python3
"""Build a device DM-alpha artifact from explicit public-only bundle inputs.

The unsigned build is for device-architecture review. --archive selects the normal
Xcode signing path; it does not upload to App Store Connect or prove live service
acceptance. All three executable bundles receive the same public configuration.
"""

import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[2]
PUBLIC_KEYS = {
    "BConnectedPilotScope": "BCONNECTED_PILOT_SCOPE",
    "BConnectedMessagingHost": "BCONNECTED_MESSAGING_HOST",
    "BConnectedMessagingPort": "BCONNECTED_MESSAGING_PORT",
    "BConnectedMessagingTrust": "BCONNECTED_MESSAGING_TRUST",
    "BConnectedEnrollmentOrigin": "BCONNECTED_ENROLLMENT_ORIGIN",
    "BConnectedCommunityOrigin": "BCONNECTED_COMMUNITY_ORIGIN",
    "BConnectedAccountPublicationOrigin": "BCONNECTED_ACCOUNT_PUBLICATION_ORIGIN",
    "BConnectedAccountPublicationTrust": "BCONNECTED_ACCOUNT_PUBLICATION_TRUST",
    "BConnectedGroupPublicParamsBase64": "BCONNECTED_GROUP_PUBLIC_PARAMS_BASE64",
    "BConnectedSenderCertificateTrustRootsBase64": "BCONNECTED_SENDER_ROOT_BASE64",
}
ORIGIN_KEYS = (
    "BConnectedEnrollmentOrigin",
    "BConnectedCommunityOrigin",
    "BConnectedAccountPublicationOrigin",
)


def release_settings() -> tuple[str, str, str]:
    """Product releases and Signal lineage come from one committed configuration."""
    contents = (ROOT / "Config/Project.xcconfig").read_text()
    keys = ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "BCONNECTED_SIGNAL_BASE_VERSION")
    values = []
    for key in keys:
        matches = re.findall(rf"^{key}\s*=\s*([^\s/]+)\s*$", contents, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"expected one explicit release setting: {key}")
        values.append(matches[0])
    validate_semantic_version(values[0])
    validate_semantic_version(values[2])
    if not re.fullmatch(r"[1-9][0-9]*", values[1]):
        raise ValueError("invalid committed build number")
    return tuple(values)


def validate_semantic_version(value: str) -> None:
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
        raise ValueError("BConnected versions must use MAJOR.MINOR.PATCH, for example 0.1.0")


def owned_host(host: str) -> str:
    if not isinstance(host, str) or not 1 <= len(host) <= 253:
        raise ValueError("invalid owned DNS host")
    lowered = host.lower()
    labels = lowered.split(".")
    if any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
           or label.startswith("xn--") for label in labels):
        raise ValueError("invalid owned DNS host")
    if all(label.isdecimal() or re.fullmatch(r"0x[0-9a-f]+", label) for label in labels):
        raise ValueError("numeric host is unavailable")
    if lowered in ("signal.org", "whispersystems.org") or lowered.endswith((".signal.org", ".whispersystems.org")):
        raise ValueError("Signal-operated origin is unavailable")
    return lowered


def owned_origin(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("owned origin must be a string")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise ValueError("invalid owned HTTPS origin")
    host = owned_host(parsed.hostname or "")
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError("invalid owned HTTPS port") from error
    if port not in (None, 443) or value not in (f"https://{host}", f"https://{host}:443"):
        raise ValueError("noncanonical owned HTTPS origin")
    return value


def canonical_base64(value: str, *, maximum: int, exact: int | None = None) -> bytes:
    if not isinstance(value, str) or not value or len(value) > ((maximum + 2) // 3) * 4:
        raise ValueError("invalid public authority encoding")
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("invalid public authority encoding") from error
    if not data or len(data) > maximum or (exact is not None and len(data) != exact) or base64.b64encode(data).decode() != value:
        raise ValueError("invalid public authority encoding")
    return data


def validate_public_config(config: object) -> dict[str, str]:
    if not isinstance(config, dict) or set(config) != set(PUBLIC_KEYS):
        raise ValueError("public DM-alpha configuration must contain exactly the documented keys")
    if any(not isinstance(value, (str, list)) for value in config.values()):
        raise ValueError("public DM-alpha configuration has an invalid value type")
    if config["BConnectedPilotScope"] != "foreground-text-dm-v1":
        raise ValueError("DM-alpha scope must be explicit")
    owned_host(config["BConnectedMessagingHost"])
    port = config["BConnectedMessagingPort"]
    if not isinstance(port, str) or not port.isascii() or not port.isdecimal() or len(port) > 5 or str(int(port)) != port or not 1 <= int(port) <= 65535:
        raise ValueError("invalid messaging port")
    # The focused artifact uses platform TLS trust. Certificate overrides remain
    # absent rather than being serialized as an empty, invalid plist value.
    if config["BConnectedMessagingTrust"] != "system" or config["BConnectedAccountPublicationTrust"] != "system":
        raise ValueError("DM-alpha artifact requires explicit system TLS trust")
    for key in ORIGIN_KEYS:
        owned_origin(config[key])
    canonical_base64(config["BConnectedGroupPublicParamsBase64"], maximum=4096)
    roots = config["BConnectedSenderCertificateTrustRootsBase64"]
    if not isinstance(roots, list) or len(roots) != 1:
        raise ValueError("this device artifact requires one explicit sender trust root")
    canonical_base64(roots[0], maximum=33, exact=33)
    return {setting: roots[0] if key == "BConnectedSenderCertificateTrustRootsBase64" else config[key]
            for key, setting in PUBLIC_KEYS.items()}


def inspect_bundles(product: Path, config: dict[str, str], marketing_version: str | None = None,
                    build_number: str | None = None, signal_base_version: str | None = None) -> None:
    import plistlib
    for plist in (
        product / "Info.plist",
        product / "PlugIns/SignalNSE.appex/Info.plist",
        product / "PlugIns/SignalShareExtension.appex/Info.plist",
    ):
        with plist.open("rb") as stream:
            actual = plistlib.load(stream)
        if marketing_version is not None and actual.get("CFBundleShortVersionString") != marketing_version:
            raise ValueError(f"DM-alpha bundle version missing or changed: {plist}")
        if build_number is not None and actual.get("CFBundleVersion") != build_number:
            raise ValueError(f"DM-alpha build number missing or changed: {plist}")
        if signal_base_version is not None and actual.get("BConnectedSignalBaseVersion") != signal_base_version:
            raise ValueError(f"Signal compatibility version missing or changed: {plist}")
        for key, setting in PUBLIC_KEYS.items():
            expected = [config[setting]] if key == "BConnectedSenderCertificateTrustRootsBase64" else config[setting]
            if actual.get(key) != expected:
                raise ValueError(f"public DM-alpha bundle input missing or changed: {plist.name} {key}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-config", required=True, type=Path, help="JSON with the ten explicit public Bundle keys")
    parser.add_argument("--archive", type=Path, help="create a signed .xcarchive using installed Xcode signing assets")
    parser.add_argument("--marketing-version", help="BConnected MAJOR.MINOR.PATCH; defaults to Config/Project.xcconfig")
    parser.add_argument("--build-number", help="monotonically increasing build number; defaults to Config/Project.xcconfig")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    try:
        config = validate_public_config(json.loads(args.public_config.read_text()))
        marketing_version, build_number, signal_base_version = release_settings()
        if args.marketing_version is None:
            args.marketing_version = marketing_version
        if args.build_number is None:
            args.build_number = build_number
        validate_semantic_version(args.marketing_version)
        if args.build_number is not None and (not args.build_number.isascii() or not args.build_number.isdecimal()
                                             or str(int(args.build_number)) != args.build_number
                                             or int(args.build_number) < 1):
            raise ValueError("invalid app build number")
        if args.validate_only:
            print("Validated explicit public DM-alpha configuration; native public-key parsing and live endpoints remain separate checks.")
            return 0
        environment = dict(os.environ)
        if not environment.get("DEVELOPER_DIR"):
            raise ValueError("set DEVELOPER_DIR to the selected Xcode developer directory")
        subprocess.run([sys.executable, "Scripts/bconnected/verify_libsignal.py", ".build/bconnected-libsignal", "--platform", "iphoneos"],
                       cwd=ROOT, env=environment, check=True)
        if args.archive:
            command = ["xcodebuild", "-workspace", "Signal.xcworkspace", "-scheme", "Signal", "-configuration", "App Store Release",
                       "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-allowProvisioningUpdates",
                       "-archivePath", str(args.archive.resolve()), "CODE_SIGN_STYLE=Automatic", "archive"]
            product = args.archive.resolve() / "Products/Applications/Signal.app"
        else:
            command = ["xcodebuild", "-workspace", "Signal.xcworkspace", "-scheme", "Signal", "-configuration", "Debug",
                       "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", ".build/DMAlphaDevice",
                       "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES", "ARCHS=arm64", "build"]
            product = ROOT / ".build/DMAlphaDevice/Build/Products/Debug-iphoneos/Signal.app"
        command += ["BCONNECTED_MESSAGING_CONFIGURED=YES",
                    "BCONNECTED_SELECTED_ENTITLEMENTS=Scripts/bconnected/DMAlpha.entitlements",
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BCONNECTED_MESSAGING_CONFIGURED BCONNECTED_OWNED_LIBSIGNAL"]
        command += [f"{key}={value}" for key, value in config.items()]
        command.append(f"BCONNECTED_SIGNAL_BASE_VERSION={signal_base_version}")
        if args.marketing_version is not None:
            command.append(f"MARKETING_VERSION={args.marketing_version}")
        if args.build_number is not None:
            command.append(f"CURRENT_PROJECT_VERSION={args.build_number}")
        subprocess.run(command, cwd=ROOT, env=environment, check=True)
        inspect_bundles(product, config, args.marketing_version, args.build_number, signal_base_version)
        print(f"Verified explicit public DM-alpha inputs in app and both extensions: {product}")
        return 0
    except subprocess.CalledProcessError as error:
        print(f"error: build command failed with exit status {error.returncode}", file=sys.stderr)
        return 1
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
