#!/bin/bash
set -euo pipefail

APP_NAME="PortSentry"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building ${APP_NAME}..."

# Create .app bundle structure
mkdir -p "${SCRIPT_DIR}/${APP_NAME}.app/Contents/MacOS"
mkdir -p "${SCRIPT_DIR}/${APP_NAME}.app/Contents/Resources"

# Compile
swiftc -parse-as-library -O -o "${SCRIPT_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" "${SCRIPT_DIR}/${APP_NAME}.swift"

# Copy Info.plist
cp "${SCRIPT_DIR}/Info.plist" "${SCRIPT_DIR}/${APP_NAME}.app/Contents/Info.plist"

echo "Build complete: ${SCRIPT_DIR}/${APP_NAME}.app"
echo ""
echo "To run:"
echo "  open ${SCRIPT_DIR}/${APP_NAME}.app"
