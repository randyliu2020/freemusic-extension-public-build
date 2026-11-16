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
        unsigned = assess_identity("com.example.player", {"present":False}, None)
        self.assertTrue(unsigned["problems"])
        self.assertEqual(unsigned["status"], "IDENTITY_MISMATCH_OR_UNSIGNED")
        result = assess_identity("com.example.player", {"present":True}, self.profile())
        self.assertEqual(result["status"], "IDENTITY_CHECK_INCOMPLETE")

    def test_missing_identity_fields_never_report_consistent(self):
        # Remove one field at a time from otherwise coherent inputs. A matching
        # application-identifier must not hide an unchecked team/prefix/date.
        cases = [("signature", "entitlements", "com.apple.developer.team-identifier"),
                 ("signature", None, "code_directory_identifiers"),
                 ("signature", None, "code_directory_teams"),
                 ("profile", "Entitlements", "com.apple.developer.team-identifier"),
                 ("profile", None, "ApplicationIdentifierPrefix"),
                 ("profile", None, "TeamIdentifier"),
                 ("profile", None, "ExpirationDate")]
        for owner, section, field in cases:
            with self.subTest(owner=owner, section=section, field=field):
                signature, profile = self.signature(), self.profile()
                target = signature if owner == "signature" else profile
                if section:
                    target = target[section]
                del target[field]
                result = assess_identity("com.example.player", signature, profile)
                self.assertEqual(result["status"], "IDENTITY_CHECK_INCOMPLETE")
                self.assertTrue(result["unknown"])
                self.assertFalse(result["problems"])

    def test_malformed_identity_fields_are_incomplete_not_coerced(self):
        for field, value in [("ApplicationIdentifierPrefix", "TEAM"),
                             ("ApplicationIdentifierPrefix", [""]),
                             ("TeamIdentifier", []), ("TeamIdentifier", [123]),
                             ("ExpirationDate", "2099-01-01"),
                             ("Entitlements", [])]:
            with self.subTest(field=field, value=value):
                profile = self.profile(); profile[field] = value
                result = assess_identity("com.example.player", self.signature(), profile)
                self.assertEqual(result["status"], "IDENTITY_CHECK_INCOMPLETE")
                self.assertTrue(result["unknown"])
        signature = self.signature()
        signature["entitlements"]["com.apple.developer.team-identifier"] = 123
        result = assess_identity("com.example.player", signature, self.profile())
        self.assertEqual(result["status"], "IDENTITY_CHECK_INCOMPLETE")

    def test_known_mismatch_is_not_downgraded_by_missing_metadata(self):
        profile = self.profile("TEAM.other.app")
        del profile["ExpirationDate"]
        result = assess_identity("com.example.player", self.signature(), profile)
        self.assertEqual(result["status"], "IDENTITY_MISMATCH_OR_UNSIGNED")
        self.assertTrue(result["problems"])
        self.assertTrue(result["unknown"])

    def test_expired_profile_is_reported(self):
        profile = self.profile(); profile["ExpirationDate"] = datetime(2000, 1, 1, tzinfo=timezone.utc)
        self.assertTrue(assess_identity("com.example.player", self.signature(), profile)["problems"])

    def test_profile_xml_extraction_is_explicitly_unambiguous(self):
        raw = plistlib.dumps(self.profile())
        self.assertEqual(profile_metadata(b"CMS_PREFIX" + raw + b"CMS_SUFFIX")["TeamIdentifier"], ["TEAM"])
        with self.assertRaises(PackageError): profile_metadata(raw + raw)


if __name__ == "__main__": unittest.main()
