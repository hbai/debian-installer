#!/usr/bin/make -f
#
# Debian Installer system makefile.
# Copyright 2001-2003 by Joey Hess <joeyh@debian.org> and the d-i team.
# Licensed under the terms of the GPL.
#
# This makefile builds a debian-installer system and bootable images from 
# a collection of udebs which it downloads from a Debian archive. See
# README for details.

DEB_HOST_ARCH = $(shell dpkg-architecture -qDEB_HOST_ARCH)
DEB_HOST_GNU_CPU = $(shell dpkg-architecture -qDEB_HOST_GNU_CPU)
DEB_HOST_GNU_SYSTEM = $(shell dpkg-architecture -qDEB_HOST_GNU_SYSTEM)

# Include main config
include config/main

# Include arch configs
include config/arch/$(DEB_HOST_GNU_SYSTEM)
include config/arch/$(DEB_HOST_GNU_SYSTEM)-$(DEB_HOST_GNU_CPU)

# Include type configs
-include config/type/$(TYPE)
-include config/type/$(TYPE)-$(DEB_HOST_GNU_SYSTEM)
-include config/type/$(TYPE)-$(DEB_HOST_ARCH)

# Include directory config
include config/dir

# Local config override.
-include config/local

# Add to PATH so dpkg will always work, and so local programs will be found.
PATH:=$(PATH):/usr/sbin:/sbin:.

# All these options make apt read the right sources list, and use APTDIR for
# everything so it need not run as root.
CWD:=$(shell pwd)/
APT_GET=apt-get --assume-yes \
	-o Dir::Etc::sourcelist=$(CWD)$(SOURCES_LIST) \
	-o Dir::State=$(CWD)$(APTDIR)/state \
	-o Debug::NoLocking=true \
	-o Dir::Cache=$(CWD)$(APTDIR)/cache

# Get the list of udebs to install.
UDEBS = $(shell ./pkg-list $(TYPE) $(KERNEL_FLAVOUR) $(KERNELIMAGEVERSION)) $(EXTRAS)

ifeq ($(TYPE),floppy)
# List of additional udebs for driver floppys.
DRIVERFD_UDEBS = \
	$(shell for target in $(EXTRA_FLOPPIES) ; do \
		./pkg-list $$target $(KERNEL_FLAVOUR) $(KERNELIMAGEVERSION); \
	done)
endif

# Sanity check TYPE against the list.
ifeq (,$(filter $(TYPE),type $(TYPES_SUPPORTED)))
%:
	@echo "unsupported type"
	@echo "type: $(TYPE)"
	@echo "supported types: $(TYPES_SUPPORTED)"
	@exit 1
endif

# Include arch targets
-include make/arch/$(DEB_HOST_GNU_SYSTEM)
include make/arch/$(DEB_HOST_GNU_SYSTEM)-$(DEB_HOST_GNU_CPU)

build: tree_umount tree $(EXTRA_TARGETS) stats

image: arch-image $(EXTRA_IMAGES) 

tree_mount: tree
	-@sudo /bin/mount -t proc proc $(TREE)/proc
ifndef USERDEVFS
	-@sudo /bin/mount -t devfs dev $(TREE)/dev
else
	-@sudo chroot $(TREE) /usr/bin/update-dev
endif

tree_umount:
ifndef USERDEVFS
	-@if [ -L $(TREE)/dev/fd ] ; then sudo /bin/umount $(TREE)/dev 2>/dev/null ; fi
endif
	-@if [ -L $(TREE)/proc/self ] ; then sudo /bin/umount $(TREE)/proc 2>/dev/null ; fi

demo: tree
	$(MAKE) tree_mount
	-@[ -f questions.dat ] && cp -f questions.dat $(TREE)/var/lib/cdebconf/
	-@sudo chroot $(TREE) bin/sh -c "export DEBCONF_DEBUG=5; /usr/bin/debconf-loadtemplate debian /var/lib/dpkg/info/*.templates; exec /usr/share/debconf/frontend /usr/bin/main-menu"
	$(MAKE) tree_umount

