#!/bin/bash

# This runs inside the Docker image

set -e  # Exit on error

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
    echo "Please pass Fulcrum, rocksdb, jemalloc, and miniupnpc dirnames as the four args"
    exit 1
fi

PACKAGE="$1"
ROCKSDB_PACKAGE="$2"
JEMALLOC_PACKAGE="$3"
MINIUPNPC_PACKAGE="$4"
TARGET_BINARY=Fulcrum.exe
TARGET_ADMIN_SCRIPT=FulcrumAdmin
if [ -n "$5" ]; then
    DEBUG_BUILD=1  # optional 5th arg, if not empty, is debug
else
    DEBUG_BUILD=0
fi

top=/work
cd "$top" || fail "Could not cd $top"
. "$top/$PACKAGE/contrib/build/common/common.sh" || (echo "Cannot source common.h" && exit 1)

# miniupnpc
info "Building miniupnpc ..."
git config --global --add safe.directory "$top"/"$MINIUPNPC_PACKAGE"  # Needed for some versions of git to not complain
mkdir -p /tmp/include || fail "Could not create /tmp/include"
mkdir -p /tmp/lib || fail "Could not create /tmp/lib"
mkdir -p /tmp/man || fail "Could not create /tmp/man"
pushd "$top/$MINIUPNPC_PACKAGE" || fail "Coult not change dir to $MINIUPNPC_PACKAGE"
mkdir -p build
cd build
/opt/mxe/usr/x86_64-pc-linux-gnu/bin/cmake  .. -DCMAKE_C_COMPILER=x86_64-w64-mingw32.static-gcc \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_HOST_SYSTEM_NAME=Linux -G"Unix Makefiles" -DCMAKE_BUILD_TYPE="Release" \
    -DCMAKE_INSTALL_INCLUDEDIR=/tmp/include -DCMAKE_INSTALL_LIBDIR=/tmp/lib -DCMAKE_INSTALL_MANDIR=/tmp/man \
    -DUPNPC_BUILD_STATIC=TRUE  -DUPNPC_BUILD_SHARED=FALSE -DUPNPC_BUILD_TESTS=FALSE -DUPNPC_BUILD_SAMPLE=FALSE \
