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

echo "==> Preparing rollback-safe swap with signal-aware trap handlers..."

cleanup() {
    local sig="${1:-0}"
    local exit_code=1
    if [ "${sig}" -eq 2 ]; then
        exit_code=130
    elif [ "${sig}" -eq 15 ]; then
        exit_code=143
    fi

    if [ -d "${APP_BUNDLE}.old" ]; then
        echo "ERROR: Bundle swap or verification failed (signal/status: ${sig}, exit code: ${exit_code})! Rolling back from backup..." >&2
        rm -rf "${APP_BUNDLE}"
        mv "${APP_BUNDLE}.old" "${APP_BUNDLE}"
        echo "==> Rollback complete: Restored previous ${APP_BUNDLE}" >&2
    fi
    rm -rf ".build_staging"
    exit "${exit_code}"
}

# Arm traps for ERR, INT, TERM before moving APP_BUNDLE to APP_BUNDLE.old
trap 'cleanup 0' ERR
trap 'cleanup 2' INT
trap 'cleanup 15' TERM

if [ -d "${APP_BUNDLE}" ]; then
    rm -rf "${APP_BUNDLE}.old"
    mv "${APP_BUNDLE}" "${APP_BUNDLE}.old"
fi

echo "==> Promoting staged bundle to ${APP_BUNDLE}..."
mv "${STAGING_DIR}" "${APP_BUNDLE}"

# Final signature check on promoted bundle
echo "==> Verifying promoted bundle signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"

# Disarm traps only after post-promotion verification successfully passes
trap - ERR INT TERM

# Cleanup backup only after post-promotion verification passes
rm -rf "${APP_BUNDLE}.old" ".build_staging"

echo "==> Build, packaging, and verification complete: ${APP_BUNDLE}"