shell: tree
	$(MAKE) tree_mount
	-@sudo chroot $(TREE) bin/sh
	$(MAKE) tree_umount

uml: $(INITRD)
	-linux initrd=$(INITRD) root=/dev/rd/0 ramdisk_size=8192 con=fd:0,fd:1 devfs=mount

demo_clean: tree_umount

clean: demo_clean tmp_mount debian/control
	rm -rf $(TEMP) || sudo rm -rf $(TEMP)
	dh_clean
	rm -f *-stamp
	rm -rf $(UDEBDIR) $(EXTRAUDEBDIR) $(TMP_MNT) debian/build
	rm -rf $(DEST)/$(TYPE)-* $(EXTRA_IMAGES) || sudo rm -rf $(DEST)/$(TYPE)-* $(EXTRA_IMAGES)
	rm -f unifont-reduced-$(TYPE).bdf
	$(foreach NAME,$(KERNELNAME), \
		rm -f $(TEMP)/$(NAME); )

reallyclean: clean
	rm -rf $(APTDIR) $(DEST) $(BASE_TMP) $(SOURCEDIR) $(DEBUGUDEBDIR)
	rm -f diskusage*.txt all-*.utf *.bdf
	rm -f sources.list

# Auto-generate a sources.list.
sources.list:
	( \
	echo "# This file is automatically generated, edit sources.list.local instead."; \
	if [ "$(MIRROR)x" != "x" ]; then \
		echo "deb $(MIRROR) $(SUITE) main/debian-installer"; \
	else \
	cat $(SYSTEM_SOURCES_LIST) | grep ^deb\  |grep -v file:/ | grep -v debian-non-US | grep ' main' | grep -v 'security.debian.org' | \
		awk '{print $$1 " " $$2}' | sed s/\\/*\ *$$/\ $(SUITE)\ main\\/debian-installer/ | uniq; \
	fi; \
	) > sources.list

# Get all required udebs and put in UDEBDIR.
get_udebs: $(TYPE)-get_udebs-stamp
$(TYPE)-get_udebs-stamp: sources.list
	mkdir -p $(APTDIR)/state/lists/partial
	mkdir -p $(APTDIR)/cache/archives/partial
	-$(APT_GET) update
	$(APT_GET) autoclean
	# If there are local udebs, remove them from the list of things to
	# get. Then get all the udebs that are left to get.
	# Note that the trailing blank on the next line is significant. It
	# makes the sed below always work.
	needed="$(UDEBS) $(DRIVERFD_UDEBS) "; \
	for file in `find $(LOCALUDEBDIR) -name "*_*" -printf "%f\n" 2>/dev/null`; do \
		package=`echo $$file | cut -d _ -f 1`; \
		needed=`echo " $$needed " | sed "s/ $$package / /g"`; \
	done; \
	if [ "$(DEBUG)" = y ] ; then \
		mkdir -p $(DEBUGUDEBDIR); \
		cd $(DEBUGUDEBDIR); \
		export DEB_BUILD_OPTIONS="debug"; \
		$(APT_GET) source --build --yes $$needed; \
		cd ..; \
	else \
		echo Need to download : $$needed; \
		if [ -n "$$needed" ]; then \
		$(APT_GET) -dy install $$needed; \
		fi; \
	fi; \

	# Now the udebs are in APTDIR/cache/archives/ and maybe LOCALUDEBDIR
	# or DEBUGUDEBDIR, but there may be other udebs there too besides those
	# we asked for. So link those we asked for to UDEBDIR, renaming them
	# to more useful names. Watch out for duplicates and missing files
	# while doing that.
	rm -rf $(UDEBDIR)
	mkdir -p $(UDEBDIR)
	rm -rf $(EXTRAUDEBDIR)
	mkdir -p $(EXTRAUDEBDIR)
	lnpkg() { \
		local pkg=$$1; local dir=$$2 debdir=$$3; \
		local L1="`echo $$dir/$$pkg\_*`"; \
		local L2="`echo $$L1 | sed -e 's, ,,g'`"; \
		if [ "$$L1" != "$$L2" ]; then \
			echo "Duplicate package $$pkg in $$dir/"; \
			exit 1; \
		fi; \
		if [ -e $$L1 ]; then \
			ln -f $$dir/$$pkg\_* $$debdir/$$pkg.udeb; \
		fi; \
	}; \
	for package in $(UDEBS) ; do \
		lnpkg $$package $(APTDIR)/cache/archives $(UDEBDIR); \
		lnpkg $$package $(LOCALUDEBDIR) $(UDEBDIR); \
		lnpkg $$package $(DEBUGUDEBDIR) $(UDEBDIR); \
		if ! [ -e $(UDEBDIR)/$$package.udeb ]; then \
			echo "Needed $$package not found (looked in $(APTDIR)/cache/archives/, $(LOCALUDEBDIR)/, $(DEBUGUDEBDIR)/)"; \
			exit 1; \
		fi; \
	done ; \
	for package in $(DRIVERFD_UDEBS) ; do \
                lnpkg $$package $(APTDIR)/cache/archives $(EXTRAUDEBDIR); \
		lnpkg $$package $(LOCALUDEBDIR) $(EXTRAUDEBDIR); \
                lnpkg $$package $(DEBUGUDEBDIR) $(EXTRAUDEBDIR); \
                if ! [ -e $(EXTRAUDEBDIR)/$$package.udeb ]; then \
                        echo "Needed $$package not found (looked in $(APTDIR)/cache/archives/, $(LOCALUDEBDIR)/, $(DEBUGUDEBDIR)/)"; \
                        exit 1; \
                fi; \
        done

	touch $(TYPE)-get_udebs-stamp

# Build the installer tree.
tree: $(TYPE)-tree-stamp
$(TYPE)-tree-stamp: $(TYPE)-get_udebs-stamp debian/control
	dh_testroot

	dpkg-checkbuilddeps

	# This build cannot be restarted, because dpkg gets confused.
	rm -rf $(TREE)
	# Set up the basic files [u]dpkg needs.
	mkdir -p $(DPKGDIR)/info
	touch $(DPKGDIR)/status
	# Create a tmp tree
	mkdir -p $(TREE)/tmp
	# Only dpkg needs this stuff, so it can be removed later.
	mkdir -p $(DPKGDIR)/updates/
	touch $(DPKGDIR)/available

	# Unpack the udebs with dpkg. This command must run as root
	# or fakeroot.
	echo -n > diskusage-$(TYPE).txt
	oldsize=0; oldblocks=0; oldcount=0; for udeb in $(UDEBDIR)/*.udeb ; do \
		pkg=`basename $$udeb` ; \
		dpkg $(DPKG_UNPACK_OPTIONS) --root=$(TREE) --unpack $$udeb ; \
		newsize=`du -bs $(TREE) | awk '{print $$1}'` ; \
		newblocks=`du -s $(TREE) | awk '{print $$1}'` ; \
		newcount=`find $(TREE) -type f | wc -l | awk '{print $$1}'` ; \
		usedsize=`echo $$newsize - $$oldsize | bc`; \
		usedblocks=`echo $$newblocks - $$oldblocks | bc`; \
		usedcount=`echo $$newcount - $$oldcount | bc`; \
		version=`dpkg-deb --info $$udeb | grep Version: | awk '{print $$2}'` ; \
		echo " $$usedsize B - $$usedblocks blocks - $$usedcount files used by pkg $$pkg (version $$version)" >>diskusage-$(TYPE).txt;\
		oldsize=$$newsize ; \
		oldblocks=$$newblocks ; \
		oldcount=$$newcount ; \
	done
	sort -n < diskusage-$(TYPE).txt > diskusage-$(TYPE).txt.new && \
		mv diskusage-$(TYPE).txt.new diskusage-$(TYPE).txt

	# Clean up after dpkg.
	rm -rf $(DPKGDIR)/updates
	rm -f $(DPKGDIR)/available $(DPKGDIR)/*-old $(DPKGDIR)/lock

	# Set up modules.dep, ensure there is at least one standard dir (kernel
	# in this case), so depmod will use its prune list for archs with no
	# modules.
	$(foreach VERSION,$(KERNELVERSION), \
		mkdir -p $(TREE)/lib/modules/$(VERSION)/kernel; \
		depmod -q -a -b $(TREE)/ $(VERSION); )
	# These files depmod makes are used by hotplug, and we shouldn't
	# need them, yet anyway.
	find $(TREE)/lib/modules/ -name 'modules*' \
		-not -name modules.dep -not -type d | xargs rm -f
	
	# Create a dev tree
	mkdir -p $(TREE)/dev
ifdef USERDEVFS
	# Create initial /dev entries -- only those that are absolutely
	# required to boot sensibly, though.
	mknod $(TREE)/dev/console c 5 1
	mkdir -p $(TREE)/dev/vc
	mknod $(TREE)/dev/vc/0 c 4 0
	mknod $(TREE)/dev/vc/1 c 4 1
	mknod $(TREE)/dev/vc/2 c 4 2
	mknod $(TREE)/dev/vc/3 c 4 3
	mknod $(TREE)/dev/vc/4 c 4 4
	mknod $(TREE)/dev/vc/5 c 4 5
	mkdir -p $(TREE)/dev/rd
	mknod $(TREE)/dev/rd/0 b 1 0
endif

	# Move the kernel image out of the way, either into a temp directory
	# for use later, or to dest.
ifdef DEST_KERNEL
	$(foreach NAME,$(KERNELNAME), \
		mv -f $(TREE)/boot/$(NAME) $(DEST)/$(NAME); )
else
	$(foreach NAME,$(KERNELNAME), \
		mv -f $(TREE)/boot/$(NAME) $(TEMP); )
endif
	-rmdir $(TREE)/boot/

ifndef NO_TERMINFO
	# Copy terminfo files for slang frontend
	# TODO: terminfo.udeb?
	for file in /etc/terminfo/a/ansi /etc/terminfo/l/linux \
		    /etc/terminfo/v/vt102; do \
		mkdir -p $(TREE)/`dirname $$file`; \
		cp -a $$file $(TREE)/$$file; \
	done
endif

ifdef EXTRAFILES
	# Copy in any extra files
	for file in $(EXTRAFILES); do \
		mkdir -p $(TREE)/`dirname $$file`; \
		cp -a $$file $(TREE)/$$file; \
	done
endif

ifdef EXTRALIBS
	# Copy in any extra libs.
	cp -a $(EXTRALIBS) $(TREE)/lib/
endif

ifeq ($(TYPE),floppy)
	# Unpack additional driver disks, so mklibs runs on them too.
	rm -rf $(DRIVEREXTRASDIR)
	mkdir -p $(DRIVEREXTRASDIR)
	mkdir -p $(DRIVEREXTRASDPKGDIR)/info $(DRIVEREXTRASDPKGDIR)/updates
	touch $(DRIVEREXTRASDPKGDIR)/status $(DRIVEREXTRASDPKGDIR)/available
	for udeb in $(EXTRAUDEBDIR)/*.udeb ; do \
		if [ -f "$$udeb" ]; then \
			dpkg $(DPKG_UNPACK_OPTIONS) --root=$(DRIVEREXTRASDIR) --unpack $$udeb; \
		fi; \
	done
endif

	# Library reduction.
	mkdir -p $(TREE)/lib
	$(MKLIBS) -v -d $(TREE)/lib --root=$(TREE) `find $(TEMP) -type f -perm +0111 -o -name '*.so'`

	# Add missing symlinks for libraries
	# (Needed for mklibs.py)
	/sbin/ldconfig -n $(TREE)/lib $(TREE)/usr/lib

	# Remove any libraries that are present in both usr/lib and lib,
	# from lib. These were unnecessarily copied in by mklibs, and
	# we want to use the ones in usr/lib instead since they came 
	# from udebs. Only libdebconf has this problem so far.
	for lib in `find $(TREE)/usr/lib/lib* -type f -printf "%f\n" | cut -d . -f 1 | sort | uniq`; do \
		rm -f $(TREE)/lib/$$lib.*; \
	done

	# Now we have reduced libraries installed .. but they are
	# not listed in the status file. This nasty thing puts them in,
	# and alters their names to end in -reduced to indicate that
	# they have been modified.
	for package in $$(dpkg -S `find $(TREE)/lib -type f -not -name '*.o' -not -name '*.dep' | \
			sed s:$(TREE)::` | cut -d : -f 1 | \
			sort | uniq); do \
		dpkg -s $$package | sed "s/$$package/$$package-reduced/g" \
			>> $(DPKGDIR)/status; \
	done

	# Reduce status file to contain only the elements we care about.
	egrep -i '^((Status|Provides|Depends|Package|Version|Description|installer-menu-item|Description-..):|$$)' \
		$(DPKGDIR)/status > $(DPKGDIR)/status.udeb
	rm -f $(DPKGDIR)/status
	ln -sf status.udeb $(DPKGDIR)/status

ifdef NO_I18N
	# Remove all internationalization from the templates.
	# Not ideal, but useful if you're very tight on space.
	for FILE in $$(find $(TREE) -name "*.templates"); do \
		perl -e 'my $$status = 0; while (<>) { if (/^[A-Z]/ || /^$$/) { if (/^(Choices|Description)-/) { $$status = 0; } else { $$status = 1; } } print if ($$status); }' < $$FILE > temp; \
		mv temp $$FILE; \
	done
endif
	
	# If the image has pcmcia, reduce the config file to list only
	# entries that there are modules on the image. This saves ~30k.
	if [ -e $(TREE)/etc/pcmcia/config ]; then \
		./pcmcia-config-reduce.pl $(TREE)/etc/pcmcia/config \
			`if [ -d "$(DRIVEREXTRASDIR)" ]; then find $(DRIVEREXTRASDIR)/lib/modules -name \*.o; fi` \
			`find $(TREE)/lib/modules/ -name \*.o` > \
			$(TREE)/etc/pcmcia/config.reduced; \
		mv -f $(TREE)/etc/pcmcia/config.reduced $(TREE)/etc/pcmcia/config; \
	fi

	# Strip all kernel modules, just in case they haven't already been
	for module in `find $(TREE)/lib/modules/ -name '*.o'`; do \
	    strip -R .comment -R .note -g $$module; \
	done

	# Remove some unnecessary dpkg files.
	for file in `find $(TREE)/var/lib/dpkg/info -name '*.md5sums' -o \
	    -name '*.postrm' -o -name '*.prerm' -o -name '*.preinst' -o \
	    -name '*.list'`; do \
		if echo $$file | grep -qv '\.list'; then \
			echo "** Removing unnecessary control file $$file"; \
		fi; \
		rm $$file; \
	done

	# Collect the used UTF-8 strings, to know which glyphs to include in
	# the font.  Using strings is not the best way, but no better
	# suggestion has been made yet.
	cp graphic.utf all-$(TYPE).utf
ifeq ($(TYPE),floppy)
	if [ -n "`find $(DRIVEREXTRASDPKGDIR)/info/ -name \\*.templates`" ]; then \
		cat $(DRIVEREXTRASDPKGDIR)/info/*.templates >> all-$(TYPE).utf; \
	fi
endif
	if [ -n "`find $(DPKGDIR)/info/ -name \\*.templates`" ]; then \
		cat $(DPKGDIR)/info/*.templates >> all-$(TYPE).utf; \
	fi
	find $(TREE) -type f | xargs strings >> all-$(TYPE).utf

ifeq ($(TYPE),floppy)
	# Remove additional driver disk contents now that we're done with
	# them.
	rm -rf $(DRIVEREXTRASDIR)
endif

	# Tree target ends here. Whew!
	touch $(TYPE)-tree-stamp

unifont-reduced-$(TYPE).bdf: all-$(TYPE).utf
	# Use the UTF-8 locale in rootskel-locale. This target shouldn't
	# be called when it is not present anyway.
	# reduce-font is part of package libbogl-dev
	# unifont.bdf is part of package bf-utf-source
	# The locale must be generated after installing the package locales
	CHARMAP=`LOCPATH=$(LOCALE_PATH) LC_ALL=C.UTF-8 locale charmap`; \
            if [ UTF-8 != "$$CHARMAP" ]; then \
	        echo "error: Trying to build unifont.bgf without rootskel-locale!"; \
	        exit 1; \
	    fi
	LOCPATH=$(LOCALE_PATH) LC_ALL=C.UTF-8 reduce-font /usr/src/unifont.bdf < all-$(TYPE).utf > $@.tmp
	mv $@.tmp $@

$(TREE)/unifont.bgf: unifont-reduced-$(TYPE).bdf
	# bdftobogl is part of package libbogl-dev
	bdftobogl -b unifont-reduced-$(TYPE).bdf > $@.tmp
	mv $@.tmp $@

# Build the driver floppy image
$(EXTRA_TARGETS) : %-stamp : $(TYPE)-get_udebs-stamp
	mkdir -p  ${TEMP}/$*
	for file in $(shell grep --no-filename -v ^\#  pkg-lists/$*/common \
		`if [ -f pkg-lists/$*/$(DEB_HOST_ARCH) ]; then echo pkg-lists/$*/$(DEB_HOST_ARCH); fi` \
	  	| sed -e 's/^\(.*\)$${kernel:Version}\(.*\)$$/$(foreach VERSION,$(KERNELIMAGEVERSION),\1$(VERSION)\2\n)/g' ) ; do \
			cp $(EXTRAUDEBDIR)/$$file* ${TEMP}/$*  ; \
			echo $$file >> ${TEMP}/$*/udeb_include; \
	done
	touch $@

