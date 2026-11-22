# Makefile - osmo-operator, facon noyau
# =============================================================================
#   Configuration (Kconfig : depends on / select / imply / choice / range)
#   make menuconfig        le menu du noyau (mconf, lxdialog) ; MENUCONFIG_COLOR=
#                          classic|bluetitle|blackbg|mono   make guiconfig (Tk)
#   make defconfig         .config depuis defconfigs/defconfig
#   make <nom>_defconfig   .config depuis defconfigs/<nom>_defconfig
#   make list-defconfigs   les defconfigs disponibles
#   make oldconfig         demande ce qui manque au .config (= make config)
#   make olddefconfig      complete le .config avec les valeurs par defaut
#   make savedefconfig     le .config minimal -> ./defconfig
#   make nconfig          l'autre menu du noyau          make config  question par question
#   make allyesconfig | allnoconfig | alldefconfig | randconfig | listnewconfig
#   make setconfig SET="TARGET_ISO=y ISO_KB=us"
#   make                   construit ce que .config decrit (= make build)
#   make showcmd           la commande que .config donne  make tree   arbres
#
#   make docker            build.sh (BuildKit bake)    make iso   build-iso.sh
#   make bake-print        la definition BuildKit resolue (docker-bake.hcl)
#
#   make c54x_exe          compile c54x_exe sur l'hote (clone s'il manque)
#   make c54x_exe-rom      ROM DSP 3606 depuis FreeCalypso (SHA-256)
#   make c54x_exe-{isa_test,dsp_tester,layer1_tester}   ses outils
#   make c54x_exe-clean
#
#   make debs              les .deb du banc (osmo-operator, pont, qemu-calypso,
#                          calypso-firmware) dans $(DEBS_OUT)
#   make debs-image        les .deb de la pile (osmo-build-*), via bake debs
#   make release           publie les .deb (banc + groupes facultatifs) en release
#                          GitHub, qui sert aussi de depot apt (tag debs-banc)
#
# Chemins : relatifs au depot par defaut, surchargeables (make VAR=...) et
# repris de .config quand il existe (CONFIG_C54X_DIR, CONFIG_QOSMO_DIR...).
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := build

# .config (tools/menuconfig.sh) : CONFIG_X="valeur" -> on retire les guillemets.
-include .config
unq = $(patsubst "%",%,$(1))

C54X_DIR          ?= $(or $(call unq,$(CONFIG_C54X_DIR)),../c54x_exe)
QOSMO             ?= $(or $(call unq,$(CONFIG_QOSMO_DIR)),../qosmo)
FIRMWARE_DIR      ?= $(or $(call unq,$(CONFIG_FIRMWARE_DIR)),../firmware)
FREECALYPSO_CACHE ?= $(or $(call unq,$(CONFIG_FREECALYPSO_CACHE)),.cache/freecalypso)
DEBS_OUT          ?= $(or $(call unq,$(CONFIG_DEBS_OUT)),packaging/dist)
DEBS_ONLY         ?= $(call unq,$(CONFIG_DEBS_ONLY))
ROM_DIR           ?= $(or $(call unq,$(CONFIG_ROM_DIR)),..)
C54X_NATIVE       ?= $(or $(CONFIG_C54X_NATIVE),n)
C54X_REPO         ?= https://github.com/bbaranoff/c54x_exe
QOSMO_REPO        ?= https://github.com/bbaranoff/qosmo
RELEASE_TAG       ?= $(or $(call unq,$(CONFIG_DEBS_RELEASE_TAG)),debs-banc)

# The Dockerfile's flags: -march=native would SIGILL on another CPU.
C54X_CFLAGS_PORTABLE := -O3 -g -Wall -Werror=format -Werror=format-extra-args \
    -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-sign-compare
C54X_CFLAGS := $(if $(filter y,$(C54X_NATIVE)),-march=native )$(C54X_CFLAGS_PORTABLE)

.PHONY: menuconfig nconfig guiconfig xconfig gconfig config oldconfig olddefconfig syncconfig \
        defconfig savedefconfig alldefconfig allyesconfig allnoconfig listnewconfig setconfig randconfig helpnewconfig \
        list-defconfigs kconfig-gen kconfig-tools build showcmd tree docker iso bake-print \
        c54x_exe c54x_exe-src c54x_exe-rom c54x_exe-clean \
        c54x_exe-isa_test c54x_exe-dsp_tester c54x_exe-layer1_tester \
        debs debs-image release-stage release help

help:
	@sed -n '3,33p' Makefile | sed 's/^# \{0,1\}//'
	@echo; echo "defconfigs :"; $(MAKE) -s list-defconfigs

