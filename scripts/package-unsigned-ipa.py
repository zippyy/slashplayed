#!/usr/bin/env python3
"""Package the unsigned iOS client from the companion's already-built resources.

This deliberately does not sign the bundle or include Blizzard's copyrighted game
executables. Sign the IPA and its nested JIT helper with suitable profiles later.
"""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "build/companion/resources/ios"
CLIENT = ROOT / "apps/client"
ADDONS = ROOT / "addon"
VERSION_FILE = ROOT / "apps/companion/project.yml"


def render(template: Path, bundle_id: str, version: str) -> bytes:
    values = {
        "@BUNDLE_ID@": bundle_id,
        "@VERSION@": version,
        "@PLATFORM@": "iPhoneOS",
        "@DTPLATFORM@": "iphoneos",
        "@MINOS@": "26.0",
        "@FAMILY@": "<integer>1</integer><integer>2</integer>",
        "@PLATFORM_KEYS@": (
            "<key>UILaunchScreen</key><dict/>"
            "<key>UIStatusBarHidden</key><true/>"
            "<key>UISupportedInterfaceOrientations~iphone</key><array>"
            "<string>UIInterfaceOrientationLandscapeLeft</string>"
            "<string>UIInterfaceOrientationLandscapeRight</string></array>"
            "<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>"
            "<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>"
            "<key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
            "<key>CFBundleIcons~ipad</key><dict><key>CFBundlePrimaryIcon</key><dict>"
            "<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string>"
            "<string>AppIcon76x76</string></array>"
            "<key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
        ),
    }
    raw = template.read_text()
    for old, new in values.items():
        raw = raw.replace(old, new)
    if "@" in raw.replace("@executable_path", ""):
        raise RuntimeError(f"Unresolved template placeholder in {template}")
    plist = plistlib.loads(raw.encode())
    return plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)


def copy(src: Path, dst: Path):
    if not src.exists():
        raise FileNotFoundError(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst)
    else:
        shutil.copy2(src, dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", default="com.strawdynamics.slashplayed")
    ap.add_argument("--version", default="1.4.0")
    ap.add_argument("--output", default="dist/Slashplayed-unsigned.ipa")
    args = ap.parse_args()
    if not RESOURCES.joinpath("slashplayed").exists():
        raise SystemExit("Build the companion first: apps/companion/build.sh")
    with tempfile.TemporaryDirectory(prefix="slashplayed-ipa-") as temporary:
        app = Path(temporary) / "Payload/Slashplayed.app"
        app.mkdir(parents=True)
        helper = app / "PlugIns/SPJitHelper.appex"
        copy(RESOURCES / "slashplayed", app / "slashplayed")
        copy(RESOURCES / "SPJitHelper", helper / "SPJitHelper")
        (app / "Info.plist").write_bytes(render(CLIENT / "Info.plist", args.bundle_id, args.version))
        (helper / "Info.plist").write_bytes(render(CLIENT / "helper/Info.plist", args.bundle_id + ".helper", args.version))
        for dylib in sorted(RESOURCES.glob("*.dylib")):
            copy(dylib, app / "Frameworks" / dylib.name)
        if not list((app / "Frameworks").glob("*.dylib")):
            raise SystemExit("No shim dylibs found")
        for filename in ("exports.json", "rewrite-map.txt", "flavors.plist"):
            src = CLIENT / filename if filename == "flavors.plist" else RESOURCES / filename
            copy(src, app / filename)
        for filename in ("licenses", "Goodmountain-Regular.otf"):
            copy(RESOURCES / filename, app / filename)
        for entry in (RESOURCES / "icon").iterdir():
            copy(entry, app / entry.name)
        if not (app / "Assets.car").exists():
            raise SystemExit("Missing compiled icon Assets.car")
        for name in ("SPMovie", "SPHover"):
            for extension in ("toc", "lua"):
                file = name + "." + extension
                copy(ADDONS / name / file, app / "addons" / name / file)
        (app / "wow.icns").touch()
        pem = subprocess.check_output([
            "security", "find-certificate", "-a", "-p",
            "/System/Library/Keychains/SystemRootCertificates.keychain"
        ], text=True)
        import base64, re
        certs = [base64.b64decode("".join(block.split())) for block in
                 re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)]
        if not certs:
            raise RuntimeError("Unable to export system root certificates")
        (app / "sproots.plist").write_bytes(plistlib.dumps(certs, fmt=plistlib.FMT_BINARY))
        # No ad-hoc signing: third-party signing tools must sign ALL nested binaries
        # and provision both the app and the extension.
        output = ROOT / args.output
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for p in (Path(temporary) / "Payload").rglob("*"):
                if p.is_file():
                    archive.write(p, p.relative_to(temporary))
        assert zipfile.ZipFile(output).testzip() is None
        print(f"Created {output} ({output.stat().st_size:,} bytes)")
        print("Unsigned. Sign the app, frameworks and PlugIns/SPJitHelper.appex with valid entitlements/profiles.")


if __name__ == "__main__":
    main()
