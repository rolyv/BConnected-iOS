"""Focused input checks for the explicit, public-only device artifact builder."""

import base64
import copy
import unittest

from build_dm_alpha_device import validate_public_config, owned_origin


class DMAlphaBuildInputTest(unittest.TestCase):
    def valid(self):
        return {
            "BConnectedPilotScope": "foreground-text-dm-v1",
            "BConnectedMessagingHost": "chat.belenchat.com",
            "BConnectedMessagingPort": "443",
            "BConnectedMessagingTrust": "system",
            "BConnectedEnrollmentOrigin": "https://api.belenchat.com",
            "BConnectedCommunityOrigin": "https://community.belenchat.com",
            "BConnectedAccountPublicationOrigin": "https://api.belenchat.com",
            "BConnectedAccountPublicationTrust": "system",
            "BConnectedGroupPublicParamsBase64": base64.b64encode(bytes(range(33))).decode(),
            "BConnectedSenderCertificateTrustRootsBase64": [base64.b64encode(bytes(range(33))).decode()],
        }

    def test_valid_public_inputs_map_to_build_settings(self):
        settings = validate_public_config(self.valid())
        self.assertEqual(settings["BCONNECTED_PILOT_SCOPE"], "foreground-text-dm-v1")
        self.assertEqual(settings["BCONNECTED_SENDER_ROOT_BASE64"], self.valid()["BConnectedSenderCertificateTrustRootsBase64"][0])

    def test_missing_extra_or_unsafe_inputs_fail_before_xcode(self):
        cases = []
        valid = self.valid()
        for key in valid:
            changed = copy.deepcopy(valid)
            del changed[key]
            cases.append(changed)
        for key, value in (
            ("BConnectedMessagingHost", "chat.signal.org"),
            ("BConnectedMessagingHost", "127.0.0.1"),
            ("BConnectedMessagingPort", "0443"),
            ("BConnectedMessagingTrust", "insecure"),
            ("BConnectedEnrollmentOrigin", "https://api.signal.org"),
            ("BConnectedCommunityOrigin", "https://community.belenchat.com/path"),
            ("BConnectedAccountPublicationOrigin", "http://api.belenchat.com"),
            ("BConnectedAccountPublicationTrust", "certificate"),
            ("BConnectedGroupPublicParamsBase64", "bad"),
            ("BConnectedSenderCertificateTrustRootsBase64", []),
            ("BConnectedSenderCertificateTrustRootsBase64", [valid["BConnectedSenderCertificateTrustRootsBase64"][0]] * 2),
        ):
            changed = copy.deepcopy(valid)
            changed[key] = value
            cases.append(changed)
        changed = copy.deepcopy(valid)
        changed["password"] = "never pass secrets as public bundle settings"
        cases.append(changed)
        for case in cases:
            with self.subTest(case=case):
                with self.assertRaises(ValueError):
                    validate_public_config(case)

    def test_origin_requires_exact_owned_https_dns(self):
        self.assertEqual(owned_origin("https://api.belenchat.com"), "https://api.belenchat.com")
        for value in ("https://API.belenchat.com", "https://api.belenchat.com/other", "https://api.belenchat.com?x=1",
                      "https://user@api.belenchat.com", "https://xn--test.example", "https://127.0.0.1",
                      "https://api.signal.org", "https://api.belenchat.com:8443"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                owned_origin(value)


if __name__ == "__main__":
    unittest.main()