# ── configuration (Kconfig, les outils du noyau) ─────────────────────────────
# tools/kconfig/linux : scripts/kconfig de Linux 6.8 (conf, mconf, nconf),
# compile au premier usage (gcc + libncurses-dev). Sans compilateur : repli
# sur kconfiglib (tools/kconfig/*.py, python3), meme Kconfig, meme .config.
# Les groupes docker et modules iso sont generes depuis tools/features.conf.
PYTHON          ?= python3
KCONFIG_CONFIG  ?= .config
KLINUX          := tools/kconfig/linux
KBIN            := $(KLINUX)/build
KPY             := tools/kconfig
KGEN            := kconfig/generated/Kconfig.groups kconfig/generated/Kconfig.modules kconfig/generated/Kconfig.params
DEFCONFIG       ?= defconfigs/defconfig
DEFCONFIG_OUT   ?= defconfig
# mconf : osmo (classic du noyau, lettres en bleu) | classic | bluetitle | blackbg | mono
MENUCONFIG_COLOR ?= osmo
MENUCONFIG_STYLE ?= $(shell cat $(KPY)/style 2>/dev/null)
# What mconf/conf write besides .config (auto.conf, autoconf.h): in .kconfig/,
# not in an include/ at the root of the repository.
KENV = srctree="$(CURDIR)" KCONFIG_CONFIG="$(KCONFIG_CONFIG)" \
       KCONFIG_AUTOCONFIG=.kconfig/auto.conf KCONFIG_AUTOHEADER=.kconfig/autoconf.h KCONFIG_RUSTCCFG=.kconfig/rustc_cfg \
       MENUCONFIG_COLOR="$(MENUCONFIG_COLOR)" MENUCONFIG_STYLE="$(MENUCONFIG_STYLE)"
# $(call kconf,<outil noyau>,<args noyau>,<repli kconfiglib>)
kconf = if $(MAKE) -s -C $(KLINUX) $(1) >/dev/null 2>&1; then $(KENV) $(KLINUX)/$(1) $(2); \
        else echo "(outils du noyau non compiles : gcc / libncurses-dev ? repli kconfiglib)" >&2; $(KENV) $(PYTHON) $(3); fi

