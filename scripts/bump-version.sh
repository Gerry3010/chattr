#!/bin/bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later


# Bump version script for Chattr. Raises the version for one or all components.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$PROJECT_ROOT/version.json"
PUBSPEC_FILE="$PROJECT_ROOT/pubspec.yaml"
LANDING_FILE="$PROJECT_ROOT/landing/index.html"
CHANGELOG_FILE="$PROJECT_ROOT/CHANGELOG.md"

# Colours for the output.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Hilfefunktion
usage() {
    echo "Usage: $0 --component <app|backend|landing|all> --type <major|minor|patch> [--no-commit]"
    echo ""
    echo "Options:"
    echo "  --component   Welche Komponente soll erhöht werden (app, backend, landing, all)"
    echo "  --type        Art der Versionierung (major, minor, patch)"
    echo "  --no-commit   Erstelle keinen Git-Commit"
    echo ""
    echo "Examples:"
    echo "  $0 --component app --type patch"
    echo "  $0 --component all --type minor"
    exit 1
}

# Raise the version number.
bump_version() {
    local version=$1
    local type=$2
    
    IFS='.' read -ra PARTS <<< "$version"
    local major=${PARTS[0]}
    local minor=${PARTS[1]}
    local patch=${PARTS[2]}
    
    case $type in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            echo -e "${RED}Invalid type: $type${NC}"
            exit 1
            ;;
    esac
    
    echo "$major.$minor.$patch"
}

# Parse Argumente
COMPONENT=""
TYPE=""
NO_COMMIT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --component)
            COMPONENT="$2"
            shift 2
            ;;
        --type)
            TYPE="$2"
            shift 2
            ;;
        --no-commit)
            NO_COMMIT=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validiere Argumente
if [ -z "$COMPONENT" ] || [ -z "$TYPE" ]; then
    echo -e "${RED}Fehler: --component und --type sind erforderlich${NC}"
    usage
fi

if [[ ! "$COMPONENT" =~ ^(app|backend|landing|all)$ ]]; then
    echo -e "${RED}Fehler: Component muss app, backend, landing oder all sein${NC}"
    usage
fi

if [[ ! "$TYPE" =~ ^(major|minor|patch)$ ]]; then
    echo -e "${RED}Fehler: Type muss major, minor oder patch sein${NC}"
    usage
fi

# Lese aktuelle Versionen
echo -e "${GREEN}Lese aktuelle Versionen...${NC}"
APP_VERSION=$(jq -r '.app_version' "$VERSION_FILE")
BACKEND_VERSION=$(jq -r '.backend_version' "$VERSION_FILE")
LANDING_VERSION=$(jq -r '.landing_version' "$VERSION_FILE")
BUILD_NUMBER=$(jq -r '.build_number' "$VERSION_FILE")

echo "Aktuelle Versionen:"
echo "  App: $APP_VERSION (Build: $BUILD_NUMBER)"
echo "  Backend: $BACKEND_VERSION"
echo "  Landing: $LANDING_VERSION"
echo ""

# Raise versions based on the component.
NEW_APP_VERSION=$APP_VERSION
NEW_BACKEND_VERSION=$BACKEND_VERSION
NEW_LANDING_VERSION=$LANDING_VERSION
NEW_BUILD_NUMBER=$BUILD_NUMBER

case $COMPONENT in
    app)
        NEW_APP_VERSION=$(bump_version "$APP_VERSION" "$TYPE")
        NEW_BUILD_NUMBER=$((BUILD_NUMBER + 1))
        echo -e "${YELLOW}Bump App: $APP_VERSION → $NEW_APP_VERSION (Build: $BUILD_NUMBER → $NEW_BUILD_NUMBER)${NC}"
        ;;
    backend)
        NEW_BACKEND_VERSION=$(bump_version "$BACKEND_VERSION" "$TYPE")
        echo -e "${YELLOW}Bump Backend: $BACKEND_VERSION → $NEW_BACKEND_VERSION${NC}"
        ;;
    landing)
        NEW_LANDING_VERSION=$(bump_version "$LANDING_VERSION" "$TYPE")
        echo -e "${YELLOW}Bump Landing: $LANDING_VERSION → $NEW_LANDING_VERSION${NC}"
        ;;
    all)
        NEW_APP_VERSION=$(bump_version "$APP_VERSION" "$TYPE")
        NEW_BACKEND_VERSION=$(bump_version "$BACKEND_VERSION" "$TYPE")
        NEW_LANDING_VERSION=$(bump_version "$LANDING_VERSION" "$TYPE")
        NEW_BUILD_NUMBER=$((BUILD_NUMBER + 1))
        echo -e "${YELLOW}Bump All:${NC}"
        echo "  App: $APP_VERSION → $NEW_APP_VERSION (Build: $BUILD_NUMBER → $NEW_BUILD_NUMBER)"
        echo "  Backend: $BACKEND_VERSION → $NEW_BACKEND_VERSION"
        echo "  Landing: $LANDING_VERSION → $NEW_LANDING_VERSION"
        ;;
