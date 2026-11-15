#!/usr/bin/env python3
"""Validate the generated Argo iOS project without Xcode or third-party modules."""

from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Argo.xcodeproj" / "project.pbxproj"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def section(text: str, name: str) -> str:
    match = re.search(
        rf"/\* Begin {re.escape(name)} section \*/(.*?)/\* End {re.escape(name)} section \*/",
        text,
        re.DOTALL,
    )
    require(match is not None, f"missing {name} section")
    return match.group(1)


def object_body(text: str, section_name: str, identifier: str) -> str:
    body = section(text, section_name)
    match = re.search(
        rf"^[ \t]*{re.escape(identifier)}(?: /\*.*?\*/)? = \{{(.*?)^[ \t]*\}};",
        body,
        re.MULTILINE | re.DOTALL,
    )
    require(match is not None, f"missing {section_name} object {identifier}")
    return match.group(1)


def unquote(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return json.loads(value)
    return value


def build_settings(text: str, identifier: str) -> dict[str, str]:
    body = object_body(text, "XCBuildConfiguration", identifier)
    require("buildSettings = {" in body, f"configuration {identifier} has no build settings")
    settings = {}
    for line in body.split("buildSettings = {", 1)[1].splitlines():
        match = re.match(r"^[ \t]*([A-Za-z][A-Za-z0-9_]*) = (.*);$", line)
        if match:
            settings[match.group(1)] = unquote(match.group(2))
    return settings


def main() -> int:
    try:
        text = PROJECT.read_text(encoding="utf-8")
        targets = re.findall(r"^[ \t]*([A-F0-9]{24})(?: /\*.*?\*/)? = \{", section(text, "PBXNativeTarget"), re.MULTILINE)
        require(len(targets) == 1, "expected exactly one native application target named Argo")
        target = object_body(text, "PBXNativeTarget", targets[0])
        require('productType = "com.apple.product-type.application";' in target, "Argo is not an iOS application target")
        require("name = Argo;" in target, "unexpected target name")
        list_match = re.search(r"buildConfigurationList = ([A-F0-9]{24})", target)
        require(list_match is not None, "target has no build configuration list")
        configurations = object_body(text, "XCConfigurationList", list_match.group(1))
        config_ids = re.findall(r"([A-F0-9]{24}) /\* (Debug|Release) \*/,", configurations)
        require(Counter(name for _, name in config_ids) == Counter({"Debug": 1, "Release": 1}), "expected only Debug and Release target configurations")

        expected = {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGN_STYLE": "Automatic",
            "GENERATE_INFOPLIST_FILE": "YES",
            "INFOPLIST_KEY_CFBundleDisplayName": "Argo",
            "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.argo.ios",
            "PRODUCT_NAME": "Argo",
            "SUPPORTS_MACCATALYST": "NO",
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "SWIFT_VERSION": "6.0",
            "TARGETED_DEVICE_FAMILY": "1,2",
        }
        for identifier, name in config_ids:
            settings = build_settings(text, identifier)
            for key, value in expected.items():
                require(settings.get(key) == value, f"{name}: {key} must be {value!r}, got {settings.get(key)!r}")
            require(settings.get("INFOPLIST_KEY_NSLocalNetworkUsageDescription", "").strip(), f"{name}: missing local-network usage description")
            require(settings.get("INFOPLIST_KEY_NSPhotoLibraryUsageDescription", "").strip(), f"{name}: missing photo-library usage description")
            require("DEVELOPMENT_TEAM" not in settings, f"{name}: development team must be selected by the user in Xcode")
        require(not re.search(r"\bDEVELOPMENT_TEAM\s*=", text), "project contains a development team")
        require("NSAllowsArbitraryLoads" not in text and "NSAppTransportSecurity" not in text, "unexpected ATS exception")
        require("NSBonjourServices" not in text, "Bonjour services are not declared without a Bonjour browser")

        packages = section(text, "XCLocalSwiftPackageReference")
        paths = set(re.findall(r"relativePath = (\"[^\"]+\"|[^;]+);", packages))
        paths = {unquote(path) for path in paths}
        require(paths == {"Packages/ArgoMobileKit", "ThirdParty/BeautifulUI"}, f"unexpected local package paths: {sorted(paths)}")
        require("XCRemoteSwiftPackageReference" not in text, "dependencies must remain same-repository local packages")
        products = section(text, "XCSwiftPackageProductDependency")
        require("productName = ArgoMobileKit;" in products, "missing ArgoMobileKit product dependency")
        require("productName = BeautifulUI;" in products, "missing BeautifulUI product dependency")
        for forbidden in ("/data00/", "/home/", "/tmp/", "/Users/", "file://"):
            require(forbidden not in text, f"generated project contains a machine-specific path: {forbidden}")

        app_sources = [path for path in (ROOT / "Argo").rglob("*.swift")
                       if "Verification" not in path.relative_to(ROOT / "Argo").parts]
        expected_sources = Counter(path.name for path in app_sources)
        require(expected_sources, "no Swift application sources found under ios/Argo")
        actual_sources = Counter(re.findall(r"/\* ([^*]+\.swift) in Sources \*/", section(text, "PBXSourcesBuildPhase")))
        require(actual_sources == expected_sources, f"Swift source membership differs: expected {expected_sources}, got {actual_sources}")
        swift = "\n".join(path.read_text(encoding="utf-8") for path in app_sources)
        require(len(re.findall(r"@main\s+", swift)) == 1, "expected exactly one @main application entry")
        require(re.search(r"@main\s+(?:public\s+)?struct\s+ArgoApp\s*:\s*(?:SwiftUI\.)?App\b", swift) is not None, "@main must be ArgoApp: App")

        assets = ROOT / "Argo" / "Resources" / "Assets.xcassets"
        icon = assets / "AppIcon.appiconset" / "Contents.json"
        require(icon.is_file(), "missing UI-owned Assets.xcassets/AppIcon.appiconset")
        require("Assets.xcassets in Resources" in section(text, "PBXResourcesBuildPhase"), "asset catalog is not in the resources build phase")
        for contents in assets.rglob("Contents.json"):
            data = json.loads(contents.read_text(encoding="utf-8"))
            for item in data.get("images", []):
                filename = item.get("filename")
                if filename:
                    require((contents.parent / filename).is_file(), f"missing asset file referenced by {contents.relative_to(ROOT)}: {filename}")
        image_names = set(re.findall(r'\bImage\(\s*"([^"]+)"\s*\)', swift))
        for name in sorted(image_names):
            require(any((assets / f"{name}{suffix}").is_dir() for suffix in (".imageset", ".symbolset")), f"missing asset catalog entry for Image(\"{name}\")")

        for package, name in (("Packages/ArgoMobileKit", "ArgoMobileKit"), ("ThirdParty/BeautifulUI", "BeautifulUI")):
            manifest = ROOT / package / "Package.swift"
            require(manifest.is_file(), f"missing local package manifest: {package}")
            require(f'name: "{name}"' in manifest.read_text(encoding="utf-8"), f"unexpected package identity in {package}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"iOS project validation failed: {error}", file=sys.stderr)
        return 1
    print(f"OK: one iOS app target, {sum(expected_sources.values())} Swift files, two local packages, assets and privacy settings validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