$(EXTRA_IMAGES) : $(DEST)/%-image.img :  $(EXTRA_TARGETS)
	rm -f $@
	install -d $(TEMP)
	install -d $(DEST)
	set -e; if [ $(INITRD_FS) = ext2 ]; then \
		genext2fs -d $(TEMP)/$* -b $(FLOPPY_SIZE) -r 0  $@; \
        elif [ $(INITRD_FS) = romfs ]; then \
                genromfs -d $(TEMP)/$* -f $@; \
        else \
                echo "Unsupported filesystem type"; \
                exit 1; \
        fi;

tarball: tree
	tar czf $(DEST)/$(TYPE)-debian-installer.tar.gz $(TREE)

# Make sure that the temporary mountpoint exists and is not occupied.
tmp_mount:
	if mount | grep -q $(TMP_MNT) && ! umount $(TMP_MNT) ; then \
		echo "Error unmounting $(TMP_MNT)" 2>&1 ; \
		exit 1; \
	fi
	mkdir -p $(TMP_MNT)

# Create a compressed image of the root filesystem by way of genext2fs.
initrd: $(INITRD)
$(INITRD): TMP_FILE=$(TEMP)/image.tmp
$(INITRD):  $(TYPE)-tree-stamp
	# Only build the font if we have rootskel-locale
	if [ -d "$(LOCALE_PATH)/C.UTF-8" ]; then \
	    $(MAKE) $(TREE)/unifont.bgf; \
	fi
	rm -f $(TMP_FILE)
	install -d $(TEMP)
	install -d $(DEST)

	if [ $(INITRD_FS) = ext2 ]; then \
		genext2fs -d $(TREE) -b `expr $$(du -s $(TREE) | cut -f 1) + $$(expr $$(find $(TREE) | wc -l) \* 2)` $(TMP_FILE); \
	elif [ $(INITRD_FS) = romfs ]; then \
		genromfs -d $(TREE) -f $(TMP_FILE); \
	else \
		echo "Unsupported filesystem type"; \
		exit 1; \
	fi;
	gzip -vc9 $(TMP_FILE) > $(INITRD).tmp
	mv $(INITRD).tmp $(INITRD)

