#!/usr/bin/env bash
# Packs a built DriveIn.app into an .ipa.
#
#   scripts/package_ipa.sh <DriveIn.app> <output.ipa> [entitlements.plist]
#
# Without entitlements the IPA is unsigned: Sideloadly / AltStore / SideStore sign it with
# your Apple ID when installing. With entitlements the app is ad-hoc signed so the
# entitlements travel inside the binary, for re-signing tools that keep them (they still
# need a provisioning profile that grants them, i.e. a paid account with CarPlay approval).
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <App.app> <output.ipa> [entitlements.plist]" >&2
  exit 64
fi

APP="$1"
OUT="$2"
ENTITLEMENTS="${3:-}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP is not an .app bundle" >&2
  exit 66
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
APP_NAME="$(basename "$APP")"

if [[ -n "$ENTITLEMENTS" ]]; then
  # Nested code must be signed before the app that contains it.
  for extension in "$WORK/Payload/$APP_NAME/PlugIns/"*.appex; do
    [[ -e "$extension" ]] || continue
    codesign --force --sign - --timestamp=none --generate-entitlement-der "$extension"
  done
  codesign --force --sign - --timestamp=none --generate-entitlement-der \
    --entitlements "$ENTITLEMENTS" "$WORK/Payload/$APP_NAME"
  echo "Embedded entitlements:"
  codesign -d --entitlements - --xml "$WORK/Payload/$APP_NAME" 2>/dev/null | plutil -p - || true
fi

mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK" && zip -qry "$OUT_ABS" Payload)
echo "Created $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
