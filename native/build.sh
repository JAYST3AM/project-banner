#!/usr/bin/env bash
# One command builds the native accelerator. It fetches the pinned godot-cpp into
# native/deps/ (git-ignored) if it is not there yet, checks out the exact revision this
# project is pinned to, and builds the release library straight into the folder the
# .gdextension file loads from.
#
#   bash native/build.sh              # release build for this host
#   TARGET=template_debug bash native/build.sh
#
# Windows: run it from Git Bash, or use native/build.cmd from a normal command prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPS="$ROOT/deps"
REV="$(cat "$ROOT/GODOT_CPP_REVISION" | tr -d '\r\n')"
SCONS="${SCONS:-scons}"
TARGET="${TARGET:-template_release}"

case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
	Linux*) PLATFORM=linux ;;
	Darwin*) PLATFORM=macos ;;
	*) PLATFORM=windows ;;
esac

if [ ! -d "$DEPS/godot-cpp/.git" ]; then
	echo "native: fetching godot-cpp into $DEPS (ignored by git)"
	mkdir -p "$DEPS"
	# `cd` first and name the target relatively: git is a native Windows program here and
	# cannot resolve the MSYS-style paths this script works in, so passing one to `-C` or as
	# a clone target fails with "cannot change to ..." - which is how this was found.
	(cd "$DEPS" && git clone --quiet https://github.com/godotengine/godot-cpp.git godot-cpp)
fi

echo "native: checking out godot-cpp $REV"
(
	cd "$DEPS/godot-cpp"
	git fetch --quiet --all 2>/dev/null || true
	git checkout --quiet "$REV"
)

echo "native: building $TARGET for $PLATFORM (api_version=4.7)"
# Same reason as the git calls above: scons is a native program and `-C` with an MSYS path
# does not resolve, so the directory is entered with the shell instead.
(cd "$ROOT" && "$SCONS" platform="$PLATFORM" target="$TARGET" arch=x86_64 api_version=4.7 "$@")

echo "native: done - addons/pb_native/bin/"