esac

# Update version.json
echo -e "${GREEN}Update version.json...${NC}"
jq ".app_version = \"$NEW_APP_VERSION\" | .backend_version = \"$NEW_BACKEND_VERSION\" | .landing_version = \"$NEW_LANDING_VERSION\" | .build_number = $NEW_BUILD_NUMBER" "$VERSION_FILE" > "$VERSION_FILE.tmp"
mv "$VERSION_FILE.tmp" "$VERSION_FILE"

# Portable in-place sed: GNU and BSD (macOS) differ on `-i`, and BSD BRE has no
# `\+`. `sed -E -i.bak … && rm` works on both (and preserves file perms); `-E`
# gives a portable `+` quantifier. Without this, a bump run on macOS silently
# no-ops every edit below while version.json still updates — which is exactly how
# v1.5.0 shipped a stale "Client v1.4.0" landing footer.
sed_portable() { # $1 = sed expr (ERE), $2 = file
    sed -E -i.bak "$1" "$2" && rm -f "$2.bak"
}

# Update pubspec.yaml when the app version changed.
if [ "$NEW_APP_VERSION" != "$APP_VERSION" ]; then
    echo -e "${GREEN}Update pubspec.yaml...${NC}"
    sed_portable "s/^version: .*/version: $NEW_APP_VERSION+$NEW_BUILD_NUMBER/" "$PUBSPEC_FILE"
fi

# Update landing/index.html + landing/technik.html (gleicher Footer)
TECHNIK_FILE="$PROJECT_ROOT/landing/technik.html"
if [ "$NEW_LANDING_VERSION" != "$LANDING_VERSION" ] || [ "$NEW_APP_VERSION" != "$APP_VERSION" ] || [ "$NEW_BACKEND_VERSION" != "$BACKEND_VERSION" ]; then
    echo -e "${GREEN}Update landing/index.html + technik.html...${NC}"
    for f in "$LANDING_FILE" "$TECHNIK_FILE"; do
        [ -f "$f" ] || continue
        sed_portable "s|v[0-9]+\.[0-9]+\.[0-9]+</p>|v$NEW_LANDING_VERSION</p>|" "$f"
        sed_portable "s|Client v[0-9]+\.[0-9]+\.[0-9]+|Client v$NEW_APP_VERSION|" "$f"
        sed_portable "s|Backend v[0-9]+\.[0-9]+\.[0-9]+|Backend v$NEW_BACKEND_VERSION|" "$f"
    done
fi

echo -e "${GREEN}✓ Versionen erfolgreich erhöht!${NC}"
echo ""

# Git Commit
if [ "$NO_COMMIT" = false ]; then
    echo -e "${GREEN}Erstelle Git Commit...${NC}"
    git add "$VERSION_FILE" "$PUBSPEC_FILE" "$LANDING_FILE"
    [ -f "$TECHNIK_FILE" ] && git add "$TECHNIK_FILE"
    
    COMMIT_MSG="chore: bump version to "
    if [ "$COMPONENT" = "all" ]; then
        COMMIT_MSG+="$NEW_APP_VERSION"
    else
        case $COMPONENT in
            app) COMMIT_MSG+="app v$NEW_APP_VERSION" ;;
            backend) COMMIT_MSG+="backend v$NEW_BACKEND_VERSION" ;;
            landing) COMMIT_MSG+="landing v$NEW_LANDING_VERSION" ;;
        esac
    fi
    
    git commit -m "$COMMIT_MSG"
    echo -e "${GREEN}✓ Commit erstellt: $COMMIT_MSG${NC}"
else
    echo -e "${YELLOW}Überspringe Git Commit (--no-commit gesetzt)${NC}"
fi

echo ""
echo -e "${GREEN}Fertig! Neue Versionen:${NC}"
echo "  App: $NEW_APP_VERSION (Build: $NEW_BUILD_NUMBER)"
echo "  Backend: $NEW_BACKEND_VERSION"
echo "  Landing: $NEW_LANDING_VERSION"
