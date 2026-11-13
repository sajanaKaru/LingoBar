#!/bin/bash
set -euo pipefail

APP_NAME="LingoBar"
APP_BUNDLE="${APP_NAME}.app"
STAGING_DIR=".build_staging/${APP_BUNDLE}"
STAGING_CONTENTS="${STAGING_DIR}/Contents"
STAGING_MACOS="${STAGING_CONTENTS}/MacOS"
STAGING_RESOURCES="${STAGING_CONTENTS}/Resources"

REQUIRED_SOURCES=(
    "main.swift"
    "KeychainHelper.swift"
    "SettingsView.swift"
    "Info.plist"
    "Resources/AppIcon.icns"
)

echo "==> [Preflight] Verifying all required source files and assets..."
for src in "${REQUIRED_SOURCES[@]}"; do
    if [ ! -f "${src}" ]; then
        echo "ERROR: Preflight check failed: Required source or asset '${src}' is missing!" >&2
        exit 1
    fi
done
echo "==> [Preflight] All required sources verified."

echo "==> Building ${APP_NAME} binary with swiftc..."
swiftc -parse-as-library main.swift KeychainHelper.swift SettingsView.swift -o "${APP_NAME}"

echo "==> Assembling bundle in staging directory..."
rm -rf ".build_staging"
mkdir -p "${STAGING_MACOS}" "${STAGING_RESOURCES}"

cp -f "${APP_NAME}" "${STAGING_MACOS}/${APP_NAME}"
cp -f "Info.plist" "${STAGING_CONTENTS}/Info.plist"
cp -f "Resources/AppIcon.icns" "${STAGING_RESOURCES}/AppIcon.icns"

# Verify staging bundle integrity
if [ ! -f "${STAGING_MACOS}/${APP_NAME}" ] || [ ! -f "${STAGING_CONTENTS}/Info.plist" ] || [ ! -f "${STAGING_RESOURCES}/AppIcon.icns" ]; then
    echo "ERROR: Staging bundle verification failed!" >&2
    exit 1
fi

echo "==> Signing staged bundle with designated requirement..."
codesign --force --deep -s - -i "com.lingobar.macos" --requirements '=designated => identifier "com.lingobar.macos"' "${STAGING_DIR}"

echo "==> Verifying signature on staged bundle before promotion..."
codesign --verify --deep --strict "${STAGING_DIR}"

echo "==> Performing rollback-safe atomic bundle swap..."
HAS_OLD=0
if [ -d "${APP_BUNDLE}" ]; then
    rm -rf "${APP_BUNDLE}.old"
    mv "${APP_BUNDLE}" "${APP_BUNDLE}.old"
    HAS_OLD=1
fi

if mv "${STAGING_DIR}" "${APP_BUNDLE}"; then
    echo "==> Promotion succeeded. Cleaning up backup and staging..."
    if [ "${HAS_OLD}" -eq 1 ]; then
        rm -rf "${APP_BUNDLE}.old"
    fi
    rm -rf ".build_staging"
else
    echo "ERROR: Bundle promotion failed! Restoring backup..." >&2
    if [ "${HAS_OLD}" -eq 1 ] && [ -d "${APP_BUNDLE}.old" ]; then
        mv "${APP_BUNDLE}.old" "${APP_BUNDLE}"
    fi
    exit 1
fi

# Final signature check on promoted bundle
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> Build, packaging, and verification complete: ${APP_BUNDLE}"
