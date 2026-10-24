#!/bin/bash


PROGNAME=$(basename "$0")

SCRIPT_VERSION=1.0.0

CWD=$(cd "$(dirname "$0")" && pwd)
PACKAGES="$CWD/packages"
WORKSPACE="$CWD/workspace"
LATEST=false
CURRENT_PACKAGE_VERSION=0


command_exists() {
  if ! [[ -x $(command -v "$1") ]]; then
    return 1
  fi

  return 0
}

if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "This script only supports macOS."
  exit 1
fi

# Check for Apple Silicon
if [[ "$(uname -m)" == "arm64" ]]; then
  export ARCH=arm64
  OPENSSL_TARGET=darwin64-arm64-cc
  echo "Apple Silicon detected."
else
  export ARCH=x86_64
  OPENSSL_TARGET=darwin64-x86_64-cc
  echo "Intel Mac detected."
fi

export MACOSX_DEPLOYMENT_TARGET=13.0
echo "macOS Version: $(sw_vers -productVersion), deployment target: $MACOSX_DEPLOYMENT_TARGET"

# Speed up the process
# Env Var NUMJOBS overrides automatic detection
if [[ -n "$NUMJOBS" ]]; then
  MJOBS="$NUMJOBS"
else
  MJOBS=$(sysctl -n hw.ncpu)
fi

make_dir() {
  remove_dir "$1"
  if ! mkdir "$1"; then
    printf "\n Failed to create dir %s" "$1"
    exit 1
  fi
}

remove_dir() {
  if [ -d "$1" ]; then
    rm -rf "$1"
  fi
}

