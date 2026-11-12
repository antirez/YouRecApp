#!/usr/bin/env python3
"""Sign a YouRec archive locally and distribute it to the external TestFlight group."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys
import tempfile
import time
import zipfile


BUNDLE = "com.antirez.yourec"
GROUP = "YouRec Beta"
PROFILE = "yourec-testflight"
ASSETS = Path.home() / "Library/Application Support/YouRec/TestFlightSigning"


def asc(*args):
    data = subprocess.check_output(["asc", "--profile", PROFILE, *args])
    return json.loads(data) if data.strip() else None


def api_get(path, *query):
    args = [arg for value in query for arg in ("--query", value)]
    return asc("api", "GET", path, *args)


def unique(items, description):
    if len(items) != 1:
        raise SystemExit(f"Expected one {description}, found {len(items)}.")
    return items[0]


def signed_ipa(archive, work):
    profile_path = ASSETS / "YouRec.mobileprovision"
    profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", profile_path]))
    if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise SystemExit("The local App Store provisioning profile has expired. Renew the signing assets before uploading.")
    team = unique(profile["TeamIdentifier"], "signing team")
    entitlements = profile["Entitlements"]
    if (entitlements.get("application-identifier") != f"{team}.{BUNDLE}"
            or entitlements.get("get-task-allow") or profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices")):
        raise SystemExit("The provisioning profile must be an App Store profile for YouRec.")
    cert = unique(profile["DeveloperCertificates"], "distribution certificate")
    keychain = work / "release.keychain-db"
    identity_pass = work / "identity-password"
    with identity_pass.open("xb") as handle:
        subprocess.run(["security", "find-generic-password", "-a", PROFILE,
                        "-s", "com.antirez.yourec.testflight.signing", "-w"], stdout=handle, check=True)
    keychain_pass = work / "keychain-password"
    keychain_pass.write_text(secrets.token_hex(32))
    options = work / "ExportOptions.plist"
    options.write_bytes(plistlib.dumps({
        "method": "app-store-connect", "destination": "export", "teamID": team,
        "signingStyle": "manual", "signingCertificate": hashlib.sha1(cert).hexdigest().upper(),
        "provisioningProfiles": {BUNDLE: profile["UUID"]}, "manageAppVersionAndBuildNumber": False,
        "testFlightInternalTestingOnly": False, "uploadSymbols": True,
    }))
    asc("profiles", "local", "install", "--path", str(profile_path), "--force")
    try:
        asc("signing", "keychain", "install", "--identity", str(ASSETS / "distribution.p12"),
            "--identity-password-file", str(identity_pass), "--keychain-password-file", str(keychain_pass),
            "--keychain", str(keychain), "--expected-certificate-sha256", hashlib.sha256(cert).hexdigest(),
            "--add-to-search-list", "--confirm")
        output = work / "export"
        subprocess.run(["xcodebuild", "-exportArchive", "-archivePath", archive,
                        "-exportOptionsPlist", options, "-exportPath", output], check=True)
        return unique(list(output.glob("*.ipa")), "exported IPA")
    finally:
        if keychain.exists():
            subprocess.run(["security", "delete-keychain", keychain], check=True)
        identity_pass.unlink(missing_ok=True)
        keychain_pass.unlink(missing_ok=True)


def matching_build(app, version, number):
    result = api_get("/v1/builds", f"filter[app]={app}", f"filter[version]={number}", "include=preReleaseVersion")
    versions = {item["id"] for item in result.get("included", []) if item["type"] == "preReleaseVersions"
                and item["attributes"]["version"] == version and item["attributes"]["platform"] == "IOS"}
    matches = [item for item in result["data"] if item["relationships"]["preReleaseVersion"]["data"]["id"] in versions]
    return unique(matches, "matching iOS build") if matches else None


def archive_source():
    repo = Path(__file__).resolve().parents[1]
    now = datetime.now()
    directory = Path.home() / "Library/Developer/Xcode/Archives" / now.strftime("%Y-%m-%d")
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / now.strftime("YouRec %Y-%m-%d %H-%M-%S.xcarchive")
    if archive.exists():
        raise SystemExit(f"Archive already exists: {archive}")
    print(f"Archiving Release to {archive}", flush=True)
    subprocess.run(["xcodebuild", "-project", "YouRec.xcodeproj", "-scheme", "YouRec",
                    "-configuration", "Release", "-destination", "generic/platform=iOS",
                    "-derivedDataPath", "build-release", "-archivePath", archive,
                    "-skipPackageUpdates", "CODE_SIGNING_ALLOWED=NO", "archive"], cwd=repo, check=True)
    return archive


def publish(args):
    notes = args.notes.read_text().strip()
    if not notes:
        raise SystemExit("Supply nonempty What to Test notes.")
    archive = args.archive.expanduser().resolve(strict=True) if args.archive else archive_source()
    info = plistlib.loads((archive / "Products/Applications/YouRec.app/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != BUNDLE:
        raise SystemExit("The archive must contain YouRec.")
    version, number = info["CFBundleShortVersionString"], str(info["CFBundleVersion"])
    app = unique(api_get("/v1/apps", f"filter[bundleId]={BUNDLE}")["data"], "YouRec app")["id"]
    groups = api_get("/v1/betaGroups", f"filter[app]={app}", f"filter[name]={GROUP}")["data"]
    external = [item for item in groups if item["attributes"]["name"] == GROUP and not item["attributes"]["isInternalGroup"]]
    group = unique(external, "YouRec Beta external group")["id"]
    build = matching_build(app, version, number)
    uploads = api_get(f"/v1/apps/{app}/buildUploads", f"filter[cfBundleVersion]={number}",
                      f"filter[cfBundleShortVersionString]={version}", "filter[platform]=IOS",
                      "fields[buildUploads]=state,uploadedDate")["data"]
    processing = any(item["attributes"]["state"]["state"] in ("PROCESSING", "COMPLETE")
                     for item in uploads)
    if (build or processing) and not args.resume:
        raise SystemExit(f"YouRec {version} ({number}) already reached Apple. Use --archive '{archive}' --resume to continue.")
    if args.resume and not build and not processing:
        raise SystemExit("Apple has no committed upload for this archive. Inspect upload status before retrying.")
    if not build and not args.resume:
        print(f"Signing YouRec {version} ({number}) for TestFlight.", flush=True)
        with tempfile.TemporaryDirectory(prefix="yourec-testflight-") as tmp:
            ipa = signed_ipa(archive, Path(tmp))
            with zipfile.ZipFile(ipa) as package:
                signed = plistlib.loads(package.read("Payload/YouRec.app/Info.plist"))
                for field in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString"):
                    if signed[field] != info[field]:
                        raise SystemExit(f"Export changed {field}; stopping before upload.")
            print("Uploading the distribution-signed IPA and waiting for Apple to process it.", flush=True)
            asc("builds", "upload", "--app", app, "--ipa", str(ipa), "--wait", "--poll-interval", "15s")
        build = matching_build(app, version, number)
    deadline = time.monotonic() + 25 * 60
    while not build or build["attributes"]["processingState"] == "PROCESSING":
        if time.monotonic() >= deadline:
            raise SystemExit("Apple is still processing. Retry with --resume.")
        time.sleep(15)
        build = matching_build(app, version, number)
    if build["attributes"].get("expired"):
        raise SystemExit("This TestFlight build has expired.")
    if build["attributes"]["processingState"] != "VALID":
        raise SystemExit(f"Apple reports {build['attributes']['processingState']}; stopping.")
    build_id = build["id"]
    if build["attributes"].get("usesNonExemptEncryption") is None:
        if info.get("ITSAppUsesNonExemptEncryption") is True:
            raise SystemExit("Archive declares non-exempt encryption. Complete its declaration on Apple.")
        if info.get("ITSAppUsesNonExemptEncryption") is not False and not args.exempt_encryption:
            raise SystemExit("Export compliance is missing. If this build uses only exempt encryption, rerun with --resume --exempt-encryption.")
        asc("builds", "update", "--build-id", build_id, "--uses-non-exempt-encryption=false")
    localizations = api_get(f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]
    en = next((item for item in localizations if item["attributes"]["locale"] == "en-US"), None)
    if not en or en["attributes"].get("whatsNew") != notes:
        asc("builds", "test-notes", "update" if en else "create", "--build-id", build_id,
            "--locale", "en-US", "--whats-new", notes)
    def assigned():
        members = asc("api", "GET", f"/v1/betaGroups/{group}/relationships/builds", "--paginate")
        return any(item["id"] == build_id for item in members["data"])

    state = api_get(f"/v1/builds/{build_id}/buildBetaDetail")["data"]
    if not state["attributes"]["autoNotifyEnabled"]:
        payload = {"data": {"type": "buildBetaDetails", "id": state["id"], "attributes": {"autoNotifyEnabled": True}}}
        asc("api", "PATCH", f"/v1/buildBetaDetails/{state['id']}", "--body", json.dumps(payload), "--confirm")
    needs_review = state["attributes"]["externalBuildState"] == "READY_FOR_BETA_SUBMISSION"
    if not assigned():
        review_flags = ["--submit", "--confirm"] if needs_review else []
        asc("builds", "add-groups", "--build-id", build_id, "--group", group, *review_flags)
    elif needs_review:
        asc("testflight", "review", "submit", "--build-id", build_id, "--confirm")
    if not assigned():
        raise SystemExit("Apple has not confirmed external group assignment. Retry with --resume.")
    state = api_get(f"/v1/builds/{build_id}/buildBetaDetail")["data"]["attributes"]
    print(f"YouRec {version} ({number}) · {GROUP} · {state['externalBuildState']} · notify={state['autoNotifyEnabled']}")
    print(f"https://appstoreconnect.apple.com/apps/{app}/testflight/ios/{build_id}")
    if state["externalBuildState"] not in {"IN_BETA_TESTING", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"}:
        raise SystemExit("The external beta is still awaiting distribution. Check its status before retrying with --resume.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Reuse an existing Release .xcarchive instead of archiving the current source")
    parser.add_argument("notes", type=Path, help="English What to Test text file")
    parser.add_argument("--resume", action="store_true", help="Finish distributing an already uploaded build")
    parser.add_argument("--exempt-encryption", action="store_true", help="Declare that this build uses only exempt encryption if Apple asks")
    os.umask(0o077)
    args = parser.parse_args()
    if args.resume and not args.archive:
        parser.error("--resume requires --archive to identify the exact build")
    if not ASSETS.is_dir():
        parser.exit(1, f"Configure the local distribution identity in {ASSETS} first.\n")
    with (ASSETS / "publish.lock").open("a") as release_lock:
        try:
            fcntl.flock(release_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.exit(1, "Another local TestFlight release is running.\n")
        try:
            publish(args)
        except subprocess.CalledProcessError as exc:
            sys.exit(f"{exc.cmd[0]} failed with exit code {exc.returncode}.")