# Write image to floppy
floppy: boot_floppy
boot_floppy: $(IMAGE)
	install -d $(DEST)
	sudo dd if=$(IMAGE) of=$(FLOPPYDEV) bs=$(FLOPPY_SIZE)k

# Write drivers  floppy
%_floppy: $(DEST)/%-image.img
	sudo dd if=$< of=$(FLOPPYDEV) bs=$(FLOPPY_SIZE)k

# If you're paranoid (or things are mysteriously breaking..),
# you can check the floppy to make sure it wrote properly.
# This target will fail if the floppy doesn't match the floppy image.
floppy_check: $(IMAGE)
	sudo cmp $(FLOPPYDEV) $(IMAGE)

listtypes:
	@echo "supported types: $(TYPES_SUPPORTED)"


stats: tree $(EXTRA_TARGETS) general-stats $(EXTRA_STATS)

COMPRESSED_SZ=$(shell expr $(shell tar czf - $(TREE) | wc -c) / 1024)
KERNEL_SZ=$(shell expr \( $(foreach NAME,$(KERNELNAME),$(shell du -b $(TEMP)/$(NAME) 2>/dev/null | cut -f 1) +) 0 \) / 1024)
general-stats:
	@echo
	@echo "System stats for $(TYPE)"
	@echo "-------------------------"
	@echo "Installed udebs: $(UDEBS)"
	@echo -n "Total system size: $(shell du -h -s $(TREE) | cut -f 1)"
	@echo -n " ($(shell du -h --exclude=modules -s $(TREE)/lib | cut -f 1) libs, "
	@echo "$(shell du -h -s $(TREE)/lib/modules | cut -f 1) kernel modules)"
	@echo "Initrd size: $(COMPRESSED_SZ)k"
	@echo "Kernel size: $(KERNEL_SZ)k"
