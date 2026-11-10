#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "Usage: GO_TOOL=/path/to/go WINRES_TOOL=/path/to/go-winres bash build.sh /absolute/output" >&2
  exit 2
fi
out="$1"
go_tool="${GO_TOOL:-$(command -v go)}"
winres_tool="${WINRES_TOOL:-$(command -v go-winres)}"
product_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' Info.plist)"
app="$out/$product_name.app"
release_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
# A fixed signing certificate keeps macOS permissions (Screen Recording, Accessibility…) across updates.
# Use SIGN_IDENTITY, or the self-signed "Final Fusion Signing" certificate when this Mac has one; otherwise ad-hoc.
sign_identity="${SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]] && /usr/bin/security find-identity -p codesigning 2>/dev/null | grep -q '"Final Fusion Signing"'; then
  sign_identity="Final Fusion Signing"
fi
sign_identity="${sign_identity:--}"
echo "Signing with: $sign_identity" >&2
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
mkdir -p -- "$app/Contents/"{MacOS,Helpers,Resources} "$out/ModuleCache" "$temp/StudioRemote.iconset" "$temp/link"
sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
export GOCACHE="${GOCACHE:-$out/GoCache}"
export GOTOOLCHAIN=local
/usr/bin/xcrun --sdk macosx swiftc -module-cache-path "$out/ModuleCache" Icon.swift -o "$temp/render-icon"
"$temp/render-icon" "$temp/icon.png"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$temp/icon.png" --out "$temp/StudioRemote.iconset/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z "$((size*2))" "$((size*2))" "$temp/icon.png" --out "$temp/StudioRemote.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$temp/StudioRemote.iconset" -o "$app/Contents/Resources/StudioRemote.icns"
/bin/cp "$temp/icon.png" "$out/StudioRemote-Icon.png"
# Copy only build inputs. Local relay config, logs, downloads and work files are not package inputs.
mkdir -p -- "$temp/link/ui"
COPYFILE_DISABLE=1 /bin/cp -- Link/*.go Link/go.mod Link/go.sum "$temp/link/"
COPYFILE_DISABLE=1 /bin/cp -- Link/ui/{icon.svg,index.html,patch.png,style.css,viewer.js} \
  Link/ui/{send,receive}-agent{,-en}.txt "$temp/link/ui/"
(
  cd -- "$temp/link"
  "$winres_tool" simply --arch amd64 --icon "$temp/icon.png" --manifest gui --product-name "$product_name" --file-description "$product_name 받기"
  GOOS=windows GOARCH=amd64 CGO_ENABLED=0 "$go_tool" build -trimpath -ldflags="-H=windowsgui -s -w -X main.releaseVersion=$release_version" -o "$app/Contents/Resources/StudioReceiver.exe" .
  for arch in arm64 amd64; do
    GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 "$go_tool" build -trimpath -ldflags="-s -w" -o "$temp/StudioLink-$arch" .
  done
)
/usr/bin/lipo -create "$temp/StudioLink-arm64" "$temp/StudioLink-amd64" -output "$app/Contents/Helpers/StudioLink"
/usr/bin/codesign --force --sign "$sign_identity" "$app/Contents/Helpers/StudioLink"
for arch in arm64 x86_64; do
  set --
  if [[ "$arch" == x86_64 ]]; then
    set -- -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-concurrency
  fi
  /usr/bin/xcrun --sdk macosx clang -fobjc-arc -isysroot "$sdk" \
    -target "$arch-apple-macosx11.0" -c VirtualDisplay.m -o "$temp/VirtualDisplay-$arch.o"
  /usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -O -sdk "$sdk" \
    -target "$arch-apple-macosx11.0" -module-cache-path "$out/ModuleCache" "$@" \
    -Xlinker -weak_framework -Xlinker ScreenCaptureKit \
    -module-name StudioRemote -import-objc-header ReceiverEvents.h Localization.swift Design.swift AgentSupport.swift Wire.swift InputBehavior.swift TrackpadGestures.swift ReceiverUpdate.swift Host.swift Viewer.swift PointerFeedback.swift ReceiverMode.swift RelayTunnel.swift Pairing.swift SelfTest.swift SessionTest.swift UIPreview.swift main.swift \
    "$temp/VirtualDisplay-$arch.o" -o "$temp/StudioRemote-$arch"
done
/usr/bin/lipo -create "$temp/StudioRemote-arm64" "$temp/StudioRemote-x86_64" -output "$app/Contents/MacOS/StudioRemote"
/bin/cp -- Info.plist "$app/Contents/Info.plist"
if [[ "$sign_identity" != "-" ]]; then
  /usr/libexec/PlistBuddy -c "Add :FinalFusionSigningIdentity string $sign_identity" "$app/Contents/Info.plist"
fi
/bin/cp -- Link/ui/{send,receive}-agent{,-en}.txt "$app/Contents/Resources/"
/bin/cp -- Assets/MyMusicGacha.png "$app/Contents/Resources/MyMusicGacha.png"
# App name and permission text follow the OS language (ko.lproj / en.lproj).
write_names() {
  mkdir -p -- "$app/Contents/Resources/$1.lproj"
  printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n"NSLocalNetworkUsageDescription" = "%s";\n' \
    "$2" "$2" "$3" > "$app/Contents/Resources/$1.lproj/InfoPlist.strings"
}
write_names ko "$product_name" "허용된 기기끼리 화면을 연결해요."
write_names en "Final Fusion" "Connects the screen between allowed devices."
mkdir -p -- "$app/Contents/Resources/Relay"
COPYFILE_DISABLE=1 /bin/cp -- Relay/{SETUP.md,worker.js,wrangler.toml} "$app/Contents/Resources/Relay/"
# Finder or a synced folder can attach metadata which codesign does not accept.
if /usr/bin/xattr -lr "$app" | grep -Eq 'com.apple.(FinderInfo|ResourceFork):'; then
  for attr in com.apple.FinderInfo com.apple.ResourceFork; do
    /usr/bin/xattr -rd "$attr" "$app" 2>/dev/null || true
  done
fi
/usr/bin/codesign --force --sign "$sign_identity" "$app"
/usr/bin/codesign --verify --strict --deep "$app"
echo "$app"
