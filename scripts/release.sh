#!/bin/bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later


# Release script for Chattr. Creates a new release with a git tag and a
# CHANGELOG update.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$PROJECT_ROOT/version.json"
CHANGELOG_FILE="$PROJECT_ROOT/CHANGELOG.md"

# Colours for the output.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Hilfefunktion
usage() {
    echo "Usage: $0 --component <app|backend|landing|all> [--type <major|minor|patch>] [--message <msg>] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --component   Welche Komponente soll released werden (app, backend, landing, all)"
    echo "  --type        Art der Versionierung (major, minor, patch) - optional, wenn Version bereits gebumpt"
    echo "  --message     Release-Nachricht für CHANGELOG - optional"
    echo "  --dry-run     Zeige nur was gemacht würde, ohne Änderungen"
    echo ""
    echo "Examples:"
    echo "  $0 --component app --type patch --message 'Bug fixes'"
    echo "  $0 --component all --type minor"
    echo "  $0 --component app  # Verwendet aktuelle Version ohne Bump"
    exit 1
}

# Parse Argumente
COMPONENT=""
TYPE=""
MESSAGE=""
DRY_RUN=false

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
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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
if [ -z "$COMPONENT" ]; then
    echo -e "${RED}Fehler: --component ist erforderlich${NC}"
    usage
fi

if [[ ! "$COMPONENT" =~ ^(app|backend|landing|all)$ ]]; then
    echo -e "${RED}Fehler: Component muss app, backend, landing oder all sein${NC}"
    usage
fi

# Bump Version wenn --type gegeben
if [ -n "$TYPE" ]; then
    echo -e "${BLUE}=== Version Bump ===${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN: Würde Version bumpen mit: --component $COMPONENT --type $TYPE${NC}"
    else
        "$SCRIPT_DIR/bump-version.sh" --component "$COMPONENT" --type "$TYPE"
    fi
    echo ""
fi

# Lese aktuelle Versionen
APP_VERSION=$(jq -r '.app_version' "$VERSION_FILE")
BACKEND_VERSION=$(jq -r '.backend_version' "$VERSION_FILE")
LANDING_VERSION=$(jq -r '.landing_version' "$VERSION_FILE")

echo -e "${BLUE}=== Release Info ===${NC}"
echo "Komponente: $COMPONENT"
echo "Versionen:"
echo "  App: $APP_VERSION"
echo "  Backend: $BACKEND_VERSION"
echo "  Landing: $LANDING_VERSION"
echo ""

# Determine the release version and tag based on the component.
case $COMPONENT in
    app)
        RELEASE_VERSION=$APP_VERSION
        TAG_NAME="v$RELEASE_VERSION"
        ;;
    backend)
        RELEASE_VERSION=$BACKEND_VERSION
        TAG_NAME="backend-v$RELEASE_VERSION"
        ;;
    landing)
        RELEASE_VERSION=$LANDING_VERSION
        TAG_NAME="landing-v$RELEASE_VERSION"
        ;;
    all)
        RELEASE_VERSION=$APP_VERSION
        TAG_NAME="v$RELEASE_VERSION"
        ;;
esac

echo -e "${BLUE}=== Git Tag ===${NC}"
echo "Tag Name: $TAG_NAME"
echo "Release Version: $RELEASE_VERSION"
echo ""

# Check whether the tag already exists.
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    echo -e "${RED}Fehler: Tag $TAG_NAME existiert bereits!${NC}"
    echo "Bitte bumpe die Version zuerst oder lösche den existierenden Tag."
    exit 1
fi

# Update CHANGELOG
echo -e "${BLUE}=== CHANGELOG Update ===${NC}"
CURRENT_DATE=$(date +%Y-%m-%d)

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN: Würde CHANGELOG.md updaten:${NC}"
    echo "  - [Unreleased] → [$RELEASE_VERSION] - $CURRENT_DATE"
    if [ -n "$MESSAGE" ]; then
        echo "  - Release Message: $MESSAGE"
    fi
else
    # Erstelle Backup
    cp "$CHANGELOG_FILE" "$CHANGELOG_FILE.bak"
    
    # Update Unreleased zu aktueller Version
    sed -i "s/## \[Unreleased\]/## [$RELEASE_VERSION] - $CURRENT_DATE/" "$CHANGELOG_FILE"
    
    # Add a new Unreleased section.
    sed -i "/## \[$RELEASE_VERSION\]/i ## [Unreleased]\n" "$CHANGELOG_FILE"
    
    # Add the release message if there is one.
    if [ -n "$MESSAGE" ]; then
        sed -i "/## \[$RELEASE_VERSION\]/a \\\n### Release Notes\n$MESSAGE\n" "$CHANGELOG_FILE"
    fi
    
    echo -e "${GREEN}✓ CHANGELOG.md updated${NC}"
fi

echo ""

# Git Operations
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}=== DRY RUN: Git Operations ===${NC}"
    echo -e "${YELLOW}Würde folgende Befehle ausführen:${NC}"
    echo "  git add $CHANGELOG_FILE"
    echo "  git commit -m 'chore: release $TAG_NAME'"
    echo "  git tag -a $TAG_NAME -m 'Release $RELEASE_VERSION'"
    echo ""
    echo -e "${YELLOW}Zum Pushen würde ausgeführt:${NC}"
    echo "  git push origin main"
    echo "  git push origin $TAG_NAME"
else
    echo -e "${BLUE}=== Git Commit & Tag ===${NC}"
    
    # Commit CHANGELOG
    git add "$CHANGELOG_FILE"
    git commit -m "chore: release $TAG_NAME"
    echo -e "${GREEN}✓ CHANGELOG committed${NC}"
    
    # Erstelle Git Tag
    TAG_MESSAGE="Release $RELEASE_VERSION"
    if [ -n "$MESSAGE" ]; then
        TAG_MESSAGE="$TAG_MESSAGE - $MESSAGE"
    fi
    
    git tag -a "$TAG_NAME" -m "$TAG_MESSAGE"
    echo -e "${GREEN}✓ Git Tag $TAG_NAME erstellt${NC}"
    
    echo ""
    echo -e "${GREEN}=== Release erfolgreich erstellt! ===${NC}"
    echo ""
    echo -e "${YELLOW}Nächste Schritte:${NC}"
    echo "1. Prüfe die Änderungen: git log --oneline -5"
    echo "2. Pushe zum Remote: git push origin main && git push origin $TAG_NAME"
    echo "3. Erstelle ggf. ein Release auf Bitbucket"
    
    # Cleanup
    rm -f "$CHANGELOG_FILE.bak"
fi

echo ""
echo -e "${BLUE}Release Summary:${NC}"
echo "  Component: $COMPONENT"
echo "  Version: $RELEASE_VERSION"
echo "  Tag: $TAG_NAME"
if [ -n "$MESSAGE" ]; then
    echo "  Message: $MESSAGE"
fi
