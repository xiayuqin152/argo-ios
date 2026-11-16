#!/usr/bin/env python3
"""Check a locally built unsigned Argo archive app and its IPA on macOS."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
from xml.parsers.expat import ExpatError
import zipfile

import check_project as project

require = project.require
ROOT = Path(__file__).resolve().parents[1]


def sha256(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def plist(data, label):
    try:
        value = plistlib.loads(data)
    except (plistlib.InvalidFileException, ExpatError, ValueError) as error:
        raise ValueError(f"{label}: invalid plist") from error
    require(isinstance(value, dict), f"{label}: expected a plist dictionary")
    return value


def release_settings():
    """Reuse the existing reader for the generated project used by the build."""
    text = (ROOT / "Argo.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    targets = re.findall(
        r"^[ \t]*([A-F0-9]{24})(?: /\*.*?\*/)? = \{",
        project.section(text, "PBXNativeTarget"), re.MULTILINE,
    )
    require(len(targets) == 1, "expected one application target")
    target = project.object_body(text, "PBXNativeTarget", targets[0])
    config = re.search(r"buildConfigurationList = ([A-F0-9]{24})", target)
    require(config is not None, "application target has no configurations")
    configs = project.object_body(text, "XCConfigurationList", config.group(1))
    release = re.findall(r"([A-F0-9]{24}) /\* Release \*/,", configs)
    require(len(release) == 1, "expected one Release application configuration")
    return project.build_settings(text, release[0])


def version(value):
    parts = str(value).split(".")
    require(1 <= len(parts) <= 3 and all(part.isdecimal() for part in parts),
            "invalid minimum OS version")
    return tuple(int(part) for part in (parts + ["0", "0"])[:3])


def tool_output(*command):
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    require(result.returncode == 0, f"{command[1]} failed (exit {result.returncode})")
    return result.stdout


def check_native(app, executable, minimum, report):
    require(sys.platform == "darwin",
            "macOS with Xcode tools is required for lipo/vtool/codesign")
    binary = str(app / executable)
    archs = tool_output("xcrun", "lipo", "-archs", binary).split()
    require(archs == ["arm64"], "main executable must contain only device arm64")
    build = tool_output("xcrun", "vtool", "-arch", "arm64", "-show-build", binary)
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", build, re.MULTILINE)
    minimums = re.findall(r"^\s*minos\s+(\S+)\s*$", build, re.MULTILINE)
    require(platforms == ["IOS"], "Mach-O build platform must be IOS, never Simulator")
    require(len(minimums) == 1 and version(minimums[0]) == version(minimum),
            "Mach-O minimum OS differs from the project")
    report["mach_o"] = {"architectures": archs, "platform": platforms[0],
                        "minimum_os": minimums[0]}
    report["checks"].append("arm64_iphoneos_mach_o")

    result = subprocess.run(
        ["xcrun", "codesign", "--display", "--verbose=4", str(app)],
        capture_output=True, text=True, encoding="utf-8",
    )
    details = result.stdout + result.stderr
    if result.returncode == 1 and "code object is not signed at all" in details:
        kind = "unsigned"
    elif result.returncode == 0:
        certificate = re.search(r"^Authority=", details, re.MULTILINE) is not None
        adhoc = re.search(r"^Signature=adhoc\s*$", details, re.MULTILINE) is not None
        report["signing"] = {"kind": "certificate" if certificate else "unrecognized"}
        require(adhoc and not certificate,
                "expected unsigned or ad-hoc code; certificate signatures are not allowed")
        kind = "ad-hoc"
    else:
        raise ValueError(f"codesign inspection failed (exit {result.returncode})")
    report["signing"] = {
        "kind": kind, "certificate_signature": False, "embedded_profile": False,
        "installable_distribution": False, "signed_apns_entitlement_verified": False,
    }
    report["checks"].append("unsigned_or_ad_hoc_without_profile")


def check_package(app, ipa, report):
    settings = release_settings()
    name = settings["PRODUCT_NAME"]
    require(app.is_dir() and app.name == name + ".app", "missing archive application")
    require(ipa.is_file(), "missing IPA")
    prefix = f"Payload/{name}.app/"
    with zipfile.ZipFile(ipa) as package:
        require(package.testzip() is None, "IPA ZIP CRC check failed")
        report["checks"].append("ipa_zip_crc")
        members = {}
        for item in package.infolist():
            path = PurePosixPath(item.filename)
            require(not path.is_absolute() and ".." not in path.parts,
                    "unsafe IPA member path")
            require(not stat.S_ISLNK(item.external_attr >> 16), "IPA contains a symlink")
            if item.filename.startswith(prefix) and not item.is_dir():
                relative = item.filename[len(prefix):]
                require(relative not in members, "duplicate IPA application member")
                members[relative] = item
        require("Info.plist" in members and name in members,
                "missing Payload application Info.plist or main executable")
        paths = list(app.rglob("*"))
        require(not any(path.is_symlink() for path in paths), "archive app contains a symlink")
        archive_files = {path.relative_to(app).as_posix(): path
                         for path in paths if path.is_file()}
        require(members.keys() == archive_files.keys(),
                "IPA and archive application file lists differ")
        hashes = {}
        for relative, path in archive_files.items():
            with path.open("rb") as source, package.open(members[relative]) as packaged:
                hashes[relative] = sha256(source)
                require(hashes[relative] == sha256(packaged),
                        f"IPA/archive content mismatch: {relative}")
        report["application_files_equal"] = len(hashes)
        report["checks"].append("ipa_archive_files_equal")

        require(not any(path.endswith(".mobileprovision") for path in members),
                "unexpected provisioning profile in unsigned package")
        report["checks"].append("no_provisioning_profile")
        info = plist(package.read(members["Info.plist"]), "packaged Info.plist")
        expected = {
            "CFBundleIdentifier": settings["PRODUCT_BUNDLE_IDENTIFIER"],
            "CFBundleName": name,
            "CFBundleDisplayName": settings["INFOPLIST_KEY_CFBundleDisplayName"],
            "CFBundleExecutable": name,
            "CFBundleShortVersionString": settings["MARKETING_VERSION"],
            "CFBundleVersion": settings["CURRENT_PROJECT_VERSION"],
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "DTPlatformName": "iphoneos",
            "UIDeviceFamily": [int(value) for value in settings["TARGETED_DEVICE_FAMILY"].split(",")],
        }
        for key, value in expected.items():
            require(info.get(key) == value, f"packaged {key} differs from the project")
        minimum = settings["IPHONEOS_DEPLOYMENT_TARGET"]
        require(version(info.get("MinimumOSVersion", "")) == version(minimum),
                "packaged MinimumOSVersion differs from the project")
        report["identity"] = {key: info[key] for key in expected}
        report["identity"]["MinimumOSVersion"] = info["MinimumOSVersion"]
        report["checks"].append("project_identity_version_platform")

        def expand(value):
            return re.sub(r"\$\((\w+)\)", lambda match: settings[match.group(1)], value)

        source_info = plist((ROOT / settings["INFOPLIST_FILE"]).read_bytes(), "source Info.plist")
        entitlements = plist((ROOT / settings["CODE_SIGN_ENTITLEMENTS"]).read_bytes(),
                             "source entitlements")
        require(expand(source_info["ArgoAPNSEnvironment"]) == "production"
                and expand(entitlements["aps-environment"]) == "production",
                "source Release APNs environment must be production")
        require(info.get("ArgoAPNSEnvironment") == "production",
                "packaged ArgoAPNSEnvironment must be production")
        report["apns_environment"] = "production"
        report["checks"].append("production_apns_configuration")

        permissions = {key: value for key, value in source_info.items()
                       if key.startswith("NS") and key.endswith("UsageDescription")}
        permissions.update({key.removeprefix("INFOPLIST_KEY_"): value
                            for key, value in settings.items()
                            if key.startswith("INFOPLIST_KEY_NS") and key.endswith("UsageDescription")})
        require(permissions, "source has no privacy usage descriptions")
        for key, value in permissions.items():
            require(isinstance(value, str) and value.strip()
                    and info.get(key) == expand(value),
                    f"missing or changed packaged {key}")
        report["usage_descriptions"] = {key: info[key] for key in permissions}
        report["checks"].append("source_usage_descriptions")

        privacy_name = "PrivacyInfo.xcprivacy"
        require(privacy_name in members, "missing packaged PrivacyInfo.xcprivacy")
        privacy = plist(package.read(members[privacy_name]), "packaged PrivacyInfo.xcprivacy")
        source_privacy = plist((ROOT / "Argo/Resources" / privacy_name).read_bytes(),
                               "source PrivacyInfo.xcprivacy")
        require(privacy == source_privacy, "packaged privacy manifest differs from source")
        require(any(entry.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
                    and "CA92.1" in entry.get("NSPrivacyAccessedAPITypeReasons", [])
                    for entry in privacy.get("NSPrivacyAccessedAPITypes", [])),
                "privacy manifest must declare UserDefaults reason CA92.1")
        report["privacy"] = privacy
        report["checks"].append("source_privacy_and_userdefaults_ca92_1")

        icon_name = settings["ASSETCATALOG_COMPILER_APPICON_NAME"]
        icon_keys = ["CFBundleIcons"]
        if 2 in expected["UIDeviceFamily"]:
            icon_keys.append("CFBundleIcons~ipad")
        for key in icon_keys:
            require(info.get(key, {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == icon_name,
                    f"missing or changed packaged {key} primary icon")
        icons = sorted(path for path in members
                       if "/" not in path and path.startswith(icon_name) and path.endswith(".png"))
        require(icons, "missing packaged AppIcon PNG resources")
        for path in icons:
            with package.open(members[path]) as image:
                require(image.read(8) == b"\x89PNG\r\n\x1a\n", "invalid packaged AppIcon PNG header")
        require("Assets.car" in members and members["Assets.car"].file_size > 0,
                "missing or empty packaged Assets.car")
        report["checks"].append("appicon_and_asset_resources")
        with ipa.open("rb") as source:
            report["sha256"] = {"ipa": sha256(source)}
        report["sha256"]["app"] = {
            path: hashes[path] for path in ["Info.plist", name, privacy_name, "Assets.car", *icons]
        }
    check_native(app, name, minimum, report)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-app", required=True, type=Path,
                        help="unpacked xcarchive/Products/Applications/Argo.app")
    parser.add_argument("--ipa", required=True, type=Path, help="generated unsigned IPA")
    parser.add_argument("--summary", type=Path, help="optional JSON summary file (also printed)")
    args = parser.parse_args(argv)
    report = {"status": "fail", "checks": []}
    try:
        check_package(args.archive_app.resolve(), args.ipa.resolve(), report)
        report["status"] = "pass"
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            zipfile.BadZipFile, RuntimeError) as error:
        report["error"] = str(error)
    output = json.dumps(report, ensure_ascii=False, separators=(",", ":")) + "\n"
    if len(output.encode("utf-8")) > 4096:
        report = {"status": "fail", "checks": report["checks"],
                  "error": "package check summary exceeds 4096 bytes"}
        output = json.dumps(report, separators=(",", ":")) + "\n"
    if args.summary:
        try:
            args.summary.write_text(output, encoding="utf-8")
        except OSError:
            report["status"] = "fail"
            report["error"] = "cannot write summary file"
            output = json.dumps(report, ensure_ascii=False, separators=(",", ":")) + "\n"
    print(output, end="")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
