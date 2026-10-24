#!/bin/bash

# Builds TDLib (tdlib/build.sh) and the media libraries (medialibs/build.sh), then collects the
# headers and static libraries the app and CLI link into libs/. Once libs/ is complete, the build
# folders (packages/, workspace/, the td source) are no longer needed; remove them with -c.

PROGNAME=$(basename "$0")

CWD=$(cd "$(dirname "$0")" && pwd)
LIBS="$CWD/libs"
TDLIB_SOURCE="$CWD/tdlib/td"
TDLIB_INSTALL="$TDLIB_SOURCE/tdlib"
TDLIB_WORKSPACE="$CWD/tdlib/workspace"
MEDIALIBS_WORKSPACE="$CWD/medialibs/workspace"

# Everything the app target and the Swift package link against.
REQUIRED_LIBS=(
  libtdjson_static.a libtdjson_private.a libtdclient.a libtdcore.a libtdapi.a libtdmtproto.a
  libtdnet.a libtddb.a libtdsqlite.a libtdactor.a libtde2e.a libtdutils.a
  libssl.a libcrypto.a
  librlottie.a libvpx.a
)
REQUIRED_HEADERS=(
  td/telegram/td_json_client.h
  rlottie_capi.h
  vpx/vpx_decoder.h
)

usage() {
  echo "Usage: $PROGNAME [OPTIONS]"
  echo "Options:"
  echo "  -h, --help                     Display usage information"
  echo "  -b, --build                    Build tdlib and media libs and collect them into libs/"
  echo "      --force                    With --build: rebuild even if libs/ is already complete"
  echo "      --collect                  Only copy already-built libraries into libs/"
  echo "  -c, --cleanup                  Remove the build folders once libs/ is complete: tdlib/packages,"
  echo "                                 tdlib/workspace, tdlib/td (source and build), medialibs/packages,"
  echo "                                 medialibs/workspace. Can be combined with -b."
  echo ""
}

libs_complete() {
  for lib in "${REQUIRED_LIBS[@]}"; do
    [ -f "$LIBS/lib/$lib" ] || return 1
  done
  for header in "${REQUIRED_HEADERS[@]}"; do
    [ -f "$LIBS/include/$header" ] || return 1
  done
  return 0
}

# Copies headers and static libraries into a fresh libs/ (replaced only when everything is present).
collect() {
  echo ""
  echo "collecting libraries into $LIBS"
  echo "======================="
  local staging="$CWD/libs.tmp"
  rm -rf "$staging"
  mkdir -p "$staging/include" "$staging/lib"

  # TDLib: headers and every static library (not the dylib, which only the CLI uses).
  cp -R "$TDLIB_INSTALL/include/" "$staging/include/" || return 1
  cp "$TDLIB_INSTALL"/lib/*.a "$staging/lib/" || return 1
  # OpenSSL: TDLib's crypto backend; no headers needed.
  cp "$TDLIB_WORKSPACE/lib/libssl.a" "$TDLIB_WORKSPACE/lib/libcrypto.a" "$staging/lib/" || return 1
  # rlottie and libvpx.
  cp "$MEDIALIBS_WORKSPACE"/include/rlottie*.h "$staging/include/" || return 1
  cp -R "$MEDIALIBS_WORKSPACE/include/vpx" "$staging/include/" || return 1
  cp "$MEDIALIBS_WORKSPACE/lib/librlottie.a" "$MEDIALIBS_WORKSPACE/lib/libvpx.a" "$staging/lib/" || return 1

  for lib in "${REQUIRED_LIBS[@]}"; do
    [ -f "$staging/lib/$lib" ] || { echo "Missing $lib"; rm -rf "$staging"; return 1; }
  done
  for header in "${REQUIRED_HEADERS[@]}"; do
    [ -f "$staging/include/$header" ] || { echo "Missing $header"; rm -rf "$staging"; return 1; }
  done

  {
    echo "tdlib $(sed -n 's/^project(TDLib VERSION \([0-9.]*\).*/\1/p' "$TDLIB_SOURCE/CMakeLists.txt")"
    for package in openssl rlottie libvpx; do
      for done_file in "$CWD/tdlib/packages/$package.done" "$CWD/medialibs/packages/$package.done"; do
        [ -f "$done_file" ] && echo "$package $(cat "$done_file")"
      done
    done
    echo "collected $(date '+%Y-%m-%d %H:%M')"
  } >"$staging/VERSIONS"

  rm -rf "$LIBS"
  mv "$staging" "$LIBS"
  echo "Collected $(ls "$LIBS/lib" | wc -l | tr -d ' ') libraries into $LIBS"
  return 0
}

cleanup() {
  echo ""
  echo "removing build folders"
  echo "======================="
  for dir in "$CWD/tdlib/packages" "$CWD/tdlib/workspace" "$TDLIB_SOURCE" "$CWD/medialibs/packages" "$CWD/medialibs/workspace"; do
    if [ -d "$dir" ]; then
      rm -rf "$dir"
      echo "Removed $dir"
    fi
  done
}

while (($# > 0)); do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  -b | --build)
    bflag='-b'
    shift
    ;;
  --force)
    force=true
    shift
    ;;
  --collect)
    collectflag=true
    shift
    ;;
  -c | --cleanup)
    cflag='-c'
    shift
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

if [ -n "$collectflag" ]; then
  collect || { echo "Collecting failed. Build the libraries first ($PROGNAME -b)."; exit 1; }
  exit 0
fi

if [ -n "$cflag" ] && [ -z "$bflag" ]; then
  if ! libs_complete; then
    echo "libs/ is incomplete; not removing the build folders. Run $PROGNAME -b first."
    exit 1
  fi
  cleanup
  exit 0
fi

if [ -z "$bflag" ]; then
  usage
  exit 1
fi

if libs_complete && [ -z "$force" ]; then
  echo "libs/ is already complete ($(head -n 1 "$LIBS/VERSIONS" 2>/dev/null)). Pass --force to rebuild."
else
  # tdlib first: medialibs/build.sh uses the cmake that tdlib/build.sh builds.
  "$CWD/tdlib/build.sh" -b || { echo "tdlib build failed."; exit 1; }
  "$CWD/medialibs/build.sh" -b || { echo "media libraries build failed."; exit 1; }
  collect || { echo "Collecting failed."; exit 1; }
fi

echo ""
echo "libs Building DONE."
echo ""
cat "$LIBS/VERSIONS"
echo ""
echo "The app (LIBS_PREFIX in project.xcproj) and the CLI (cli/Package.swift) link from $LIBS."
echo ""

if [ -n "$cflag" ]; then
  libs_complete && cleanup
else
  echo "Build folders are kept. Run $PROGNAME -c to remove them; a later rebuild then starts from scratch."
  echo ""
fi

exit 0
