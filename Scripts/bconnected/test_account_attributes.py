"""Compile the exact production Codable source in owned, default and explicit legacy modes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "SignalServiceKit/Network/API/Requests/AccountAttributes/AccountAttributes.swift"
SUPPORT = """
public enum PhoneNumberDiscoverability { case everybody, nobody
    var isDiscoverable: Bool { self == .everybody }
}
extension Optional where Wrapped == PhoneNumberDiscoverability {
    var orAccountAttributeDefault: PhoneNumberDiscoverability { self ?? .everybody }
}
"""
MAIN = """
import Foundation
let attributes = AccountAttributes(isManualMessageFetchEnabled: true, registrationId: 23,
    pniRegistrationId: 42, unidentifiedAccessKey: "synthetic-access-key", unrestrictedUnidentifiedAccess: false,
    reglockToken: nil, registrationRecoveryPassword: "synthetic-recovery", encryptedDeviceName: nil,
    discoverableByPhoneNumber: .nobody, capabilities: .init(hasSVRBackups: false))
let data = try JSONEncoder().encode(attributes)
var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
#if BCONNECTED_LEGACY_TRANSPORT
precondition(object["recoveryPassword"] as? String == "synthetic-recovery")
#else
precondition(object["recoveryPassword"] == nil)
#endif
precondition(object["registrationId"] as? Int == 23 && object["pniRegistrationId"] as? Int == 42)
precondition(object["fetchesMessages"] as? Bool == true && object["discoverableByPhoneNumber"] as? Bool == false)
object["recoveryPassword"] = "synthetic-decoded"
let decoded = try JSONDecoder().decode(AccountAttributes.self, from: JSONSerialization.data(withJSONObject: object))
let repeated = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
#if BCONNECTED_LEGACY_TRANSPORT
precondition(repeated["recoveryPassword"] as? String == "synthetic-decoded")
#else
precondition(repeated["recoveryPassword"] == nil)
#endif
precondition(repeated["unidentifiedAccessKey"] as? String == "synthetic-access-key")
"""


class AccountAttributesTest(unittest.TestCase):
    def check_mode(self, condition):
        with tempfile.TemporaryDirectory(prefix="bconnected-attributes-") as directory:
            work = Path(directory)
            (work / "Support.swift").write_text(SUPPORT)
            (work / "main.swift").write_text(MAIN)
            command = ["xcrun", "swiftc", "-module-cache-path", str(work / "cache")]
            if condition:
                command += ["-D", condition]
            command += [str(SOURCE), str(work / "Support.swift"), str(work / "main.swift"), "-o", str(work / "probe")]
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([str(work / "probe")], check=True, capture_output=True, timeout=30)

    def test_owned_omits_recovery(self):
        self.check_mode("BCONNECTED_OWNED_LIBSIGNAL")

    def test_default_omits_recovery(self):
        self.check_mode(None)

    def test_explicit_legacy_preserves_recovery(self):
        self.check_mode("BCONNECTED_LEGACY_TRANSPORT")


if __name__ == "__main__":
    unittest.main()