|| fail "Could not run CMake"
make -j`nproc` || fail "Could not build miniupnpc"
make install || fail "Could not install miniupnpc"
rm -vf /tmp/lib/libminiupnpc*.dll* /tmp/lib/libminiupnpc*.so*
rm -fr /tmp/man/*
for a in /tmp/lib/libminiupnpc*.a; do
    bn=`basename $a`
    info "Stripping $bn ..."
    x86_64-w64-mingw32.static-strip -g "$a" || fail "Failed to strip $a"
done
popd > /dev/null
printok "miniupnpc built and installed in /tmp/"
# /miniupnpc

info "Running configure for jemalloc ..."
git config --global --add safe.directory "$top"/"$JEMALLOC_PACKAGE"  # Needed for some versions of git to not complain
cd "$JEMALLOC_PACKAGE" || fail "Could not change dir to $JEMALLOC_PACKAGE"
CXX=x86_64-w64-mingw32.static-g++ LD=x86_64-w64-mingw32.static-ld CC=x86_64-w64-mingw32.static-gcc \
    ./autogen.sh --host x86_64-w64-mingw32 --with-jemalloc-prefix= --disable-shared --enable-static \
|| fail "Configure of jemalloc failed"

info "Building jemalloc ..."
make -j`nproc` || fail "Could not build jemalloc"
make install || fail "Could not install jemalloc"
JEMALLOC_LIBDIR=$(jemalloc-config --libdir)
[ -n "$JEMALLOC_LIBDIR" ] || fail "Could not determine JEMALLOC_LIBDIR"
JEMALLOC_INCDIR=$(jemalloc-config --includedir)
[ -n "$JEMALLOC_INCDIR" ] || fail "Could not determine JEMALLOC_INCDIR"
if ((! DEBUG_BUILD)); then
    for a in "$JEMALLOC_LIBDIR"/jemalloc*.lib; do
        bn=`basename $a`
        info "Stripping $bn ..."
        x86_64-w64-mingw32.static-strip -g "$a" || fail "Failed to strip $a"
    done
fi
printok "jemalloc static library built and installed in $JEMALLOC_LIBDIR"

cd "$top" || fail "Could not cd $top"  # back to top to proceed to rocksdb build

info "Running CMake for RocksDB ..."
git config --global --add safe.directory "$top"/"$ROCKSDB_PACKAGE"  # Needed for some versions of git to not complain
cd "$ROCKSDB_PACKAGE" && mkdir build/ && cd build || fail "Could not change to build dir"
/opt/mxe/usr/x86_64-pc-linux-gnu/bin/cmake  .. -DCMAKE_C_COMPILER=x86_64-w64-mingw32.static-gcc \
    -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32.static-g++ -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_HOST_SYSTEM_NAME=Linux -G"Unix Makefiles" -DWITH_GFLAGS=0 -DWITH_JNI=0  \
    -DCMAKE_BUILD_TYPE="Release" -DUSE_RTTI=1 -DPORTABLE=1 -DWITH_JEMALLOC=OFF \
    -DFAIL_ON_WARNINGS=OFF \
|| fail "Could not run CMake"

info "Building RocksDB ..."
#make -j`nproc` VERBOSE=1 rocksdb || fail "Could not build RocksDB"  # Uncomment this for verbose compile
make -j`nproc` rocksdb || fail "Could not build RocksDB"

if ((! DEBUG_BUILD)); then
    info "Stripping librocksdb.a ..."
    x86_64-w64-mingw32.static-strip -g librocksdb.a || fail "Could not strip librocksdb.a"
fi

info "Copying librocksdb.a to Fulcrum directory ..."
ROCKSDB_LIBDIR="$top"/"$PACKAGE"/staticlibs/rocksdb/bin/custom_win64  # prevents -dirty git commit hash
ROCKSDB_INCDIR="$top"/"$PACKAGE"/staticlibs/rocksdb/include
mkdir -p "${ROCKSDB_LIBDIR}" || fail "Could not create directory ${ROCKSDB_LIBDIR}"
cp -fpva librocksdb.a "${ROCKSDB_LIBDIR}" || fail "Could not copy librocksdb.a"
printok "RocksDB built and moved to Fulcrum staticlibs directory"

cd "$top"/"$PACKAGE" || fail "Could not chdir to Fulcrum dir"

if ((DEBUG_BUILD)); then
    dbg_opts="CONFIG+=debug CONFIG-=release"
    dbg_blurb="(Debug)"
    out_dir="debug"
else
    dbg_opts="CONFIG-=debug CONFIG+=release"
    dbg_blurb="(Release)"
    out_dir="release"
fi

info "Building Fulcrum ${dbg_blurb} ..."
git config --global --add safe.directory "$top"/"$PACKAGE"  # Needed for some versions of git to not complain
mkdir build && cd build || fail "Could not create/change-to build/"

# Hack/workaround for Qt6 qmake which, if it's a symlink, ends up
# not being able to find its own qmakespec.
# The below tries to dereference the symlink and find the actual
# path that qmake lives at, and call it using that, since that
# apparently makes Qt6 qmake happy.
ACTUAL_QMAKE=$(stat --format '%N' `which qmake` | cut -f4 -d "'")
if [ -z "${ACTUAL_QMAKE}" ]; then
    # not a symlink, just use "qmake"
    ACTUAL_QMAKE=qmake
fi

# Figure out the git commit hash
GIT_COMMIT=$(git -C .. describe --always --dirty --match NOT_A_TAG)

${ACTUAL_QMAKE} -makefile ../Fulcrum.pro ${dbg_opts} \
                     LIBS+="-L${ROCKSDB_LIBDIR}" LIBS+="-lrocksdb" \
                     INCLUDEPATH+="${ROCKSDB_INCDIR}" \
                     LIBS+="-L${JEMALLOC_LIBDIR}" LIBS+="-ljemalloc" \
                     INCLUDEPATH+="${JEMALLOC_INCDIR}" \
                     LIBS+="-L/opt/mxe/usr/x86_64-w64-mingw32.static/lib" LIBS+="-lzmq" LIBS+="-lsodium" \
                     INCLUDEPATH+="/tmp/include" LIBS+="-L/tmp/lib -lminiupnpc -liphlpapi" \
                     DEFINES+="MINIUPNP_STATICLIB" \
                     INCLUDEPATH+="/opt/mxe/usr/x86_64-w64-mingw32.static/include" \
                     DEFINES+="ZMQ_STATIC" \
                     DEFINES+='GIT_COMMIT="\\\"'${GIT_COMMIT}'\\\""' \
    || fail "Could not run qmake"
make -j`nproc`  || fail "Could not run make"

ls -al "${out_dir}/$TARGET_BINARY" || fail "$TARGET_BINARY not found"
printok "$TARGET_BINARY built"

info "Copying to top level ..."
mkdir -p "$top/built" || fail "Could not create build products directory"
cp -fpva "${out_dir}/$TARGET_BINARY" "$top/built/." || fail "Could not copy $TARGET_BINARY"
cd "$top" || fail "Could not cd to $top"

function build_AdminScript {
    info "Preparing to build ${TARGET_ADMIN_SCRIPT}.exe ..."
    pushd "$top" 1> /dev/null || fail "Could not chdir to $top"
    rm -fr tmp || true
    mkdir tmp || fail "Cannot mkdir tmp"
    cd tmp || fail "Cannot chdir tmp"
    export WINEPREFIX=$HOME/wine64
    export WINEDEBUG=-all
    #ARCH=win32
    #PYTHON_VERSION=3.6.8
    #WINE=wine
    ARCH=amd64
    PYTHON_VERSION=3.8.2
    WINE=wine64
    PYHOME=c:/python$PYTHON_VERSION
    PYTHON="$WINE $PYHOME/python.exe -OO -B"
    info "Starting Wine ..."
    $WINE 'wineboot' || fail "Cannot start Wine ..."
    info "Installing Python $PYTHON_VERSION (within Wine) ..."
    for msifile in core dev exe lib pip tools; do
        info "Downloading Python component: ${msifile} ..."
        wget "https://www.python.org/ftp/python/$PYTHON_VERSION/${ARCH}/${msifile}.msi"
        info "Installing Python component: ${msifile} ..."
        $WINE msiexec /i "${msifile}.msi" /qn TARGETDIR=$PYHOME || fail "Failed to install Python component: ${msifile}"
    done
    pver=$($PYTHON --version) || fail "Could not verify version"
    printok "Python reports version: $pver"
    unset pver
    info "Updating Python $PYTHON_VERSION ..."
    $PYTHON -m pip install --upgrade pip || fail "Failed to update Python"
    info "Installing PyInstaller ..."
    $PYTHON -m pip install --upgrade pyinstaller || fail "Failed to install PyInstaller"
    info "Building ${TARGET_ADMIN_SCRIPT}.exe (with PyInstaller) ..."
    cp -fpva "$top/$PACKAGE/${TARGET_ADMIN_SCRIPT}" . || fail "Failed to copy script"
    cp -fpva "$top/$PACKAGE/contrib/build/win/${TARGET_ADMIN_SCRIPT}.spec" . || fail "Failed to copy .spec file"
    # TODO: Add an icon here, -i option
    $PYTHON -m PyInstaller --clean ${TARGET_ADMIN_SCRIPT}.spec \
        || fail "Failed to build ${TARGET_ADMIN_SCRIPT}.exe"
    info "Copying to top level ..."
    mkdir -p "$top/built" || true
    cp -fpva dist/${TARGET_ADMIN_SCRIPT}.exe "$top/built/." || fail "Could not copy to top level"
    printok "${TARGET_ADMIN_SCRIPT}.exe built"
    cd "$top" && rm -fr tmp
    popd 1> /dev/null
    # Be tidy and clean up variables we created above
    unset WINEPREFIX WINEDEBUG ARCH PYTHON_VERSION WINE PYHOME PYTHON
}
build_AdminScript || fail "Could not build ${TARGET_ADMIN_SCRIPT}.exe"


printok "Inner _build.sh finished"
