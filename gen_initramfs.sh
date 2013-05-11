#!/bin/bash
# $Id$

CPIO_ARGS="--quiet -o -H newc"

# The copy_binaries function is explicitly released under the CC0 license to
# encourage wide adoption and re-use.  That means:
# - You may use the code of copy_binaries() as CC0 outside of genkernel
# - Contributions to this function are licensed under CC0 as well.
# - If you change it outside of genkernel, please consider sending your
#   modifications back to genkernel@gentoo.org.
#
# On a side note: "Both public domain works and the simple license provided by
#                  CC0 are compatible with the GNU GPL."
#                 (from https://www.gnu.org/licenses/license-list.html#CC0)
#
# Written by: 
# - Sebastian Pipping <sebastian@pipping.org> (error checking)
# - Robin H. Johnson <robbat2@gentoo.org> (complete rewrite)
# - Richard Yao <ryao@cs.stonybrook.edu> (original concept)
# Usage:
# copy_binaries DESTDIR BINARIES...
copy_binaries() {
	local destdir=$1
	shift

	for binary in "$@"; do
		[[ -e "${binary}" ]] \
				|| gen_die "Binary ${binary} could not be found"

		if LC_ALL=C lddtree "${binary}" 2>&1 | fgrep -q 'not found'; then
			gen_die "Binary ${binary} is linked to missing libraries and may need to be re-built"
		fi
	done
	# This must be OUTSIDE the for loop, we only want to run lddtree etc ONCE.
	# lddtree does not have the -V (version) nor the -l (list) options prior to version 1.18
	(
	if lddtree -V > /dev/null 2>&1 ; then
		lddtree -l "$@"
	else
		lddtree "$@" \
			| tr ')(' '\n' \
			| awk  '/=>/{ if($3 ~ /^\//){print $3}}'
	fi ) \
			| sort \
			| uniq \
			| cpio -p --make-directories --dereference --quiet "${destdir}" \
			|| gen_die "Binary ${f} or some of its library dependencies could not be copied"
}

log_future_cpio_content() {
	if [[ "${LOGLEVEL}" -gt 1 ]]; then
		echo =================================================================
		echo "About to add these files from '${PWD}' to cpio archive:"
		find . | xargs ls -ald
		echo =================================================================
	fi
}

append_base_layout() {
	if [ -d "${TEMP}/initramfs-base-temp" ]
	then
		rm -rf "${TEMP}/initramfs-base-temp" > /dev/null
	fi

	mkdir -p ${TEMP}/initramfs-base-temp/dev/shm
	mkdir -p ${TEMP}/initramfs-base-temp/bin
	mkdir -p ${TEMP}/initramfs-base-temp/etc
	mkdir -p ${TEMP}/initramfs-base-temp/usr
	mkdir -p ${TEMP}/initramfs-base-temp/lib
	mkdir -p ${TEMP}/initramfs-base-temp/mnt
	mkdir -p ${TEMP}/initramfs-base-temp/run
	mkdir -p ${TEMP}/initramfs-base-temp/sbin
	mkdir -p ${TEMP}/initramfs-base-temp/proc
	mkdir -p ${TEMP}/initramfs-base-temp/temp
	mkdir -p ${TEMP}/initramfs-base-temp/tmp
	mkdir -p ${TEMP}/initramfs-base-temp/sys
	mkdir -p ${TEMP}/initramfs-temp/.initrd
	mkdir -p ${TEMP}/initramfs-base-temp/var/lock/dmraid
	mkdir -p ${TEMP}/initramfs-base-temp/sbin
	mkdir -p ${TEMP}/initramfs-base-temp/usr/bin
	mkdir -p ${TEMP}/initramfs-base-temp/usr/sbin
	mkdir -p ${TEMP}/initramfs-base-temp/usr/share
	mkdir -p ${TEMP}/initramfs-base-temp/usr/lib
	ln -s  lib  ${TEMP}/initramfs-base-temp/lib64
	ln -s  lib  ${TEMP}/initramfs-base-temp/usr/lib64

	echo "/dev/ram0     /           ext2    defaults	0 0" > ${TEMP}/initramfs-base-temp/etc/fstab
	echo "proc          /proc       proc    defaults    0 0" >> ${TEMP}/initramfs-base-temp/etc/fstab

	cd ${TEMP}/initramfs-base-temp/dev
	mknod -m 660 console c 5 1
	mknod -m 660 null c 1 3
	mknod -m 660 zero c 1 5
	mknod -m 600 tty0 c 4 0
	mknod -m 600 tty1 c 4 1
	mknod -m 600 ttyS0 c 4 64

	date -u '+%Y%m%d-%H%M%S' > ${TEMP}/initramfs-base-temp/etc/build_date
	echo "Genkernel $GK_V" > ${TEMP}/initramfs-base-temp/etc/build_id

	cd "${TEMP}/initramfs-base-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing baselayout cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-base-temp" > /dev/null
}

