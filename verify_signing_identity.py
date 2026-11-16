"""Read-only identity checks for a user's locally re-signed FreeMusic IPA.

This is not cryptographic signature/provisioning validation and cannot prove
that iOS accepts the package or that Lock Screen launch works. It never reads
private keys, executes app code, changes the IPA or sends data to a server.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import struct
import sys
import zipfile

from package_extension import parse_macho, safe_zip_entries, LC_CODE_SIGNATURE, PackageError


def signature_metadata(binary: bytes) -> dict:
    commands = [command for command in parse_macho(binary, 2).commands if command.kind == LC_CODE_SIGNATURE]
    if not commands:
        return {"present": False, "entitlements": None, "code_directory_identifiers": []}
    if len(commands) != 1:
        raise PackageError("Multiple signature commands")
    offset, length = struct.unpack_from("<II", commands[0].raw, 8)
    blob = binary[offset:offset + length]
    if len(blob) < 12:
        raise PackageError("Truncated signature superblob")
    magic, used, count = struct.unpack_from(">III", blob)
    if magic != 0xFADE0CC0 or not 12 <= used <= len(blob) or count > (used - 12) // 8:
        raise PackageError("Invalid signature superblob")
    result = {"present": True, "entitlements": None, "code_directory_identifiers": [], "code_directory_teams": []}
    for index in range(count):
        slot, position = struct.unpack_from(">II", blob, 12 + index * 8)
        if position < 12 + count * 8 or position + 8 > used:
            raise PackageError("Invalid signature subblob offset")
        kind, size = struct.unpack_from(">II", blob, position)
        if size < 8 or position + size > used:
            raise PackageError("Invalid signature subblob length")
        item = blob[position:position + size]
        if slot == 5 and kind == 0xFADE7171:
            value = plistlib.loads(item[8:])
            if not isinstance(value, dict):
                raise PackageError("Signature entitlements are not a dictionary")
            result["entitlements"] = value
        if kind == 0xFADE0C02:
            if size < 44:
                raise PackageError("Truncated CodeDirectory")
            version, = struct.unpack_from(">I", item, 8)
            identity_offset, = struct.unpack_from(">I", item, 20)
            def string_at(start):
                end = item.find(b"\0", start)
                if start < 44 or end < start:
                    raise PackageError("Invalid CodeDirectory string")
                return item[start:end].decode("utf-8")
            result["code_directory_identifiers"].append(string_at(identity_offset))
            if version >= 0x20200 and size >= 52:
                team_offset, = struct.unpack_from(">I", item, 48)
                if team_offset:
                    result["code_directory_teams"].append(string_at(team_offset))
    return result


def profile_metadata(raw: bytes) -> dict:
    # Provisioning profiles wrap an XML plist in CMS. Extract only the visible
    # plist; no claim is made that the CMS signature or Apple chain is verified.
    if raw.count(b"<plist") != 1 or raw.count(b"</plist>") != 1:
        raise PackageError("Cannot unambiguously locate profile XML plist")
    start = raw.index(b"<plist")
    end = raw.index(b"</plist>", start) + len(b"</plist>")
    profile = plistlib.loads(raw[start:end])
    if not isinstance(profile, dict):
        raise PackageError("Provisioning profile is not a dictionary")
    return profile


def assess_identity(bundle_id: str, signature: dict, profile: dict | None) -> dict:
    problems, warnings, unknown = [], [], []
    signed = signature.get("entitlements")
    application_id = signed.get("application-identifier") if isinstance(signed, dict) else None
    signed_team = signed.get("com.apple.developer.team-identifier") if isinstance(signed, dict) else None
    if not signature.get("present"):
        problems.append("Main executable has no code signature; package must be signed before installation.")
    elif not application_id:
        unknown.append("No XML application-identifier was found; DER-only entitlements require Apple's codesign tooling.")
    if application_id and not application_id.endswith("." + bundle_id):
        problems.append("Signed application-identifier does not end with the exact Info.plist bundle identifier.")
    for identifier in set(signature.get("code_directory_identifiers", [])):
        if identifier != bundle_id:
            warnings.append("CodeDirectory identifier differs from Info.plist bundle identifier: " + identifier)
    profile_id = None
    expiry = None
    if profile is None:
        unknown.append("No embedded provisioning profile; profile scope was not checked.")
    else:
        entitlements = profile.get("Entitlements", {})
        profile_id = entitlements.get("application-identifier")
        prefixes = profile.get("ApplicationIdentifierPrefix", [])
        if application_id and prefixes and application_id not in [str(prefix) + "." + bundle_id for prefix in prefixes]:
            problems.append("Signed application-identifier is not a profile-authorized prefix plus this bundle identifier.")
        if application_id and profile_id:
            in_scope = application_id.startswith(profile_id[:-1]) if profile_id.endswith(".*") else application_id == profile_id
            if not in_scope:
                problems.append("Signed application-identifier is outside the provisioning profile scope.")
        elif not profile_id:
            unknown.append("Provisioning profile application-identifier is missing.")
        teams = profile.get("TeamIdentifier", [])
        profile_team = entitlements.get("com.apple.developer.team-identifier")
        if signed_team and ((teams and signed_team not in teams) or (profile_team and signed_team != profile_team)):
            problems.append("Signed team identifier differs from the profile team.")
        for team in set(signature.get("code_directory_teams", [])):
            if signed_team and team != signed_team:
                problems.append("CodeDirectory team differs from signed entitlement team.")
        expiry = profile.get("ExpirationDate")
        if isinstance(expiry, datetime):
            expiry = expiry.replace(tzinfo=timezone.utc) if expiry.tzinfo is None else expiry.astimezone(timezone.utc)
            if expiry < datetime.now(timezone.utc):
                problems.append("Embedded provisioning profile is expired.")
            expiry = expiry.isoformat()
    status = "IDENTITY_MISMATCH_OR_UNSIGNED" if problems else ("IDENTITY_CHECK_INCOMPLETE" if unknown else "IDENTITIES_CONSISTENT_SIGNATURE_NOT_VERIFIED")
    return {"status": status, "bundle_identifier": bundle_id,
        "signed_application_identifier": application_id, "signed_team_identifier": signed_team,
        "profile_application_identifier": profile_id, "profile_expiration_utc": expiry,
        "code_directory_identifiers": signature.get("code_directory_identifiers", []),
        "problems": problems, "warnings": warnings, "unknown": unknown,
        "cryptographic_signature_verified": False, "device_launch_verified": False,
        "next_validation": "On macOS run Apple's codesign verification on the fully signed app, then install and test on the iPhone. Matching identities are necessary packaging evidence, not proof that the Lock Screen opens the app."}


def verify_ipa(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        entries = safe_zip_entries(archive)
        names = [entry.filename for entry in entries]
        candidates = [name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist") and len(name.split("/")) == 3]
        if len(candidates) != 1:
            raise PackageError("Expected exactly one top-level app")
        info_path = candidates[0]
        app = info_path[:-len("Info.plist")]
        info = plistlib.loads(archive.read(info_path))
        executable, bundle_id = info.get("CFBundleExecutable"), info.get("CFBundleIdentifier")
        if not isinstance(executable, str) or any(char in executable for char in "/\\:\0") or executable in {"", ".", ".."}:
            raise PackageError("Invalid executable name")
        if not isinstance(bundle_id, str) or not bundle_id:
            raise PackageError("Missing bundle identifier")
        signature = signature_metadata(archive.read(app + executable))
        profile_path = app + "embedded.mobileprovision"
        profile = profile_metadata(archive.read(profile_path)) if profile_path in names else None
        return assess_identity(bundle_id, signature, profile)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    args = parser.parse_args()
    try:
        report = verify_ipa(args.ipa)
        print(json.dumps(report, indent=2, ensure_ascii=False))
        sys.exit(2 if report["problems"] else (3 if report["unknown"] else 0))
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        sys.exit(2)
