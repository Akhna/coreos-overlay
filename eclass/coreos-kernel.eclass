# Copyright 2013-2014 CoreOS, Inc.
# Copyright 2012 The Chromium OS Authors.
# Distributed under the terms of the GNU General Public License v2

# @ECLASS-VARIABLE: COREOS_SOURCE_REVISION
# @DESCRIPTION:
# Revision of the source ebuild, e.g. -r1. default is ""
: ${COREOS_SOURCE_REVISION:=}

COREOS_SOURCE_VERSION="${PV}${COREOS_SOURCE_REVISION}"
COREOS_SOURCE_NAME="linux-${PV}-coreos${COREOS_SOURCE_REVISION}"

[[ ${EAPI} != "5" ]] && die "Only EAPI=5 is supported"

inherit linux-info savedconfig toolchain-funcs

HOMEPAGE="http://www.kernel.org"
LICENSE="GPL-2 freedist"
SLOT="0/${PVR}"
SRC_URI=""
IUSE="audit selinux"

DEPEND="=sys-kernel/coreos-sources-${COREOS_SOURCE_VERSION}
	sys-kernel/bootengine:="

# Do not analyze or strip installed files
RESTRICT="binchecks strip"

# Use source installed by coreos-sources
KERNEL_DIR="${SYSROOT}/usr/src/${COREOS_SOURCE_NAME}"

# Search for an apropriate defconfig in ${FILESDIR}. The config should reflect
# the kernel version but partial matching is allowed if the config is
# applicalbe to multiple ebuilds, such as different -r revisions or stable
# kernel releases. For an amd64 ebuild with version 3.12.4-r2 the order is:
# (uses the portage $ARCH instead of the kernel's for simplicity sake)
#  - amd64_defconfig-3.12.4-r2
#  - amd64_defconfig-3.12.4
#  - amd64_defconfig-3.12
#  - amd64_defconfig
# The first matching config is used, die otherwise.
find_defconfig() {
	local base_path="${FILESDIR}/${ARCH}_defconfig"
	local try_suffix try_path
	for try_suffix in "-${PVR}" "-${PV}" "-${PV%.*}" ""; do
		try_path="${base_path}${try_suffix}"
		if [[ -f "${try_path}" ]]; then
			echo "${try_path}"
			return
		fi
	done

	die "No defconfig found for ${ARCH} and ${PVR} in ${FILESDIR}"
}

# @FUNCTION: get_bootengine_lib
# @DESCRIPTION:
# Check if /lib is a symlink in the current cpio. If so we need to use
# the target path (usually lib64) instead when adding new things.
# When extracting with GNU cpio the first entry (the symlink) wins but
# in the kernel the second entry (as a directory) definition wins.
# As if using cpio isn't bad enough already.
# If lib doesn't exist or isn't a symlink then nothing is returned.
get_bootengine_lib() {
	cpio -itv --quiet < build/bootengine.cpio | \
		awk '$1 ~ /^l/ && $9 == "lib" { print $11 }'
	assert
}

# @FUNCTION: update_bootengine_cpio
# @DESCRIPTION:
# Append files in the given directory to the bootengine cpio.
# Allows us to stick kernel modules into the initramfs built into the image.
update_bootengine_cpio() {
	local extra_root="$1"
	local cpio_args=(
		--create --append --null
		# dracut uses the 'newc' cpio format
		--format=newc
		# squash file ownership to root for new files.
		--owner=root:root
		# append to our local copy of bootengine
		-F "${S}/build/bootengine.cpio"
	)

	echo "Updating bootengine.cpio"
	(cd "${extra_root}" && find . -print0 | cpio "${cpio_args[@]}") || \
		die "cpio update failed!"
}

kmake() {
	local kernel_arch=$(tc-arch-kernel) kernel_cflags=
	if gcc-specs-pie; then
		kernel_cflags="-nopie -fstack-check=no"
	fi
	emake \
		ARCH="${kernel_arch}" \
		CROSS_COMPILE="${CHOST}-" \
		KBUILD_OUTPUT="build" \
		KCFLAGS="${kernel_cflags}" \
		LDFLAGS="" \
		"$@"
}