append_busybox() {
	if [ -d "${TEMP}/initramfs-busybox-temp" ]
	then
		rm -rf "${TEMP}/initramfs-busybox-temp" > /dev/null
	fi

	mkdir -p "${TEMP}/initramfs-busybox-temp/bin/" 
	tar -xjf "${BUSYBOX_BINCACHE}" -C "${TEMP}/initramfs-busybox-temp/bin" busybox ||
		gen_die 'Could not extract busybox bincache!'
	chmod +x "${TEMP}/initramfs-busybox-temp/bin/busybox"

	mkdir -p "${TEMP}/initramfs-busybox-temp/usr/share/udhcpc/"
	cp "${GK_SHARE}/defaults/udhcpc.scripts" ${TEMP}/initramfs-busybox-temp/usr/share/udhcpc/default.script
	chmod +x "${TEMP}/initramfs-busybox-temp/usr/share/udhcpc/default.script"

	# Set up a few default symlinks
	local default_applets="[ ash sh mount uname ls echo cut cat flock stty"
	default_applets+=" readlink"
	for i in ${BUSYBOX_APPLETS:-${default_applets}}; do
		rm -f ${TEMP}/initramfs-busybox-temp/bin/$i
		ln -s busybox ${TEMP}/initramfs-busybox-temp/bin/$i ||
			gen_die "Busybox error: could not link ${i}!"
	done

	local mod_applets="sbin/modprobe sbin/insmod sbin/rmmod bin/lsmod"
	local dir=
	local name=
	for i in ${mod_applets}; do
		dir=$(dirname $i)
		name=$(basename $i)
		rm -f ${TEMP}/initramfs-busybox-temp/$dir/$name
		mkdir -p ${TEMP}/initramfs-busybox-temp/$dir ||
			gen_die "Busybox error: could not create dir: $dir"
		ln -s ../bin/busybox ${TEMP}/initramfs-busybox-temp/$dir/$name ||
			gen_die "Busybox error: could not link ${i}!"
	done

	cd "${TEMP}/initramfs-busybox-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing busybox cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-busybox-temp" > /dev/null
}

append_e2fsprogs(){
	if [ -d "${TEMP}"/initramfs-e2fsprogs-temp ]
	then
		rm -r "${TEMP}"/initramfs-e2fsprogs-temp
	fi

	cd "${TEMP}" \
			|| gen_die "cd '${TEMP}' failed"
	mkdir -p initramfs-e2fsprogs-temp
	copy_binaries "${TEMP}"/initramfs-e2fsprogs-temp/ /sbin/{e2fsck,mke2fs}

	cd "${TEMP}"/initramfs-e2fsprogs-temp \
			|| gen_die "cd '${TEMP}/initramfs-e2fsprogs-temp' failed"
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}"
	rm -rf "${TEMP}"/initramfs-e2fsprogs-temp > /dev/null
}

append_blkid(){
	if [ -d "${TEMP}/initramfs-blkid-temp" ]
	then
		rm -r "${TEMP}/initramfs-blkid-temp/"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-blkid-temp/"

	if [[ "${DISKLABEL}" = "1" ]]; then
		copy_binaries "${TEMP}"/initramfs-blkid-temp/ /sbin/blkid
	fi

	cd "${TEMP}/initramfs-blkid-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing blkid cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-blkid-temp" > /dev/null
}