$(KGEN): tools/features.conf tools/features.sh kconfig/gen-features.sh kconfig/gen-params.sh \
         globals.conf.example $(wildcard iso_modules/*.sh) $(wildcard install_modules/*.sh)
	@bash kconfig/gen-features.sh
	@bash kconfig/gen-params.sh build kconfig/generated/Kconfig.params
kconfig-gen: ; @bash kconfig/gen-features.sh && bash kconfig/gen-params.sh build kconfig/generated/Kconfig.params
kconfig-tools: ; @$(MAKE) -s -C $(KLINUX)

menuconfig: $(KGEN)
	@$(call kconf,build/mconf,Kconfig,$(KPY)/menuconfig.py Kconfig)
nconfig: $(KGEN)
	@$(call kconf,build/nconf,Kconfig,$(KPY)/menuconfig.py Kconfig)
guiconfig xconfig gconfig: $(KGEN)
	@$(KENV) $(PYTHON) $(KPY)/guiconfig.py Kconfig
config: $(KGEN)
	@$(call kconf,build/conf,--oldaskconfig Kconfig,$(KPY)/oldconfig.py Kconfig)
oldconfig: $(KGEN)
	@$(call kconf,build/conf,--oldconfig Kconfig,$(KPY)/oldconfig.py Kconfig)
olddefconfig syncconfig: $(KGEN)
	@$(call kconf,build/conf,--olddefconfig Kconfig,$(KPY)/olddefconfig.py Kconfig)
defconfig: $(KGEN)
	@$(call kconf,build/conf,--defconfig=$(DEFCONFIG) Kconfig,$(KPY)/defconfig.py --kconfig Kconfig $(DEFCONFIG))
%_defconfig: $(KGEN)
	@[ -f defconfigs/$@ ] || { echo "defconfigs/$@ : inconnu (make list-defconfigs)" >&2; exit 2; }
	@$(call kconf,build/conf,--defconfig=defconfigs/$@ Kconfig,$(KPY)/defconfig.py --kconfig Kconfig defconfigs/$@)
savedefconfig: $(KGEN)
	@$(call kconf,build/conf,--savedefconfig=$(DEFCONFIG_OUT) Kconfig,$(KPY)/savedefconfig.py --kconfig Kconfig --out $(DEFCONFIG_OUT))
alldefconfig allyesconfig allnoconfig: $(KGEN)
	@$(call kconf,build/conf,--$@ Kconfig,$(KPY)/$@.py Kconfig)
randconfig: $(KGEN)
	@$(call kconf,build/conf,--randconfig Kconfig,$(KPY)/alldefconfig.py Kconfig)
listnewconfig helpnewconfig: $(KGEN)
	@$(call kconf,build/conf,--$@ Kconfig,$(KPY)/listnewconfig.py --kconfig Kconfig)
# make setconfig SET="TARGET_ISO=y ISO_KB=us"   (comme scripts/config du noyau)
setconfig: $(KGEN)
	@$(KENV) $(PYTHON) $(KPY)/setconfig.py --kconfig Kconfig $(SET)
list-defconfigs:
	@for f in defconfigs/*defconfig; do printf '  %-28s %s\n' "$$(basename $$f)" "$$(sed -n 's/^# *//p;q' $$f)"; done

# make (= make build) : .config resynchronise (olddefconfig) puis construit.
build: $(KGEN)
	@[ -f "$(KCONFIG_CONFIG)" ] || { echo "$(KCONFIG_CONFIG) absent : make menuconfig, make defconfig ou make <nom>_defconfig" >&2; exit 1; }
	@$(call kconf,build/conf,--olddefconfig Kconfig,$(KPY)/olddefconfig.py Kconfig) >/dev/null
	@bash tools/menuconfig.sh --build --file="$(KCONFIG_CONFIG)"
showcmd: $(KGEN)
	@[ -f "$(KCONFIG_CONFIG)" ] || { echo "$(KCONFIG_CONFIG) absent" >&2; exit 1; }
	@$(call kconf,build/conf,--olddefconfig Kconfig,$(KPY)/olddefconfig.py Kconfig) >/dev/null
	@bash tools/menuconfig.sh --print --file="$(KCONFIG_CONFIG)"
tree:
	@bash tools/menuconfig.sh --tree

# ── images ───────────────────────────────────────────────────────────────────
docker:
	./build.sh $(ARGS)
iso:
	./build-iso.sh $(ARGS)
bake-print:
	docker buildx bake -f docker-bake.hcl --print $(or $(TARGETS),all run debs)

# ── c54x_exe : le DSP Calypso hors QEMU, compile sur l'hote ──────────────────
# Needs gcc, pkg-config and libosmocore-dev (libosmocoding); see
# doc/c54x_exe-depuis-ubuntu-vierge.md.
c54x_exe-src:
	@[ -d "$(QOSMO)/.git" ] || git clone $(QOSMO_REPO) "$(QOSMO)"
	@[ -d "$(C54X_DIR)/.git" ] || git clone $(C54X_REPO) "$(C54X_DIR)"
	@pkg-config --exists libosmocoding libosmocore \
	    || { echo "libosmocoding introuvable : apt install libosmocore-dev (ou le depot Osmocom)" >&2; exit 1; }

c54x_exe: c54x_exe-src
	$(MAKE) -C "$(C54X_DIR)" c54x_exe QOSMO="$(abspath $(QOSMO))" CFLAGS="$(C54X_CFLAGS)"
	@"$(C54X_DIR)/c54x_exe" --help >/dev/null 2>&1 || true
	@echo "c54x_exe : $(abspath $(C54X_DIR))/c54x_exe"

# The ROM: tools/freecalypso-fetch.sh (cache, SHA-256), then the repo's
# rom/fetch-rom.sh splits it into the 7 sections --rom-dir expects.
c54x_exe-rom: c54x_exe-src
	bash tools/freecalypso-fetch.sh --cache "$(FREECALYPSO_CACHE)" dsp-rom-3606-dump.txt
	cd "$(C54X_DIR)" && FREECALYPSO_URL="file://$(abspath $(FREECALYPSO_CACHE))" \
	    bash rom/fetch-rom.sh --dest "$(abspath $(ROM_DIR))" --dest "$(abspath $(C54X_DIR))/rom"
	cp -f "$(FREECALYPSO_CACHE)/dsp-rom-3606-dump.txt" "$(ROM_DIR)/calypso_dsp.txt"
	cp -f "$(FREECALYPSO_CACHE)/dsp-rom-3606-dump.txt" "$(C54X_DIR)/rom/calypso_dsp.txt"

c54x_exe-isa_test c54x_exe-dsp_tester c54x_exe-layer1_tester: c54x_exe-src
	$(MAKE) -C "$(C54X_DIR)" $(patsubst c54x_exe-%,%,$@) QOSMO="$(abspath $(QOSMO))" CFLAGS="$(C54X_CFLAGS)"

c54x_exe-clean:
	$(MAKE) -C "$(C54X_DIR)" clean

# ── les .deb ─────────────────────────────────────────────────────────────────
debs:
	OSMO_OPERATOR_SRC="$(CURDIR)" QOSMO_SRC="$(abspath $(QOSMO))" FIRMWARE_SRC="$(abspath $(FIRMWARE_DIR))" \
	    bash packaging/build-debs.sh --out "$(DEBS_OUT)" $(if $(DEBS_ONLY),--only "$(shell echo $(DEBS_ONLY) | tr " " ,)")
	@ls -lh "$(DEBS_OUT)"/*.deb

debs-image:
	docker buildx bake -f docker-bake.hcl debs
	@ls "$(CURDIR)/.deb-cache/out" | head -50

# Release = an apt repository. The bench .debs, plus the packages of the
# optional groups (gr-gsm, 4G: what the menu lets you leave out of an image),
# taken from the host .deb cache, are published with a flat apt index
# (Packages, Packages.gz, Release). An image that left them out installs them
# later with apt (iso_modules/89-apt-release.sh writes the source):
#     deb [trusted=yes] https://github.com/<repo>/releases/download/<tag> ./
# The tag is rolling (assets replaced, not marked "latest"). Refuses any
# package carrying the TI DSP mask ROM or a nested .deb: never published.
RELEASE_STAGE      ?= $(DEBS_OUT)/release
OSMO_DEB_CACHE     ?= $(or $(call unq,$(CONFIG_DEB_CACHE)),/var/cache/osmo-debs)
RELEASE_GROUP_PKGS ?= grgsm-venv grgsm-exe srsran open5gs libzmq srsgui pmbootstrap pmos-kernel

release-stage: debs
	@command -v dpkg-scanpackages >/dev/null || { echo "dpkg-scanpackages requis (apt install dpkg-dev)" >&2; exit 1; }
	mkdir -p "$(RELEASE_STAGE)"
	find "$(RELEASE_STAGE)" -maxdepth 1 -type f -delete
	@# GitHub turns "~" into "." in asset names: the index must use the served names.
	@for d in "$(DEBS_OUT)"/*.deb; do cp -f "$$d" "$(RELEASE_STAGE)/$$(basename "$$d" | tr '~' .)"; done
	@for p in $(RELEASE_GROUP_PKGS); do \
	    for d in "$(OSMO_DEB_CACHE)"/osmo-build-$${p}_*.deb; do \
	        if [ -f "$$d" ]; then cp -f "$$d" "$(RELEASE_STAGE)/$$(basename "$$d" | tr '~' .)"; fi; \
	    done; \
	done
	@for d in "$(RELEASE_STAGE)"/*.deb; do \
	    if dpkg-deb -c "$$d" | grep -qE 'calypso_dsp|dsp-rom-[0-9]+-dump|\.deb$$'; then \
	        echo "REFUS : $$d contient la ROM DSP TI ou un .deb imbrique" >&2; exit 1; fi; \
	done
	cd "$(RELEASE_STAGE)" && dpkg-scanpackages --multiversion . /dev/null 2>/dev/null > Packages \
	    && gzip -9kf Packages && sha256sum *.deb > SHA256SUMS \
	    && { echo "Origin: osmo-operator"; echo "Label: osmo-operator $(RELEASE_TAG)"; \
	         echo "Suite: $(RELEASE_TAG)"; echo "Date: $$(LC_ALL=C date -Ru)"; echo "SHA256:"; \
	         for f in Packages Packages.gz; do printf ' %s %s %s\n' "$$(sha256sum $$f | cut -d' ' -f1)" "$$(stat -c%s $$f)" "$$f"; done; } > Release
	@ls -lh "$(RELEASE_STAGE)"

release: release-stage
	@command -v gh >/dev/null || { echo "gh (GitHub CLI) requis" >&2; exit 1; }
	gh release view "$(RELEASE_TAG)" >/dev/null 2>&1 \
	    || gh release create "$(RELEASE_TAG)" --latest=false \
	        --title "Paquets .deb du banc - depot apt ($(RELEASE_TAG))" \
	        --notes "Paquets du banc (packaging/build-debs.sh : osmo-operator, pont, qemu-calypso, calypso-firmware) et paquets des groupes facultatifs de l'image (gr-gsm, 4G : srsRAN, Open5GS, pmbootstrap, noyau pmOS). Cette release est aussi un depot apt plat : echo 'deb [trusted=yes] https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/$(RELEASE_TAG) ./' | sudo tee /etc/apt/sources.list.d/osmo-operator.list && sudo apt update. Les ISO le declarent deja (iso_modules/89-apt-release.sh). Sommes de controle : SHA256SUMS. Aucun paquet ne contient la ROM DSP TI."
	gh release upload "$(RELEASE_TAG)" "$(RELEASE_STAGE)"/* --clobber

