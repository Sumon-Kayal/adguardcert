#!/bin/bash
set -e

# Read version fields directly so they are available before the subshell.
# BUG FIX: the original script used `case version in` (literal string) instead
# of `case "$version" in`, so pre-release tags were never skipped.
version=$(sed -ne 's/^version=//p' ./module/module.prop)
versionCode=$(sed -ne 's/^versionCode=//p' ./module/module.prop)

case "$version" in
*-*)
    # Pre-release tag (e.g. v2.2-beta): skip update.json update.
    ;;
*)
    git checkout -B master origin/master
    cat > update.json << EOF
{
  "version": "$version",
  "versionCode": $versionCode,
  "zipUrl": "https://github.com/AdguardTeam/adguardcert/releases/download/$version/adguardcert-$version.zip",
  "changelog": "https://github.com/AdguardTeam/adguardcert/releases/tag/$version"
}
EOF
    git add update.json
    git commit -m "skipci: Update update.json" || true
    ;;
esac