# Discard the module signing key, we use new keys for each build.
shred_keys() {
	if [[ -e signing_key.priv ]]; then
		shred -u signing_key.* || die
		rm -f x509.genkey || die
	fi
}

coreos-kernel_src_unpack() {
	mkdir -p "${S}/build" || die
	ln -s "${KERNEL_DIR}"/* "${S}/" || die
}

coreos-kernel_src_prepare() {
	if [[ -f ".config" || -d "include/config" ]]
	then
		die "Source is not clean! Run make mrproper in ${KERNEL_DIR}"
	fi

	restore_config build/.config
	if [[ ! -f build/.config ]]; then
		local config="$(find_defconfig)"
		elog "Building using default config ${config}"
		cp "${config}" build/.config || die
	fi

	# copy the cpio initrd to the output build directory so we can tack it
	# onto the kernel image itself.
	cp "${ROOT}"/usr/share/bootengine/bootengine.cpio build/bootengine.cpio \
		|| die "cp bootengine.cpio failed, try emerge-\$BOARD bootengine"
}

coreos-kernel_src_configure() {
	if ! use audit; then
		sed -i -e '/^CONFIG_CMDLINE=/s/"$/ audit=0"/' build/.config || die
	fi
	if ! use selinux; then
		sed -i -e '/CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE/d' build/.config || die
		echo CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0 >> build/.config || die
	fi

	# Use default for any options not explitly set in defconfig
	kmake olddefconfig

	# For convinence, generate a minimal defconfig of the build
	kmake savedefconfig
}

coreos-kernel_src_compile() {
	# Build both vmlinux and modules (moddep checks symbols in vmlinux)
	kmake vmlinux modules

	# Install modules and add them to the initramfs image
	local bootengine_root="${T}/bootengine"
	kmake INSTALL_MOD_PATH="${bootengine_root}" \
		  INSTALL_MOD_STRIP="--strip-unneeded" \
		  modules_install

	local bootengine_lib=$(get_bootengine_lib)
	if [[ -n "${bootengine_lib}" ]]; then
		mkdir -p "$(dirname "${bootengine_root}/${bootengine_lib}")" || die
		mv "${bootengine_root}/lib" \
			"${bootengine_root}/${bootengine_lib}" || die
	fi
	update_bootengine_cpio "${bootengine_root}"

	# Build the final kernel image
	kmake
}

coreos-kernel_src_install() {
	dodir /usr/boot
	kmake INSTALL_PATH="${D}/usr/boot" install
	# Install modules to /usr, assuming USE=symlink-usr
	# Install firmware to a temporary (bogus) location.
	# The linux-firmware package will be used instead.
	# Stripping must be done here, not portage, to preserve sigs.
	# Uncomment vdso_install for easy access to debug symbols in gdb:
	#   set debug-file-directory /lib/modules/4.0.7-coreos-r2/vdso/
	kmake INSTALL_MOD_PATH="${D}/usr" \
		  INSTALL_MOD_STRIP="--strip-unneeded" \
		  INSTALL_FW_PATH="${T}/fw" \
		  modules_install # vdso_install

	local version=$(kmake -s --no-print-directory kernelrelease)
	dosym "vmlinuz-${version}" /usr/boot/vmlinuz
	dosym "config-${version}" /usr/boot/config

	# build and source must cleaned up to avoid referencing $ROOT
	rm "${D}/usr/lib/modules/${version}"/{build,source} || die
	dosym "../../../src/linux-${version}" "/usr/lib/modules/${version}/source"

	# this is just here for linux-info.eclass, mask from prod images
	dodir "/usr/lib/modules/${version}/build"
	dosym "../../../../boot/config-${version}" \
		"/usr/lib/modules/${version}/build/.config"

	save_config build/defconfig

	shred_keys
}

EXPORT_FUNCTIONS src_unpack src_prepare src_configure src_compile src_install