download() {
  # download url [filename[dirname]]

  DOWNLOAD_PATH="$PACKAGES"
  DOWNLOAD_FILE="${2:-"${1##*/}"}"

  if [[ "$DOWNLOAD_FILE" =~ tar. ]]; then
    TARGETDIR="${DOWNLOAD_FILE%.*}"
    TARGETDIR="${3:-"${TARGETDIR%.*}"}"
  else
    TARGETDIR="${3:-"${DOWNLOAD_FILE%.*}"}"
  fi

  if [ ! -f "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ] || [ ! -s "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ]; then
    echo "Downloading $1 as $DOWNLOAD_FILE"

    MAX_RETRIES=2
    RETRY_COUNT=0
    SUCCESS=false

    while [ $RETRY_COUNT -le $MAX_RETRIES ]; do
      if [ $RETRY_COUNT -gt 0 ]; then
        echo "Retrying download (attempt $((RETRY_COUNT + 1))/$((MAX_RETRIES + 1))) in 10 seconds..."
        sleep 10
      fi

      curl -L --silent --fail -o "$DOWNLOAD_PATH/$DOWNLOAD_FILE" "$1"
      EXITCODE=$?

      if [ $EXITCODE -eq 0 ] && [ -s "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ]; then
        SUCCESS=true
        break
      fi

      echo "Failed to download $1 (Exitcode $EXITCODE or empty file)"
      RETRY_COUNT=$((RETRY_COUNT + 1))
    done

    if [ "$SUCCESS" = false ]; then
      echo "Failed to download $1 after $((MAX_RETRIES + 1)) attempts."
      exit 1
    fi

    echo "... Done"
  else
    echo "$DOWNLOAD_FILE has already been downloaded and is not empty."
  fi

  make_dir "$DOWNLOAD_PATH/$TARGETDIR"

  if ! tar -xf "$DOWNLOAD_PATH/$DOWNLOAD_FILE" -C "$DOWNLOAD_PATH/$TARGETDIR" --strip-components 1 2>/dev/null >/dev/null; then
    echo "Failed to extract $DOWNLOAD_FILE"
    exit 1
  fi

  echo "Extracted $DOWNLOAD_FILE"

  cd "$DOWNLOAD_PATH/$TARGETDIR" || {
    echo "Error has occurred."
    exit 1
  }
}

execute() {
  echo "$ $*"

  OUTPUT=$("$@" 2>&1)

  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    echo "$OUTPUT"
    echo ""
    echo "Failed to Execute $*" >&2
    exit 1
  fi
}

build() {
  echo ""
  echo "building $1 - version $2"
  echo "======================="
  CURRENT_PACKAGE_VERSION=$2

  if [ -f "$PACKAGES/$1.done" ]; then
    if grep -Fx "$2" "$PACKAGES/$1.done" >/dev/null; then
      echo "$1 version $2 already built. Remove $PACKAGES/$1.done lockfile to rebuild it."
      return 1
    elif $LATEST; then
      echo "$1 is outdated and will be rebuilt with latest version $2"
      return 0
    else
      echo "$1 is outdated, but will not be rebuilt. Pass in --latest to rebuild it or remove $PACKAGES/$1.done lockfile."
      return 1
    fi
  fi

  return 0
}

build_done() {
  echo "$2" >"$PACKAGES/$1.done"
}

cleanup() {
  remove_dir "$PACKAGES"
  remove_dir "$WORKSPACE"
  echo "Cleanup done."
  echo ""
}

usage() {
  echo "Usage: $PROGNAME [OPTIONS]"
  echo "Options:"
  echo "  -h, --help                     Display usage information"
  echo "      --version                  Display version information"
  echo "  -b, --build                    Starts the build process"
  echo "  -c, --cleanup                  Remove all working dirs"
  echo "      --latest                   Rebuild packages whose version changed"
  echo ""
}

echo "tdlib-deps-build-script v$SCRIPT_VERSION"
echo "========================="
echo ""

while (($# > 0)); do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  --version)
    echo "$SCRIPT_VERSION"
    exit 0
    ;;
  -b | --build)
    bflag='-b'
    shift
    ;;
  -c | --cleanup)
    cflag='-c'
    cleanup
    shift
    ;;
  --latest)
    LATEST=true
    shift
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

if [ -z "$bflag" ]; then
  if [ -z "$cflag" ]; then
    usage
    exit 1
  fi
  exit 0
fi

echo "Using $MJOBS make jobs simultaneously."

mkdir -p "$PACKAGES"
mkdir -p "$WORKSPACE"

export PATH="${WORKSPACE}/bin:$PATH"

if ! command_exists "make"; then
  echo "make not installed."
  exit 1
fi

if ! command_exists "clang++"; then
  echo "clang++ is not installed. Please install Xcode Command Line Tools."
  exit 1
fi

if ! command_exists "curl"; then
  echo "curl not installed."
  exit 1
fi

if ! command_exists "perl"; then
  echo "perl not installed. It is required to configure OpenSSL."
  exit 1
fi

##
## build tools
##

if build "gperf" "3.3"; then
  download "https://ftpmirror.gnu.org/gnu/gperf/gperf-$CURRENT_PACKAGE_VERSION.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j "$MJOBS"
  execute make install
  build_done "gperf" $CURRENT_PACKAGE_VERSION
fi

if build "cmake" "4.2.3"; then
  download "https://github.com/Kitware/CMake/releases/download/v$CURRENT_PACKAGE_VERSION/cmake-$CURRENT_PACKAGE_VERSION.tar.gz"
  execute ./configure --prefix="${WORKSPACE}" --parallel="${MJOBS}" -- -DCMAKE_USE_OPENSSL=OFF
  execute make -j "$MJOBS"
  execute make install
  build_done "cmake" $CURRENT_PACKAGE_VERSION
fi

##
## libraries
##

if build "openssl" "3.6.1"; then
  download "https://github.com/openssl/openssl/releases/download/openssl-$CURRENT_PACKAGE_VERSION/openssl-$CURRENT_PACKAGE_VERSION.tar.gz"
  execute ./Configure "$OPENSSL_TARGET" --prefix="${WORKSPACE}" --openssldir="${WORKSPACE}/ssl" --libdir="lib" no-shared no-tests
  execute make -j "$MJOBS"
  execute make install_sw
  build_done "openssl" $CURRENT_PACKAGE_VERSION
fi

cd "$CWD" || exit 1

echo ""
echo "tdlib dependencies Building DONE."
echo ""
echo "  gperf:   $("${WORKSPACE}/bin/gperf" --version | head -n 1)"
echo "  cmake:   $("${WORKSPACE}/bin/cmake" --version | head -n 1)"
echo "  openssl: $("${WORKSPACE}/bin/openssl" version)"
echo ""

##
## tdlib
##

TD_SOURCE="$CWD/td"
if [ ! -f "$TD_SOURCE/CMakeLists.txt" ]; then
  if ! command_exists "git"; then
    echo "git not installed. It is required to fetch the tdlib source."
    exit 1
  fi
  execute git clone https://github.com/tdlib/td.git "$TD_SOURCE"
fi

# The version comes from the source tree, so pulling a newer td rebuilds it.
TD_VERSION=$(sed -n 's/^project(TDLib VERSION \([0-9.]*\).*/\1/p' "$TD_SOURCE/CMakeLists.txt")

if build "tdlib" "$TD_VERSION"; then
  echo "Building tdlib takes a while (often 10-30 minutes). Set NUMJOBS lower if the machine runs out of memory."
  make_dir "$TD_SOURCE/build"
  cd "$TD_SOURCE/build" || exit 1
  execute cmake -DCMAKE_BUILD_TYPE=Release -DOPENSSL_ROOT_DIR="${WORKSPACE}" -DCMAKE_INSTALL_PREFIX:PATH=../tdlib -DTD_ENABLE_LTO=ON ..
  execute cmake --build . --target install -j "$MJOBS"
  build_done "tdlib" $CURRENT_PACKAGE_VERSION
fi

cd "$CWD" || exit 1

echo ""
echo "tdlib Building DONE."
echo ""
echo "  tdlib:   $TD_VERSION, installed in $TD_SOURCE/tdlib"
echo ""
ls -l "$TD_SOURCE/tdlib/lib"/*.a
echo ""

exit 0
