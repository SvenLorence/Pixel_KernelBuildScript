#!/usr/bin/env bash

# ==============================================================================
#                              INITIALIZATION
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Variables.conf
source "$PROJECT_ROOT/Variables.conf"

# ==============================================================================
#                                FUNCTIONS
# ==============================================================================

usage() {
  echo "Usage: $0 --stable|--beta --ksu|--ksun|--sukisu"
  exit 1
}

log() {
  printf '\nℹ️ ==> %s\n' "$1"
}

apply_patch_file() {
  local target="$1"
  local patch_file="$2"
  local optional="${3:-0}"

  printf '  -> %s\n' "$(basename "$patch_file")"
  if [[ "$optional" == "1" ]]; then
    patch -d "$target" -p1 < "$patch_file" || true
  else
    patch -d "$target" -p1 < "$patch_file"
  fi
}

# ==============================================================================
#                            ARGUMENT PARSING
# ==============================================================================

TYPE_FIRMWARE=""
KSU_TYPE_FLAG=""

for arg in "$@"; do
  case $arg in
    --stable) TYPE_FIRMWARE="STABLE" ; FOLDER_KERNEL="stable_source" ;;
    --beta) TYPE_FIRMWARE="BETA" ; FOLDER_KERNEL="beta_source" ;;
    --ksu) KSU_TYPE_FLAG="KernelSU" ;;
    --ksun) KSU_TYPE_FLAG="KernelSU-Next" ;;
    --sukisu) KSU_TYPE_FLAG="SukiSU-Ultra" ;;
    *) echo "Unknown flag: $arg"; usage ;;
  esac
done

if [[ -z "$TYPE_FIRMWARE" || -z "$KSU_TYPE_FLAG" ]]; then
  usage
fi

KSU_TYPE="$KSU_TYPE_FLAG"
KERNEL="$PROJECT_ROOT/pixel"
AOSP="$KERNEL/common/ack"
DEFCONFIG="$KERNEL/private/devices/google/shusky/shusky_defconfig"
PATCH_DIR="$PROJECT_ROOT/patches/ksu-next_susfs"

# ==============================================================================
#                              CLEAN WORKSPACE
# ==============================================================================

log "Clean workspace"
sudo umount "$AOSP" 2>/dev/null || true
rm -rf "$PROJECT_ROOT/susfs4ksu" "$PROJECT_ROOT/KPatch-Next" "$PROJECT_ROOT/output" "$PROJECT_ROOT/AnyKernel3" 2>/dev/null || true

for kernel_folder in stable_source beta_source; do
  cd "$PROJECT_ROOT/$kernel_folder"
  git reset --hard HEAD
  git clean -fdx
  rm -rf Baseband-guard KernelSU KernelSU-Next
done

cd "$KERNEL"
git reset --hard HEAD
git clean -fdx

# ==============================================================================
#                             PREPARE SOURCES
# ==============================================================================

cd "$PROJECT_ROOT"
git clone https://gitlab.com/simonpunk/susfs4ksu --single-branch -b gki-android14-6.1
cd "$PROJECT_ROOT/susfs4ksu"
if [[ "$KSU_TYPE" == "KernelSU" ]]; then
  git checkout "$SUSFS_KSU_COMMIT"
else
  git checkout "$SUSFS_COMMIT"
fi

log "Mount kernel source"
sudo mount --bind "$PROJECT_ROOT/$FOLDER_KERNEL" "$AOSP"

log "Formation of variables"
rollback_index="${TYPE_FIRMWARE}_rollback_index"
salt="${TYPE_FIRMWARE}_salt"
os_version="${TYPE_FIRMWARE}_os_version"
fingerprint="${TYPE_FIRMWARE}_fingerprint"
security_patch="${TYPE_FIRMWARE}_security_patch"

# ==============================================================================
#                            KERNEL CONFIGURATION
# ==============================================================================

log "Configure kernel"
cat >> "$DEFCONFIG" <<EOF
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_THREAD_INFO_IN_TASK=y
EOF

if [[ "$KSU_TYPE" == "KernelSU-Next" ]]; then
cat >> "$DEFCONFIG" <<EOF
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
EOF
fi

rm -rf "$AOSP"/android/abi_gki_protected_exports_*
perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' "$AOSP/BUILD.bazel"
sed -i 's/echo -n -dirty/echo -n ""/g' "$KERNEL/build/kernel/kleaf/workspace_status_stamp.py"

KERNEL_VER="$(sed -n '2,4p' "$AOSP/Makefile" | grep -oE '[0-9]+' | paste -sd '.')"

# ==============================================================================
#                           ROOT SOLUTION SETUP
# ==============================================================================