append_multipath(){
	if [ -d "${TEMP}/initramfs-multipath-temp" ]
	then
		rm -r "${TEMP}/initramfs-multipath-temp"
	fi
	print_info 1 '	Multipath support being added'
	mkdir -p "${TEMP}"/initramfs-multipath-temp/{bin,etc,sbin,lib}/

	# Copy files
	copy_binaries "${TEMP}/initramfs-multipath-temp" \
		/bin/mountpoint \
		/sbin/{multipath,kpartx,mpath_prio_*,devmap_name,dmsetup} \
		/{lib,lib64}/{udev/scsi_id,multipath/*so} 

	if [ -x /sbin/multipath ]
	then
		cp /etc/multipath.conf "${TEMP}/initramfs-multipath-temp/etc/" || gen_die 'could not copy /etc/multipath.conf please check this'
	fi
	# /etc/scsi_id.config does not exist in newer udevs
	# copy it optionally.
	if [ -x /sbin/scsi_id -a -f /etc/scsi_id.config ]
	then
		cp /etc/scsi_id.config "${TEMP}/initramfs-multipath-temp/etc/" || gen_die 'could not copy scsi_id.config'
	fi
	cd "${TEMP}/initramfs-multipath-temp"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing multipath cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-multipath-temp/"
}

append_dmraid(){
	if [ -d "${TEMP}/initramfs-dmraid-temp" ]
	then
		rm -r "${TEMP}/initramfs-dmraid-temp/"
	fi
	print_info 1 'DMRAID: Adding support (copying binaries from system)...'

	mkdir -p "${TEMP}/initramfs-dmraid-temp/sbin"

	copy_binaries "${TEMP}/initramfs-dmraid-temp" \
		/usr/sbin/dmraid /usr/sbin/dmevent_tool

	cd "${TEMP}/initramfs-dmraid-temp"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing dmraid cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-dmraid-temp/"
}

append_iscsi(){
	if [ -d "${TEMP}/initramfs-iscsi-temp" ]
	then
		rm -r "${TEMP}/initramfs-iscsi-temp/"
	fi
	print_info 1 'iSCSI: Adding support (copying binaries from system)...'

	mkdir -p "${TEMP}/initramfs-iscsi-temp/usr/sbin/"

	copy_binaries /usr/sbin/iscsistart

	cd "${TEMP}/initramfs-iscsi-temp"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing iscsi cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-iscsi-temp/"
}

append_lvm(){
	if [ -d "${TEMP}/initramfs-lvm-temp" ]
	then
		rm -r "${TEMP}/initramfs-lvm-temp/"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-lvm-temp"/{bin,sbin}
	mkdir -p "${TEMP}/initramfs-lvm-temp/etc/lvm/"
	print_info 1 'LVM: Adding support (copying binaries from system)...'

	udev_files=( $(qlist -e sys-fs/lvm2:0 | grep ^/lib/udev/rules.d) )
	for f in "${udev_files[@]}"; do
		[ -f "${f}" ] || gen_die "append_lvm: not a file: ${f}"
		mkdir -p "${TEMP}/initramfs-lvm-temp"/$(dirname "${f}") || \
			gen_die "cannot create rules.d directory"
		cp "${f}" "${TEMP}/initramfs-lvm-temp/${f}" || \
			gen_die "cannot copy ${f} from system"
	done

	copy_binaries "${TEMP}/initramfs-lvm-temp" \
		/sbin/lvm /sbin/dmsetup

	if [ -x /sbin/lvm ]
	then
		cp /etc/lvm/lvm.conf "${TEMP}/initramfs-lvm-temp/etc/lvm/" ||
			gen_die 'Could not copy over lvm.conf!'
	fi
	cd "${TEMP}/initramfs-lvm-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing lvm cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-lvm-temp/"
}

append_mdadm(){
	if [ -d "${TEMP}/initramfs-mdadm-temp" ]
	then
		rm -r "${TEMP}/initramfs-mdadm-temp/"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-mdadm-temp/etc/"
	mkdir -p "${TEMP}/initramfs-mdadm-temp/sbin/"

	copy_binaries "${TEMP}/initramfs-mdadm-temp" \
		/sbin/mdadm /sbin/mdmon /sbin/mdassemble

	if [ -n "${MDADM_CONFIG}" ]
	then
		if [ -f "${MDADM_CONFIG}" ]
		then
			cp -a "${MDADM_CONFIG}" \
				"${TEMP}/initramfs-mdadm-temp/etc/mdadm.conf" \
			|| gen_die "Could not copy mdadm.conf!"
		else
			gen_die 'sl${MDADM_CONFIG} does not exist!'
		fi
	else
		print_info 1 '         MDADM: Skipping inclusion of mdadm.conf'
	fi

	cd "${TEMP}/initramfs-mdadm-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing mdadm cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-mdadm-temp" > /dev/null
}

append_zfs(){
	if [ -d "${TEMP}/initramfs-zfs-temp" ]
	then
		rm -r "${TEMP}/initramfs-zfs-temp"
	fi

	mkdir -p "${TEMP}/initramfs-zfs-temp/etc/zfs/"

	# Copy files to /etc/zfs
	for i in /etc/zfs/{zdev.conf,zpool.cache}
	do
		cp -a "${i}" "${TEMP}/initramfs-zfs-temp/etc/zfs" \
			|| print_warning 1 "Could not copy file ${i} for ZFS"
	done

	# Copy binaries
	copy_binaries "${TEMP}/initramfs-zfs-temp" /sbin/{mount.zfs,zfs,zpool}

	cd "${TEMP}/initramfs-zfs-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing zfs cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-zfs-temp" > /dev/null
}

append_splash(){
	splash_geninitramfs=`which splash_geninitramfs 2>/dev/null`
	if [ -x "${splash_geninitramfs}" ]
	then
		[ -z "${SPLASH_THEME}" ] && [ -e /etc/conf.d/splash ] && source /etc/conf.d/splash
		[ -z "${SPLASH_THEME}" ] && SPLASH_THEME=default
		print_info 1 "  >> Installing splash [ using the ${SPLASH_THEME} theme ]..."
		if [ -d "${TEMP}/initramfs-splash-temp" ]
		then
			rm -r "${TEMP}/initramfs-splash-temp/"
		fi
		mkdir -p "${TEMP}/initramfs-splash-temp"
		cd /
		local tmp=""
		[ -n "${SPLASH_RES}" ] && tmp="-r ${SPLASH_RES}"
		splash_geninitramfs -c "${TEMP}/initramfs-splash-temp" ${tmp} ${SPLASH_THEME} || gen_die "Could not build splash cpio archive"
		if [ -e "/usr/share/splashutils/initrd.splash" ]; then
			mkdir -p "${TEMP}/initramfs-splash-temp/etc"
			cp -f "/usr/share/splashutils/initrd.splash" "${TEMP}/initramfs-splash-temp/etc"
		fi
		cd "${TEMP}/initramfs-splash-temp/"
		log_future_cpio_content
		find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing splash cpio"
		cd "${TEMP}"
		rm -r "${TEMP}/initramfs-splash-temp/"
	else
		print_warning 1 '               >> No splash detected; skipping!'
	fi
}

append_plymouth() {
	[ -z "${PLYMOUTH_THEME}" ] && \
		PLYMOUTH_THEME=$(plymouth-set-default-theme)
	[ -z "${PLYMOUTH_THEME}" ] && PLYMOUTH_THEME=text

	if [ -d "${TEMP}/initramfs-ply-temp" ]
	then
		rm -r "${TEMP}/initramfs-ply-temp"
	fi

	mkdir -p "${TEMP}/initramfs-ply-temp/usr/share/plymouth/themes"
	mkdir -p "${TEMP}/initramfs-ply-temp/etc/plymouth"
	mkdir -p "${TEMP}/initramfs-ply-temp/"{bin,sbin}

	cd "${TEMP}/initramfs-ply-temp"

	local theme_dir="/usr/share/plymouth/themes"
	local t=

	local p=
	local ply="${theme_dir}/${PLYMOUTH_THEME}/${PLYMOUTH_THEME}.plymouth"
	local plugin=$(grep "^ModuleName=" "${ply}" | cut -d= -f2-)
	local plugin_binary=
	if [ -n "${plugin}" ]
	then
		plugin_binary="$(plymouth --get-splash-plugin-path)/${plugin}.so"
	fi

	print_info 1 "  >> Installing plymouth [ using the ${PLYMOUTH_THEME} theme and plugin: \"${plugin}\" ]..."

	for t in text details ${PLYMOUTH_THEME}; do
		cp -R "${theme_dir}/${t}" \
			"${TEMP}/initramfs-ply-temp${theme_dir}/" || \
			gen_die "cannot copy ${theme_dir}/details"
	done
	cp /usr/share/plymouth/{bizcom.png,plymouthd.defaults} \
		"${TEMP}/initramfs-ply-temp/usr/share/plymouth/" || \
			gen_die "cannot copy bizcom.png and plymouthd.defaults"

	# Do both config setup
	echo -en "[Daemon]\nTheme=${PLYMOUTH_THEME}\n" > \
		"${TEMP}/initramfs-ply-temp/etc/plymouth/plymouthd.conf" || \
		gen_die "Cannot create /etc/plymouth/plymouthd.conf"
	ln -sf "${PLYMOUTH_THEME}/${PLYMOUTH_THEME}.plymouth" \
		"${TEMP}/initramfs-ply-temp${theme_dir}/default.plymouth" || \
		gen_die "cannot setup the default plymouth theme"

	local libs=(
		"/lib*/libply-splash-core.so.*"
		"/usr/lib*/libply-splash-graphics.so.*"
		"/usr/lib*/plymouth/text.so"
		"/usr/lib*/plymouth/details.so"
		"/usr/lib*/plymouth/renderers/frame-buffer.so"
		"/usr/lib*/plymouth/renderers/drm.so"
		"${plugin_binary}"
	)
	# lib64 must take the precedence or all the cpio archive
	# symlinks will be fubared
	local slib= lib= final_lib= final_libs=()
	for slib in "${libs[@]}"; do
		lib=( ${slib} )
		final_lib="${lib[0]}"
		final_libs+=( "${final_lib}" )
	done

	copy_binaries "${TEMP}/initramfs-ply-temp" \
		/sbin/plymouthd /bin/plymouth \
		"${final_libs[@]}" || gen_die "cannot copy plymouth"

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "appending plymouth to cpio"

	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-ply-temp/"
}

