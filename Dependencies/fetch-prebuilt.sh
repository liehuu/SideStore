#!/usr/bin/env bash

# Ensure we are in Dependencies directory
cd "$(dirname "$0")"

# Detect if Homebrew is in /opt/homebrew (Apple Silicon) or /usr/local (Intel)
if [[ -d "/opt/homebrew" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
elif [[ -d "/usr/local" ]]; then
    export PATH="/usr/local/bin:$PATH"
fi

# Check if curl is installed; if not, install it via Homebrew
# (wget is no longer used: downloads go through curl -fL, which fails
# cleanly on HTTP errors instead of saving the error page as a .a file)
if ! command -v curl &> /dev/null; then
    echo "curl not found, attempting to install via Homebrew..."
    if command -v brew &> /dev/null; then
        brew install curl
    else
        echo "Homebrew is not installed. Please install Homebrew and rerun the script."
        exit 1
    fi
fi

# Download a URL to a local path with curl (-f: HTTP errors fail instead of
# saving the error page; -L: follow GitHub release redirects; --retry for flaky
# networks), then sanity-check the result so a bad download fails THIS step
# loudly instead of breaking libtool later with a cryptic error.
fetch_prebuilt() {
    local DST="$1"
    local URL="$2"
    local MIN_BYTES="${3:-1000}"
    rm -f "$DST"
    if ! curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "$DST" "$URL"; then
        echo "ERROR: failed to download $URL -> $DST"
        rm -f "$DST"
        exit 1
    fi
    local SIZE=$(wc -c < "$DST" | tr -d ' ')
    if [ "$SIZE" -lt "$MIN_BYTES" ]; then
        echo "ERROR: $DST is only $SIZE bytes (expected >= $MIN_BYTES) - download corrupt?"
        rm -f "$DST"
        exit 1
    fi
    echo "OK: $DST ($SIZE bytes)"
}

check_for_update() {
    # em_proxy's "latest" release was repackaged as an .xcframework.zip and no longer
    # ships the per-arch static libs (libem_proxy-ios.a / .h / .swift) that this 0.6.3
    # Xcode project expects. Pin em_proxy to the rolling "build" tag, which still ships
    # the legacy .a + header layout. minimuxer keeps using "latest" (its latest is the
    # "build" tag and still has the .a files).
    local REF="latest"
    if [ "$1" = "em_proxy" ]; then REF="build"; fi

    # URL forms differ between "latest" and a concrete tag:
    #   latest endpoint:  releases/latest/download/<file>          (NOT releases/download/latest/...)
    #   tag endpoint:     releases/download/<tag>/<file>
    # The API check mirrors this: releases/latest vs releases/tags/<tag>.
    local DL_BASE="https://github.com/SideStore/$1/releases/latest/download"
    local API_URL="https://api.github.com/repos/SideStore/$1/releases/latest"
    if [ "$REF" != "latest" ]; then
        DL_BASE="https://github.com/SideStore/$1/releases/download/$REF"
        API_URL="https://api.github.com/repos/SideStore/$1/releases/tags/$REF"
    fi

    if [ -f ".skip-prebuilt-fetch-$1" ]; then
        echo "Skipping prebuilt fetch for $1 since .skip-prebuilt-fetch-$1 exists. If you are developing $1 alongside SideStore, don't remove this file, or this script will replace your locally built binaries with the ones built by GitHub Actions."
        return
    fi

    if [ ! -f ".last-prebuilt-fetch-$1" ]; then
        echo "0,none" > ".last-prebuilt-fetch-$1"
    fi

    LAST_FETCH=`cat .last-prebuilt-fetch-$1 | perl -n -e '/([0-9]*),([^ ]*)$/ && print $1'`
    LAST_COMMIT=`cat .last-prebuilt-fetch-$1 | perl -n -e '/([0-9]*),([^ ]*)$/ && print $2'`

    # Check if required library files exist
    FORCE_DOWNLOAD=false
    if [ ! -f "$1/lib$1-sim.a" ] || [ ! -f "$1/lib$1-ios.a" ]; then
        echo "Required libraries missing for $1, forcing download..."
        FORCE_DOWNLOAD=true
    fi

    # Download if:
    # 1. Libraries are missing (FORCE_DOWNLOAD), or
    # 2. Last fetch was over 1 hour ago, or
    # 3. Force flag was passed
    if [ "$FORCE_DOWNLOAD" = true ] || [[ $LAST_FETCH -lt $(expr $(date +%s) - 3600) ]] || [[ "$2" == "force" ]]; then
        echo "Checking $1 for update"
        echo
        LATEST_COMMIT=`curl -L "$API_URL" | perl -n -e '/Commit: https:\\/\\/github\\.com\\/[^\\/]*\\/[^\\/]*\\/commit\\/([^"]*)/ && print $1'`
        echo
        echo "Last commit: $LAST_COMMIT"
        echo "Latest commit: $LATEST_COMMIT"

        NOT_UPTODATE=false
        if [[ "$LAST_COMMIT" != "$LATEST_COMMIT" ]]; then
            echo "Found update on the remote: https://api.github.com/repos/SideStore/$1/releases/latest"
            NOT_UPTODATE=true
        fi

        # Download if:
        # 1. Libraries are missing (FORCE_DOWNLOAD), or
        # 2. New commit is available
        if [ "$FORCE_DOWNLOAD" = true ] || [ "$NOT_UPTODATE" = true ] ;then
            echo "downloading binaries"
            echo
            if [[ "$1" != "minimuxer" ]]; then
                fetch_prebuilt "$1/lib$1-sim.a"  "$DL_BASE/lib$1-sim.a" 100000
                fetch_prebuilt "$1/lib$1-ios.a"  "$DL_BASE/lib$1-ios.a" 100000
                fetch_prebuilt "$1/$1.h"         "$DL_BASE/$1.h" 100
                fetch_prebuilt "$1/$1.swift"     "$DL_BASE/$1.swift" 100
                echo
            else
                fetch_prebuilt "$1/lib$1-sim.a"  "$DL_BASE/lib$1-sim.a" 100000
                fetch_prebuilt "$1/lib$1-ios.a"  "$DL_BASE/lib$1-ios.a" 100000
                fetch_prebuilt "$1/generated.zip" "$DL_BASE/generated.zip" 1000
                echo
                echo "Unzipping generated.zip"
                cd "$1"
                unzip ./generated.zip
                cp -v generated/* .
                # Remove all files except ones that comes checked-in from minimuxer repository
                find generated -type f ! -name 'minimuxer-Bridging-Header.h' ! -name 'minimuxer-helpers.swift' -exec rm -v {} \;
                rm generated.zip
                rmdir generated/
                cd ..
                echo "Done"
            fi
        else
            echo "Up-to-date"
        fi
        echo "$(date +%s),$LATEST_COMMIT" > ".last-prebuilt-fetch-$1"
    else
        echo "It hasn't been 1 hour and force was not specified, skipping update check for $1"
    fi
}

# Allow for Xcode to check minimuxer and em_proxy separately by skipping the update check if the other one is specified as an argument
if [[ "$1" != "em_proxy" ]]; then
    check_for_update minimuxer "$1"
    if [[ "$1" != "minimuxer" ]]; then
        echo
    fi
fi
if [[ "$1" != "minimuxer" ]]; then
    check_for_update em_proxy "$1"
fi
