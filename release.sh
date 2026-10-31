#!/bin/zsh
set -euo pipefail

dir="${0:A:h}"
version="$(<"$dir/VERSION")"
"$dir/build.sh" >/dev/null

stage="$(mktemp -d)"
dmg="$dir/dist/Stillwake-$version.dmg"
mkdir -p "$dir/dist"
rm -f "$dmg"

cp -R "$dir/build/Stillwake.app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Stillwake $version" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg" >/dev/null
rm -rf "$stage"

shasum -a 256 "$dmg"