if [[ "$KSU_TYPE" == "KernelSU" ]]; then
  # ---------------------------------------------------------
  # Setup: KernelSU
  # ---------------------------------------------------------
  log "Install KernelSU"
  cd "$AOSP"
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
  cd "$AOSP/$KSU_TYPE"
  git checkout "$KSU_COMMIT"

  log "Apply SUSFS patches"
  cp "$PROJECT_ROOT/susfs4ksu/kernel_patches/fs/"* "$AOSP/fs/"
  cp "$PROJECT_ROOT/susfs4ksu/kernel_patches/include/linux/"* "$AOSP/include/linux/"
  if [[ "$TYPE_FIRMWARE" == "BETA" || "$TYPE_FIRMWARE" == "STABLE" ]]; then
    apply_patch_file "$AOSP" "$PROJECT_ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch" 1
  else
    apply_patch_file "$AOSP" "$PROJECT_ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch"
  fi
  apply_patch_file "$AOSP/$KSU_TYPE" "$PROJECT_ROOT/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

  log "Adding Signature"
  sed -i 's/0x033b/897/' "${AOSP}/${KSU_TYPE}/kernel/Kbuild"
  sed -i 's/c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6/b2e20f9dc4520d5f93a2e6ae19eecff475739dc0062d148644ee5111622d039d/' "${AOSP}/${KSU_TYPE}/kernel/Kbuild"

elif [[ "$KSU_TYPE" == "KernelSU-Next" ]]; then
  # ---------------------------------------------------------
  # Setup: KernelSU-Next
  # ---------------------------------------------------------
  log "Install KernelSU-Next"
  cd "$AOSP"
  curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" | bash -s dev-susfs
  cd "$AOSP/KernelSU-Next"
  git checkout "$KSU_NEXT_COMMIT"
  log "KernelSU-Next commits list"
  git log

  log "Apply SUSFS patches"
  cp "$PROJECT_ROOT/susfs4ksu/kernel_patches/fs/"* "$AOSP/fs/"
  cp "$PROJECT_ROOT/susfs4ksu/kernel_patches/include/linux/"* "$AOSP/include/linux/"
  apply_patch_file "$AOSP" "$PROJECT_ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch" 1
  
  # ┌─────────────────────────────────────────────┐
  # │ По аналогии с SukiSU, patch'и SUSFS         │
  # │ требуются только к ядру, а не драйверу KSU, │
  # │ так как драйвер уже заранее пропатчен.      │
  # └─────────────────────────────────────────────┘
  # apply_patch_file "$AOSP/$KSU_TYPE" "$PROJECT_ROOT/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" 1

elif [[ "$KSU_TYPE" == "SukiSU-Ultra" ]]; then
  # ---------------------------------------------------------
  # Setup: SukiSU-Ultra
  # ---------------------------------------------------------
  log "Install SukiSU-Ultra"
  cd "$AOSP"
  curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin

  log "Apply SUSFS patches"
  cp "$PROJECT_ROOT/susfs4ksu/kernel_patches/fs/"* "$AOSP/fs/"
  cp "$PROJECT_ROOT/susfs4ksu/kernel_patches/include/linux/"* "$AOSP/include/linux/"
  
  #####################################################
  ### Применяется только 50_add_susfs_in_gki.patch  ###
  ### 10_enable_susfs_for_ksu.patch не применяется  ###
  #####################################################
  apply_patch_file "$AOSP" "$PROJECT_ROOT/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch" 1

  log "Adding Signature"
  APK_SIGN_C="${AOSP}/KernelSU/kernel/manager/apk_sign.c"
  awk -v size="${SIG_SIZE_SUKISU:-897}" -v sha="${SIG_HASH_SUKISU:-b2e20f9dc4520d5f93a2e6ae19eecff475739dc0062d148644ee5111622d039d}" '
    /^} apk_sign_keys\[\] = \{$/  { print; skip=1; next }
    skip && /^\};$/               { print "    { " size ", \"" sha "\" }, // Custom"; skip=0 }
    skip                          { next }
                                  { print }
  ' "${APK_SIGN_C}" > "${APK_SIGN_C}.tmp" && mv "${APK_SIGN_C}.tmp" "${APK_SIGN_C}"
fi

# ==============================================================================
#                        ADDITIONAL PATCHES & SECURITY
# ==============================================================================

if [[ "$TYPE_FIRMWARE" == "BETA" || "$TYPE_FIRMWARE" == "STABLE" ]]; then
  log "Patching Kernel Source"
  for kernelsource_patch_name in "${KERNELSOURCE_PATCHES[@]}"; do
    apply_patch_file "$AOSP" "$PATCH_DIR/$kernelsource_patch_name"
  done
fi

log "Install Baseband-guard"
cd "$AOSP"
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash
echo "CONFIG_BBG=y" >> "$DEFCONFIG"
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "$AOSP/security/Kconfig"

