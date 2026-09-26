#!/bin/bash
#
# NeverSettle Kernel build script
#

set -e

# -----------------
# ARGUMENT PARSING
# -----------------

CLEAN_BUILD=false
BUILDTYPE="${BUILDTYPE:-RELEASE}"

for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN_BUILD=true
            ;;
        --test)
            BUILDTYPE="TEST"
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --clean         Perform a clean build (mrproper)"
            echo "  --test          Tag the build as TEST instead of a release version"
            echo "  --help, -h      Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# -----------------
# BUILD LOG SETUP
# -----------------

KERNEL_SRC="${PWD}"
LOG_DIR="${KERNEL_SRC}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"

# Redirect all output (stdout + stderr) to log + terminal
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==> Build log: $LOG_FILE"

# -----------------
# BUILD CONFIGURATION
# -----------------

if [ "$BUILDTYPE" = "TEST" ]; then
    VERSION="TEST"
else
    VERSION="v5.1"
fi

KERNEL_VERSION="4.19.325-cip136-st20"
CLANG_VER="r614150"
CLANG_VERSION="23.0.1"
KSU_VERSION="v3.4.0"
SUSFS_VERSION="v2.3.0"
BUILD_DATE="$(date +%d-%m-%Y)"

KERNEL_NAME="NeverSettle-Kernel-$VERSION"
ZIP_NAME="$KERNEL_NAME-$(date +%d%m%Y-%H%M).zip"

DEFCONFIGS="avicii_defconfig avicii_ext.config"
TC_DIR="${HOME}/tc"
OUTPUT_DIR="${KERNEL_SRC}/out"
PACKAGING_DIR="${KERNEL_SRC}/packaging"
AVBTOOL="${KERNEL_SRC}/scripts/avb/avbtool.py"

KERNEL_IMG="${OUTPUT_DIR}/arch/arm64/boot/Image.gz-dtb"
DTBO_IMG="${OUTPUT_DIR}/arch/arm64/boot/dtbo.img"

export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-$USER}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-$HOSTNAME}"
export ARCH=arm64
export SUBARCH=arm64
export BRAND_SHOW_FLAG=oneplus

# -----------------
# TOOLCHAIN SETUP
# -----------------

if [ ! -x "$TC_DIR/bin/clang" ]; then
    echo "==> Downloading AOSP Clang ($CLANG_VERSION, $CLANG_VER)..."
    mkdir -p "$TC_DIR"
    wget -q "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main-kernel/clang-$CLANG_VER.tar.gz" \
        -O "/tmp/clang-$CLANG_VER.tar.gz"
    tar -xzf "/tmp/clang-$CLANG_VER.tar.gz" -C "$TC_DIR"
    rm -f "/tmp/clang-$CLANG_VER.tar.gz"
fi

export PATH="$TC_DIR/bin:$PATH"
export CLANG_TRIPLE="aarch64-linux-gnu-"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
export LLVM=1
export LLVM_IAS=1
export DTC_EXT="$(command -v dtc)"

if command -v ccache &> /dev/null; then
    CC="ccache clang"
else
    CC="clang"
fi

# -----------------
# SOURCE TWEAKS
# -----------------

# Don't rewrite qcacld include paths relative to srctree
sed -i 's/ccflags-y += $(subst $(srctree),source,$(INCS))/ccflags-y += $(INCS)/g' drivers/staging/qcacld-3.0/Kbuild

# -----------------
# BUILD PROCESS
# -----------------

echo "==============================================="
echo "  NeverSettle Kernel $VERSION"
echo "==============================================="
echo "Kernel:      $KERNEL_VERSION"
echo "Clang:       $CLANG_VERSION ($CLANG_VER)"
echo "Defconfig:   $DEFCONFIGS"
echo "Clean build: $CLEAN_BUILD"
echo "Cores:       $(nproc --all)"
echo "==============================================="

START=$(date +%s)

if [ "$CLEAN_BUILD" = true ]; then
    echo "==> Cleaning source tree (mrproper)..."
    make O="$OUTPUT_DIR" mrproper
fi

echo "==> Generating defconfig..."
make -s ARCH=arm64 O="$OUTPUT_DIR" CC="$CC" $DEFCONFIGS

# Set version string on the generated config instead of editing the tracked defconfig
scripts/config --file "$OUTPUT_DIR/.config" \
    --set-str LOCALVERSION "-NeverSettle-Kernel-$VERSION" \
    --disable LOCALVERSION_AUTO
make -s ARCH=arm64 O="$OUTPUT_DIR" CC="$CC" olddefconfig

echo "==> Compiling kernel..."
make -j"$(nproc --all)" ARCH=arm64 O="$OUTPUT_DIR" CC="$CC"

# -----------------
# BUILD VERIFICATION
# -----------------

if [ ! -f "$KERNEL_IMG" ] || [ ! -f "$DTBO_IMG" ]; then
    echo "✗ Compilation failed: Image.gz-dtb or dtbo.img missing"
    exit 1
fi

echo "==> Adding AVB hash footer to dtbo.img..."
python3 "$AVBTOOL" add_hash_footer --image "$DTBO_IMG" --partition_size 25165824 --partition_name dtbo

# -----------------
# PACKAGING
# -----------------

echo "==> Creating flashable zip..."
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

# Work on a copy so the tracked packaging/ dir isn't modified
cp -r "$PACKAGING_DIR"/. "$STAGING_DIR"
cp "$KERNEL_IMG" "$DTBO_IMG" "$STAGING_DIR"

sed -i \
    -e "s/version.string=/version.string=$VERSION/" \
    -e "s/date.string=/date.string=$BUILD_DATE/" \
    -e "s/kernel.version=/kernel.version=$KERNEL_VERSION/" \
    -e "s/ksu.version=/ksu.version=$KSU_VERSION/" \
    -e "s/susfs.version=/susfs.version=$SUSFS_VERSION/" \
    -e "s/clang.version=/clang.version=$CLANG_VERSION/" \
    "$STAGING_DIR/anykernel.sh"

(cd "$STAGING_DIR" && zip -r9 "$KERNEL_SRC/$ZIP_NAME" . -x '.git*' README.md '*placeholder')

END=$(date +%s)
DIFF=$((END - START))

# -----------------
# COMPLETION
# -----------------

echo ""
echo "==============================================="
echo "        Build finished successfully!           "
echo "==============================================="
echo "Build time:    $((DIFF / 60))m $((DIFF % 60))s"
echo "Flashable ZIP: $KERNEL_SRC/$ZIP_NAME"
echo "MD5:           $(md5sum "$KERNEL_SRC/$ZIP_NAME" | cut -d' ' -f1)"
echo "==============================================="
