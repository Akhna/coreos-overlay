# Copyright 1999-2014 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: /var/cvsroot/gentoo-x86/net-fs/nfs-utils/nfs-utils-1.2.9-r3.ebuild,v 1.7 2014/08/11 13:38:48 vapier Exp $

EAPI="4"

inherit eutils flag-o-matic multilib autotools systemd

DESCRIPTION="NFS client and server daemons"
HOMEPAGE="http://linux-nfs.org/"
SRC_URI="mirror://sourceforge/nfs/${P}.tar.bz2"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="alpha amd64 arm arm64 hppa ia64 ~mips ppc ppc64 s390 sh sparc x86"
IUSE="caps ipv6 kerberos +libmount nfsdcld +nfsidmap +nfsv4 nfsv41 selinux tcpd +uuid"
REQUIRED_USE="kerberos? ( nfsv4 )"
RESTRICT="test" #315573

# kth-krb doesn't provide the right include
# files, and nfs-utils doesn't build against heimdal either,
# so don't depend on virtual/krb.
# (04 Feb 2005 agriffis)
DEPEND_COMMON="tcpd? ( sys-apps/tcp-wrappers )
	caps? ( sys-libs/libcap )
	sys-libs/e2fsprogs-libs
	>=net-nds/rpcbind-0.2.0-r1
	net-libs/libtirpc
	libmount? ( sys-apps/util-linux )
	nfsdcld? ( >=dev-db/sqlite-3.3 )
	nfsv4? (
		>=dev-libs/libevent-1.0b
		>=net-libs/libnfsidmap-0.21-r1
		kerberos? (
			>=net-libs/libtirpc-0.2.4-r1[kerberos]
			app-crypt/mit-krb5
		)
		nfsidmap? (
			>=net-libs/libnfsidmap-0.24
			sys-apps/keyutils
		)
	)
	nfsv41? (
		sys-fs/lvm2
	)
	selinux? (
		sec-policy/selinux-rpc
		sec-policy/selinux-rpcbind
	)
	uuid? ( sys-apps/util-linux )"
RDEPEND="${DEPEND_COMMON} !net-nds/portmap"
DEPEND="${DEPEND_COMMON}
	virtual/pkgconfig"

src_prepare() {
	epatch "${FILESDIR}"/${PN}-1.1.4-mtab-sym.patch
	epatch "${FILESDIR}"/${PN}-1.2.8-cross-build.patch

	sed \
		-e "/^sbindir/s:= := \"${EPREFIX}\":g" \
		-i utils/*/Makefile.am || die

	eautoreconf
}

src_configure() {
	export libsqlite3_cv_is_recent=yes # Our DEPEND forces this.
	export ac_cv_header_keyutils_h=$(usex nfsidmap)
	econf \
		--with-statedir="${EPREFIX}"/var/lib/nfs \
		--enable-tirpc \
		--with-tirpcinclude="${EPREFIX}"/usr/include/tirpc/ \
		$(use_enable libmount libmount-mount) \
		$(use_with tcpd tcp-wrappers) \
		$(use_enable nfsdcld nfsdcltrack) \
		$(use_enable nfsv4) \
		$(use_enable nfsv41) \
		$(use_enable ipv6) \
		$(use_enable caps) \
		$(use_enable uuid) \
		$(use_enable kerberos gss) \
		--without-gssglue
}

src_compile(){
	# remove compiled files bundled in the tarball
	emake clean
	default
}

src_install() {
	default
	rm linux-nfs/Makefile* || die
	dodoc -r linux-nfs README

	# Don't overwrite existing xtab/etab, install the original
	# versions somewhere safe...  more info in pkg_postinst
	keepdir /var/lib/nfs/{,sm,sm.bak}
	mv "${ED}"/var/lib "${ED}"/usr/$(get_libdir) || die

	# Install some client-side binaries in /sbin
	dodir /sbin
	mv "${ED}"/usr/sbin/rpc.statd "${ED}"/sbin/ || die

	if use nfsv4 && use nfsidmap ; then
		# Install a config file for idmappers in newer kernels. #415625
		insinto /etc/request-key.d
		echo 'create id_resolver * * /usr/sbin/nfsidmap -t 600 %k %d' > id_resolver.conf
		doins id_resolver.conf
	fi

	systemd_dotmpfilesd "${FILESDIR}"/nfs-utils.conf
	systemd_dounit "${FILESDIR}"/nfsd.service
	systemd_dounit "${FILESDIR}"/rpc-statd.service
	systemd_dounit "${FILESDIR}"/rpc-mountd.service
	systemd_dounit "${FILESDIR}"/rpc-idmapd.service
	systemd_dounit "${FILESDIR}"/{proc-fs-nfsd,var-lib-nfs-rpc_pipefs}.mount
	use nfsv4 && use kerberos && systemd_dounit "${FILESDIR}"/rpc-{gssd,svcgssd}.service
}

pkg_postinst() {
	# Install default xtab and friends if there's none existing.  In
	# src_install we put them in /usr/lib/nfs for safe-keeping, but
	# the daemons actually use the files in /var/lib/nfs.  #30486
	local f
	mkdir -p "${EROOT}"/var/lib/nfs #368505
	for f in "${EROOT}"/usr/$(get_libdir)/nfs/*; do
		[[ -e ${EROOT}/var/lib/nfs/${f##*/} ]] && continue
		einfo "Copying default ${f##*/} from ${EPREFIX}/usr/$(get_libdir)/nfs to ${EPREFIX}/var/lib/nfs"
		cp -pPR "${f}" "${EROOT}"/var/lib/nfs/
	done
}