ifneq (,$(FLOPPY_SIZE))
	@echo "Free space: $(shell expr $(FLOPPY_SIZE) - $(KERNEL_SZ) - $(COMPRESSED_SZ))k"
endif
	@echo "Disk usage per package:"
	@sed 's/^/  /' < diskusage-$(TYPE).txt
# Add your interesting stats here.

SZ=$(shell expr $(shell du -b $(TEMP)/$*  | cut -f 1 ) / 1024)
$(EXTRA_STATS) : %-stats:
	@echo
	@echo "$* size: $(SZ)k"
ifneq (,$(FLOPPY_SIZE))
	@echo "Free space: $(shell expr $(FLOPPY_SIZE) - $(SZ))k"
endif
	@echo "Disk usage per package:"
	@cd $(TEMP)/$*/; ls -l *.udeb

# These tagets act on all available types.
all_build:
	set -e; for type in $(TYPES_SUPPORTED); do \
		$(MAKE) build TYPE=$$type; \
	done
all_images:
	set -e; for type in $(TYPES_SUPPORTED); do \
		$(MAKE) image TYPE=$$type; \
	done
all_clean:
	set -e; for type in $(TYPES_SUPPORTED); do \
		$(MAKE) clean TYPE=$$type; \
	done
# Suitable for a cron job, you'll only see the stats unless a build fails.
all_stats:
	@echo "Image size stats"
	@echo
	@(set -e; $(MAKE) all_build >tmp/log 2>&1 || \
	  (echo "build failure!"; cat tmp/log; false))
	@rm -f tmp/log
	@for type in $(TYPES_SUPPORTED); do \
		$(MAKE) -s stats TYPE=$$type; \
	done