append_overlay(){
	cd ${INITRAMFS_OVERLAY}
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing overlay cpio"
}

append_luks() {
	local _luks_error_format="LUKS support cannot be included: %s.  Please emerge sys-fs/cryptsetup[static]."
	local _luks_source=/sbin/cryptsetup
	local _luks_dest=/sbin/cryptsetup

	if [ -d "${TEMP}/initramfs-luks-temp" ]
	then
		rm -r "${TEMP}/initramfs-luks-temp/"
	fi

	mkdir -p "${TEMP}/initramfs-luks-temp/lib/luks/"
	mkdir -p "${TEMP}/initramfs-luks-temp/sbin"
	cd "${TEMP}/initramfs-luks-temp"

	if isTrue ${LUKS}
	then
		[ -x "${_luks_source}" ] \
				|| gen_die "$(printf "${_luks_error_format}" "no file ${_luks_source}")"

		print_info 1 "Including LUKS support"
		copy_binaries "${TEMP}/initramfs-luks-temp/" /sbin/cryptsetup
	fi

	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "appending cryptsetup to cpio"

	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-luks-temp/"
}

append_firmware() {
	if [ -z "${FIRMWARE_FILES}" -a ! -d "${FIRMWARE_DIR}" ]
	then
		gen_die "specified firmware directory (${FIRMWARE_DIR}) does not exist"
	fi
	if [ -d "${TEMP}/initramfs-firmware-temp" ]
	then
		rm -r "${TEMP}/initramfs-firmware-temp/"
	fi
	mkdir -p "${TEMP}/initramfs-firmware-temp/lib/firmware"
	cd "${TEMP}/initramfs-firmware-temp"
	if [ -n "${FIRMWARE_FILES}" ]
	then
		OLD_IFS=$IFS
		IFS=","
		for i in ${FIRMWARE_FILES}
		do
			cp -L "${i}" ${TEMP}/initramfs-firmware-temp/lib/firmware/
		done
		IFS=$OLD_IFS
	else
		cp -a "${FIRMWARE_DIR}"/* ${TEMP}/initramfs-firmware-temp/lib/firmware/
	fi
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
		|| gen_die "appending firmware to cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-firmware-temp/"
}

append_gpg() {
	if [ -d "${TEMP}/initramfs-gpg-temp" ]
	then
		rm -r "${TEMP}/initramfs-gpg-temp"
	fi
	mkdir -p "${TEMP}/initramfs-gpg-temp/sbin/"

	print_info 1 "Including GPG support"
	copy_binaries "${TEMP}/initramfs-gpg-temp" /sbin/gpg

	cd "${TEMP}/initramfs-gpg-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing gpg cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-gpg-temp" > /dev/null
}

append_udev() {
	if [ -d "${TEMP}/initramfs-udev-temp" ]
	then
		rm -r "${TEMP}/initramfs-udev-temp"
	fi

	udev_files="
		/lib/udev/rules.d/50-udev-default.rules
		/lib/udev/rules.d/60-persistent-storage.rules
		/lib/udev/rules.d/80-drivers.rules
		/etc/udev/udev.conf
	"
	udev_maybe_files="
		/lib/udev/rules.d/99-systemd.rules
	"
	is_maybe=0
	for f in ${udev_files} -- ${udev_maybe_files}; do
		[ "${f}" = "--" ] && {
			is_maybe=1;
			continue;
		}
		mkdir -p "${TEMP}/initramfs-udev-temp"/$(dirname "${f}") || \
			gen_die "cannot create rules.d directory"
		cp "${f}" "${TEMP}/initramfs-udev-temp/${f}"
		if [ "${?}" != "0" ]
		then
			[ "${is_maybe}" = "0" ] && \
				gen_die "cannot copy ${f} from udev"
			[ "${is_maybe}" = "1" ] && \
				print_warning 1 "cannot copy ${f} from udev"
		fi
	done

	# Copy binaries
	copy_binaries "${TEMP}/initramfs-udev-temp" \
		/sbin/udevd /bin/udevadm /lib/udev/scsi_id \
		/lib/udev/ata_id /lib/udev/mtd_probe

	cd "${TEMP}/initramfs-udev-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing udev cpio"
	cd "${TEMP}"
	rm -rf "${TEMP}/initramfs-udev-temp" > /dev/null
}

print_list()
{
	local x
	for x in ${*}
	do
		echo ${x}
	done
}

append_modules() {
	local group
	local group_modules
	local MOD_EXT=".ko"

	print_info 2 "initramfs: >> Searching for modules..."
	if [ "${INSTALL_MOD_PATH}" != '' ]
	then
	  cd ${INSTALL_MOD_PATH}
	else
	  cd /
	fi

	if [ -d "${TEMP}/initramfs-modules-${KV}-temp" ]
	then
		rm -r "${TEMP}/initramfs-modules-${KV}-temp/"
	fi
	mkdir -p "${TEMP}/initramfs-modules-${KV}-temp/lib/modules/${KV}"
	for i in `gen_dep_list`
	do
		mymod=`find ./lib/modules/${KV} -name "${i}${MOD_EXT}" 2>/dev/null| head -n 1 `
		if [ -z "${mymod}" ]
		then
			print_warning 2 "Warning :: ${i}${MOD_EXT} not found; skipping..."
			continue;
		fi

		print_info 2 "initramfs: >> Copying ${i}${MOD_EXT}..."
		cp -ax --parents "${mymod}" "${TEMP}/initramfs-modules-${KV}-temp"
	done

	cp -ax --parents ./lib/modules/${KV}/modules* ${TEMP}/initramfs-modules-${KV}-temp 2>/dev/null

	mkdir -p "${TEMP}/initramfs-modules-${KV}-temp/etc/modules"
	for group_modules in ${!MODULES_*}; do
		group="$(echo $group_modules | cut -d_ -f2 | tr "[:upper:]" "[:lower:]")"
		print_list ${!group_modules} > "${TEMP}/initramfs-modules-${KV}-temp/etc/modules/${group}"
	done
	cd "${TEMP}/initramfs-modules-${KV}-temp/"
	log_future_cpio_content
	find . | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing modules cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-modules-${KV}-temp/"	
}

# check for static linked file with objdump
is_static() {
	LANG="C" LC_ALL="C" objdump -T $1 2>&1 | grep "not a dynamic object" > /dev/null
	return $?
}

append_auxilary() {
	if [ -d "${TEMP}/initramfs-aux-temp" ]
	then
		rm -r "${TEMP}/initramfs-aux-temp/"
	fi
	mkdir -p "${TEMP}/initramfs-aux-temp/etc"
	mkdir -p "${TEMP}/initramfs-aux-temp/sbin"
	if [ -f "${CMD_LINUXRC}" ]
	then
		cp "${CMD_LINUXRC}" "${TEMP}/initramfs-aux-temp/init"
		print_info 2 "        >> Copying user specified linuxrc: ${CMD_LINUXRC} to init"
	else
		if isTrue ${NETBOOT}
		then
			cp "${GK_SHARE}/netboot/linuxrc.x" "${TEMP}/initramfs-aux-temp/init"
		else
			if [ -f "${GK_SHARE}/arch/${ARCH}/linuxrc" ]
			then
				cp "${GK_SHARE}/arch/${ARCH}/linuxrc" "${TEMP}/initramfs-aux-temp/init"
			else
				cp "${GK_SHARE}/defaults/linuxrc" "${TEMP}/initramfs-aux-temp/init"
			fi
		fi
	fi

	# Make sure it's executable
	chmod 0755 "${TEMP}/initramfs-aux-temp/init"

	# Make a symlink to init .. incase we are bundled inside the kernel as one
	# big cpio.
	cd ${TEMP}/initramfs-aux-temp
	ln -s init linuxrc
#	ln ${TEMP}/initramfs-aux-temp/init ${TEMP}/initramfs-aux-temp/linuxrc

	if [ -f "${GK_SHARE}/arch/${ARCH}/initrd.scripts" ]
	then
		cp "${GK_SHARE}/arch/${ARCH}/initrd.scripts" "${TEMP}/initramfs-aux-temp/etc/initrd.scripts"
	else
		cp "${GK_SHARE}/defaults/initrd.scripts" "${TEMP}/initramfs-aux-temp/etc/initrd.scripts"
	fi

	if [ -f "${GK_SHARE}/arch/${ARCH}/initrd.defaults" ]
	then
		cp "${GK_SHARE}/arch/${ARCH}/initrd.defaults" "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	else
		cp "${GK_SHARE}/defaults/initrd.defaults" "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	fi

	if [ -n "${REAL_ROOT}" ]
	then
		sed -i "s:^REAL_ROOT=.*$:REAL_ROOT='${REAL_ROOT}':" "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	fi

	echo -n 'HWOPTS="$HWOPTS ' >> "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	for group_modules in ${!MODULES_*}; do
		group="$(echo $group_modules | cut -d_ -f2 | tr "[:upper:]" "[:lower:]")"
		echo -n "${group} " >> "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	done
	echo '"' >> "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"

	if isTrue $CMD_DOKEYMAPAUTO
	then
		echo 'MY_HWOPTS="${MY_HWOPTS} keymap"' >> ${TEMP}/initramfs-aux-temp/etc/initrd.defaults
	fi
	if isTrue $CMD_KEYMAP
	then
		print_info 1 "        >> Copying keymaps"
		mkdir -p "${TEMP}/initramfs-aux-temp/lib/"
		cp -R "${GK_SHARE}/defaults/keymaps" "${TEMP}/initramfs-aux-temp/lib/" \
				|| gen_die "Error while copying keymaps"
	fi

	cd ${TEMP}/initramfs-aux-temp/sbin && ln -s ../init init
	cd ${TEMP}
	chmod +x "${TEMP}/initramfs-aux-temp/init"
	chmod +x "${TEMP}/initramfs-aux-temp/etc/initrd.scripts"
	chmod +x "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"

	if isTrue ${NETBOOT}
	then
		cd "${GK_SHARE}/netboot/misc"
		cp -pPRf * "${TEMP}/initramfs-aux-temp/"
	fi

	cd "${TEMP}/initramfs-aux-temp/"
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing auxilary cpio"
	cd "${TEMP}"
	rm -r "${TEMP}/initramfs-aux-temp/"
}

append_data() {
	local name=$1 var=$2
	local func="append_${name}"

	[ $# -eq 0 ] && gen_die "append_data() called with zero arguments"
	if [ $# -eq 1 ] || isTrue ${var}
	then
	    print_info 1 "        >> Appending ${name} cpio data..."
	    ${func} || gen_die "${func}() failed"
	fi
}

create_initramfs() {
	local compress_ext=""
	print_info 1 "initramfs: >> Initializing..."

	# Create empty cpio
	CPIO="${TMPDIR}/initramfs-${KV}"
	echo | cpio ${CPIO_ARGS} -F "${CPIO}" 2>/dev/null \
		|| gen_die "Could not create empty cpio at ${CPIO}"

	append_data 'base_layout'
	append_data 'udev' "${UDEV}"
	append_data 'auxilary' "${BUSYBOX}"
	append_data 'busybox' "${BUSYBOX}"
	isTrue "${CMD_E2FSPROGS}" && append_data 'e2fsprogs'
	append_data 'lvm' "${LVM}"
	append_data 'dmraid' "${DMRAID}"
	append_data 'iscsi' "${ISCSI}"
	append_data 'mdadm' "${MDADM}"
	append_data 'luks' "${LUKS}"
	append_data 'multipath' "${MULTIPATH}"
	append_data 'gpg' "${GPG}"

	if [ "${RAMDISKMODULES}" = '1' ]
	then
		append_data 'modules'
	else
		print_info 1 "initramfs: Not copying modules..."
	fi

	append_data 'zfs' "${ZFS}"

	append_data 'blkid' "${DISKLABEL}"

	append_data 'splash' "${SPLASH}"

	append_data 'plymouth' "${PLYMOUTH}"

	if isTrue "${FIRMWARE}" && [ -n "${FIRMWARE_DIR}" ]
	then
		append_data 'firmware'
	fi

	# This should always be appended last
	if [ "${INITRAMFS_OVERLAY}" != '' ]
	then
		append_data 'overlay'
	fi

	if isTrue "${INTEGRATED_INITRAMFS}"
	then
		# Explicitly do not compress if we are integrating into the kernel.
		# The kernel will do a better job of it than us.
		mv ${TMPDIR}/initramfs-${KV} ${TMPDIR}/initramfs-${KV}.cpio
		sed -i '/^.*CONFIG_INITRAMFS_SOURCE=.*$/d' ${KERNEL_DIR}/.config
		compress_config='INITRAMFS_COMPRESSION_NONE'
		case ${compress_ext} in
			gz)  compress_config='INITRAMFS_COMPRESSION_GZIP' ;;
			bz2) compress_config='INITRAMFS_COMPRESSION_BZIP2' ;;
			lzma) compress_config='INITRAMFS_COMPRESSION_LZMA' ;;
			xz) compress_config='INITRAMFS_COMPRESSION_XZ' ;;
			lzo) compress_config='INITRAMFS_COMPRESSION_LZO' ;;
			*) compress_config='INITRAMFS_COMPRESSION_NONE' ;;
		esac
		# All N default except XZ, so there it gets used if the kernel does
		# compression on it's own.
		cat >>${KERNEL_DIR}/.config	<<-EOF
		CONFIG_INITRAMFS_SOURCE="${TMPDIR}/initramfs-${KV}.cpio${compress_ext}"
		CONFIG_INITRAMFS_ROOT_UID=0
		CONFIG_INITRAMFS_ROOT_GID=0
		CONFIG_INITRAMFS_COMPRESSION_NONE=n
		CONFIG_INITRAMFS_COMPRESSION_GZIP=n
		CONFIG_INITRAMFS_COMPRESSION_BZIP2=n
		CONFIG_INITRAMFS_COMPRESSION_LZMA=n
		CONFIG_INITRAMFS_COMPRESSION_XZ=y
		CONFIG_INITRAMFS_COMPRESSION_LZO=n
		CONFIG_${compress_config}=y
		EOF
	else
		if isTrue "${COMPRESS_INITRD}"
		then
			# NOTE:  We do not work with ${KERNEL_CONFIG} here, since things like
			#        "make oldconfig" or --noclean could be in effect.
			if [ -f "${KERNEL_DIR}"/.config ]; then
				local ACTUAL_KERNEL_CONFIG="${KERNEL_DIR}"/.config
			else
				local ACTUAL_KERNEL_CONFIG="${KERNEL_CONFIG}"
			fi

			if [[ "$(file --brief --mime-type "${ACTUAL_KERNEL_CONFIG}")" == application/x-gzip ]]; then
				# Support --kernel-config=/proc/config.gz, mainly
				local CONFGREP=zgrep
			else
				local CONFGREP=grep
			fi

			cmd_xz=$(type -p xz)
			cmd_lzma=$(type -p lzma)
			cmd_bzip2=$(type -p bzip2)
			cmd_gzip=$(type -p gzip)
			cmd_lzop=$(type -p lzop)
			pkg_xz='app-arch/xz-utils'
			pkg_lzma='app-arch/xz-utils'
			pkg_bzip2='app-arch/bzip2'
			pkg_gzip='app-arch/gzip'
			pkg_lzop='app-arch/lzop'
			local compression
			case ${COMPRESS_INITRD_TYPE} in
				xz|lzma|bzip2|gzip|lzop) compression=${COMPRESS_INITRD_TYPE} ;;
				lzo) compression=lzop ;;
				best|fastest)
					for tuple in \
							'CONFIG_RD_XZ    cmd_xz    xz' \
							'CONFIG_RD_LZMA  cmd_lzma  lzma' \
							'CONFIG_RD_BZIP2 cmd_bzip2 bzip2' \
							'CONFIG_RD_GZIP  cmd_gzip  gzip' \
							'CONFIG_RD_LZO   cmd_lzop  lzop'; do
						set -- ${tuple}
						kernel_option=$1
						cmd_variable_name=$2
						if ${CONFGREP} -q "^${kernel_option}=y" "${ACTUAL_KERNEL_CONFIG}" && test -n "${!cmd_variable_name}" ; then
							compression=$3
							[[ ${COMPRESS_INITRD_TYPE} == best ]] && break
						fi
					done
					[[ -z "${compression}" ]] && gen_die "None of the initramfs compression methods we tried are supported by your kernel (config file \"${ACTUAL_KERNEL_CONFIG}\"), strange!?"
					;;
				*)
					gen_die "Compression '${COMPRESS_INITRD_TYPE}' unknown"
					;;
			esac

			# Check for actual availability
			cmd_variable_name=cmd_${compression}
			pkg_variable_name=pkg_${compression}
			[[ -z "${!cmd_variable_name}" ]] && gen_die "Compression '${compression}' is not available. Please install package '${!pkg_variable_name}'."

			case $compression in
				xz) compress_ext='.xz' compress_cmd="${cmd_xz} -e --check=none -z -f -9" ;;
				lzma) compress_ext='.lzma' compress_cmd="${cmd_lzma} -z -f -9" ;;
				bzip2) compress_ext='.bz2' compress_cmd="${cmd_bzip2} -z -f -9" ;;
				gzip) compress_ext='.gz' compress_cmd="${cmd_gzip} -f -9" ;;
				lzop) compress_ext='.lzo' compress_cmd="${cmd_lzop} -f -9" ;;
			esac
	
			if [ -n "${compression}" ]; then
				print_info 1 "        >> Compressing cpio data (${compress_ext})..."
				${compress_cmd} "${CPIO}" || gen_die "Compression (${compress_cmd}) failed"
				mv -f "${CPIO}${compress_ext}" "${CPIO}" || gen_die "Rename failed"
			else
				print_info 1 "        >> Not compressing cpio data ..."
			fi
		fi
	fi

	if isTrue "${CMD_INSTALL}"
	then
		if ! isTrue "${INTEGRATED_INITRAMFS}"
		then
			copy_image_with_preserve "initramfs" \
				"${TMPDIR}/initramfs-${KV}" \
				"initramfs-${KNAME}-${ARCH}-${KV}"
		fi
	fi
}