# ==============================================================================
#                               BUILD PROCESS
# ==============================================================================

log "Correction of the .sh script used for build"
sed -i '/zuma_shusky_dist/q' "$KERNEL/build_shusky.sh"
sed -i 's/zuma_shusky_dist/kernel/' "$KERNEL/build_shusky.sh"
sed -i 's/bazel run/bazel build/' "$KERNEL/build_shusky.sh"

log "Build kernel"
cd "$KERNEL"
tools/bazel clean --expunge
KLEAF_REPO_MANIFEST=aosp_manifest.xml ./build_shusky.sh --config=fast --lto=thin --keep_going

# ==============================================================================
#                             BOOT.IMG PREPARATION
# ==============================================================================

log "Prepare boot.img"
DIST="$(find "$KERNEL/out/bazel/output_user_root" -type d -name kernel_kbuild_mixed_tree)"
TMPDIR="$(mktemp -d)"
mkdir -p "$TMPDIR/gki"

curl -fsSL 'https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/main/mkbootimg.py?format=TEXT' | base64 -d > "$TMPDIR/mkbootimg.py"
curl -fsSL 'https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/main/gki/generate_gki_certificate.py?format=TEXT' | base64 -d > "$TMPDIR/gki/generate_gki_certificate.py"
curl -fsSL 'https://android.googlesource.com/platform/external/avb/+/refs/heads/main-kernel/avbtool.py?format=TEXT' | base64 -d > "$TMPDIR/avbtool.py"
: > "$TMPDIR/gki/__init__.py"

lz4 -l -12 -f "$DIST/Image" "$TMPDIR/kernel"
: > "$TMPDIR/ramdisk"

python3 "$TMPDIR/mkbootimg.py" \
  --header_version 4 \
  --pagesize 4096 \
  --kernel "$TMPDIR/kernel" \
  --ramdisk "$TMPDIR/ramdisk" \
  --cmdline '' \
  --os_patch_level "${!security_patch}" \
  -o "$DIST/boot.img"

mkdir -p "$PROJECT_ROOT/output"

# ==============================================================================
#                          KERNELSU-NEXT PATCHING
# ==============================================================================

if [[ "$KSU_TYPE" == "KernelSU-Next" ]]; then
  log "Prepare patched boot.img"
  mkdir -p "$PROJECT_ROOT/KPatch-Next"
  cd "$PROJECT_ROOT/KPatch-Next"
  gh release download --repo KernelSU-Next/KPatch-Next -p 'kpimg-linux' -p 'kptools-linux' --clobber
  chmod +x kptools-linux
  ./kptools-linux -p -i "$DIST/Image" -k kpimg-linux -o "$DIST/Image_patched"
  mv -f "$DIST/Image_patched" "$DIST/Image"

  gh release download v30.2 --repo topjohnwu/Magisk -p 'Magisk*.apk' --clobber
  unzip -oj Magisk*.apk lib/x86_64/libmagiskboot.so
  mv -f libmagiskboot.so magiskboot
  chmod +x magiskboot

  cp "$DIST/boot.img" "$PROJECT_ROOT/output/"
  cd "$PROJECT_ROOT/output"
  "$PROJECT_ROOT/KPatch-Next/magiskboot" unpack boot.img
  cp -f "$DIST/Image" ./kernel
  "$PROJECT_ROOT/KPatch-Next/magiskboot" repack boot.img boot_patched.img
  mv -f boot_patched.img boot.img
else
  cp "$DIST/boot.img" "$PROJECT_ROOT/output/"
  cd "$PROJECT_ROOT/output"
fi

# ==============================================================================
#                               AVB SIGNING
# ==============================================================================

python3 "$TMPDIR/avbtool.py" add_hash_footer \
  --image "$PROJECT_ROOT/output/boot.img" \
  --partition_name boot \
  --partition_size 67108864 \
  --hash_algorithm sha256 \
  --algorithm NONE \
  --rollback_index "${!rollback_index}" \
  --rollback_index_location 0 \
  --flags 0 \
  --salt "${!salt}" \
  --prop "com.android.build.boot.os_version:${!os_version}" \
  --prop "com.android.build.boot.fingerprint:${!fingerprint}" \
  --prop "com.android.build.boot.security_patch:${!security_patch}"

# ==============================================================================
#                          PACKAGING AND CLEANUP
# ==============================================================================

rm -rf *kernel* ramdisk* header* dtb* unknown*
rm -rf "$TMPDIR"

BOOT_NAME="${KERNEL_VER}_boot.img_${KSU_TYPE}"
7z a "${BOOT_NAME}.7z" boot.img

rm -f boot.img
printf '\nDone: output/%s.7z\n' "${BOOT_NAME}"