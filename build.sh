#!/bin/bash
set -euo pipefail

APP_NAME="LingoBar"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME} binary with swiftc..."
swiftc -parse-as-library main.swift KeychainHelper.swift SettingsView.swift -o "${APP_NAME}"

echo "==> Preparing bundle directory structure..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "==> Installing binary into app bundle..."
cp -f "${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Verify binary installation
if [ ! -f "${MACOS_DIR}/${APP_NAME}" ]; then
    echo "ERROR: Target executable '${MACOS_DIR}/${APP_NAME}' is missing!" >&2
    exit 1
fi

# Ensure Info.plist exists and is installed
if [ -f "Info.plist" ]; then
    echo "==> Installing Info.plist..."
    cp -f Info.plist "${CONTENTS_DIR}/Info.plist"
elif [ -f "${CONTENTS_DIR}/Info.plist" ]; then
    echo "==> Retaining existing ${CONTENTS_DIR}/Info.plist"
else
    echo "ERROR: Required metadata file 'Info.plist' is missing!" >&2
    exit 1
fi

if [ ! -f "${CONTENTS_DIR}/Info.plist" ]; then
    echo "ERROR: Target '${CONTENTS_DIR}/Info.plist' not found in bundle!" >&2
    exit 1
fi

# Ensure AppIcon.icns exists and is installed
if [ -f "Resources/AppIcon.icns" ]; then
    echo "==> Installing AppIcon.icns..."
    cp -f Resources/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
elif [ -f "${RESOURCES_DIR}/AppIcon.icns" ]; then
    echo "==> Retaining existing ${RESOURCES_DIR}/AppIcon.icns"
else
    echo "ERROR: Required icon file 'Resources/AppIcon.icns' is missing!" >&2
    exit 1
fi

if [ ! -f "${RESOURCES_DIR}/AppIcon.icns" ]; then
    echo "ERROR: Target '${RESOURCES_DIR}/AppIcon.icns' not found in bundle!" >&2
    exit 1
fi

echo "==> Signing ${APP_BUNDLE} with designated requirement..."
codesign --force --deep -s - -i "com.lingobar.macos" --requirements '=designated => identifier "com.lingobar.macos"' "${APP_BUNDLE}"

echo "==> Build and packaging complete: ${APP_BUNDLE}"
