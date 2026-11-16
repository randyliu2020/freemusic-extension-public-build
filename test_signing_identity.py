import unittest
from datetime import datetime, timezone
from verify_signing_identity import assess_identity, profile_metadata, PackageError
import plistlib


class IdentityTests(unittest.TestCase):
    def signature(self, app="TEAM.com.example.player"):
        return {"present":True, "entitlements":{"application-identifier":app, "com.apple.developer.team-identifier":"TEAM"},
                "code_directory_identifiers":["com.example.player"], "code_directory_teams":["TEAM"]}

    def profile(self, app="TEAM.com.example.player"):
        return {"Entitlements":{"application-identifier":app, "com.apple.developer.team-identifier":"TEAM"},
                "ApplicationIdentifierPrefix":["TEAM"], "TeamIdentifier":["TEAM"], "ExpirationDate":datetime(2099, 1, 1)}

    def test_exact_match_does_not_claim_signature_validation(self):
        result = assess_identity("com.example.player", self.signature(), self.profile())
        self.assertEqual(result["status"], "IDENTITIES_CONSISTENT_SIGNATURE_NOT_VERIFIED")
        self.assertFalse(result["cryptographic_signature_verified"])
        self.assertFalse(result["device_launch_verified"])

    def test_wildcard_profile_is_supported_but_signed_id_must_be_exact(self):
        self.assertFalse(assess_identity("com.example.player", self.signature(), self.profile("TEAM.*"))["problems"])
        self.assertTrue(assess_identity("com.example.player", self.signature("TEAM.*"), self.profile("TEAM.*"))["problems"])

    def test_matching_profile_and_signature_do_not_hide_wrong_bundle_id(self):
        result = assess_identity("com.example.player", self.signature("TEAM.some.other.app"), self.profile("TEAM.some.other.app"))
        self.assertTrue(result["problems"])

    def test_prefix_and_team_are_not_assumed_identical(self):
        signature = self.signature("OLDPREFIX.com.example.player")
        profile = self.profile("OLDPREFIX.*")
        profile["ApplicationIdentifierPrefix"] = ["OLDPREFIX"]
        self.assertFalse(assess_identity("com.example.player", signature, profile)["problems"])

    def test_profile_scope_and_team_mismatch_fail(self):
        self.assertTrue(assess_identity("com.example.player", self.signature(), self.profile("TEAM.other"))["problems"])
        profile = self.profile(); profile["TeamIdentifier"] = ["OTHER"]
        self.assertTrue(assess_identity("com.example.player", self.signature(), profile)["problems"])

    def test_unsigned_and_missing_xml_are_distinct(self):
        self.assertTrue(assess_identity("com.example.player", {"present":False}, None)["problems"])
        result = assess_identity("com.example.player", {"present":True}, self.profile())
        self.assertEqual(result["status"], "IDENTITY_CHECK_INCOMPLETE")

    def test_expired_profile_is_reported(self):
        profile = self.profile(); profile["ExpirationDate"] = datetime(2000, 1, 1, tzinfo=timezone.utc)
        self.assertTrue(assess_identity("com.example.player", self.signature(), profile)["problems"])

    def test_profile_xml_extraction_is_explicitly_unambiguous(self):
        raw = plistlib.dumps(self.profile())
        self.assertEqual(profile_metadata(b"CMS_PREFIX" + raw + b"CMS_SUFFIX")["TeamIdentifier"], ["TEAM"])
        with self.assertRaises(PackageError): profile_metadata(raw + raw)


if __name__ == "__main__": unittest.main()
