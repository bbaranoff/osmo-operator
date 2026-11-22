# docker-bake.hcl - the four Dockerfiles as one BuildKit build graph
# =============================================================================
#
#   docker buildx bake --load                 osmocom-nitb (group default)
#   docker buildx bake --load nitb lite stp   several images in ONE BuildKit run
#   docker buildx bake --load all             nitb + lite + stp
#   docker buildx bake run                    osmocom-run on the local osmocom-nitb
#   docker buildx bake debs                   the .deb cache into .deb-cache/out/
#   docker buildx bake --print [target]       the resolved definition (JSON)
#
# build.sh uses it by default (OSMO_BUILD_BACKEND=bake|compose|docker); the
# menu (make menuconfig, build.sh --menuconfig) writes the same variables.
#
# Why bake rather than one `docker build` per image:
#   - targets requested together share ONE BuildKit session: stp (independent
#     of nitb) builds in parallel with nitb, and lite starts as soon as nitb is
#     done, without going through the local image store;
#   - lite takes nitb through a named context (contexts = target:nitb): the
#     Dockerfile.lite `FROM ${BASE}` is served by the nitb target, so
#     `bake lite` alone is consistent too (nitb comes from the BuildKit cache);
#   - the arguments live here once, instead of build.sh + compose.yaml.
#
# Every variable can be overridden from the environment (same name), which is
# how build.sh passes them:  OSMO_FAST=1 docker buildx bake --load nitb
# =============================================================================

variable "OSMO_DEB_REFRESH"   { default = "0" }   # 1 = recompile every .deb (build.sh --no-cache)
variable "OSMO_UBUNTU_MIRROR" { default = "" }    # chosen by packaging/apt-mirror.sh
variable "OSMO_FAST"          { default = "0" }   # build.sh --fast (amd64 only)
# Optional components of the Dockerfile (1 = built, 0 = left out):
# tools/features.conf, make menuconfig, build.sh --without=... GNURADIO and
# NODE are libs: build.sh sets them from GRGSM_EXE / EGPRS_WEB.
variable "OSMO_WITH_GRGSM_EXE"   { default = "1" }
variable "OSMO_WITH_GNURADIO"    { default = "1" }
variable "OSMO_WITH_LTE"         { default = "1" }
variable "OSMO_WITH_PMBOOTSTRAP" { default = "1" }
variable "OSMO_WITH_EGPRS_WEB"   { default = "1" }
variable "OSMO_WITH_NODE"        { default = "1" }
variable "OSMO_WITH_TNCATTACH"   { default = "1" }
variable "OSMO_WITH_RNS"         { default = "1" }
variable "OSMO_WITH_GAPK"        { default = "1" }
variable "OSMO_WITH_SMSC"        { default = "1" }
variable "OSMO_WITH_SMS_CODING_UTILS" { default = "1" }
variable "OSMO_WITH_TRANSCEIVER" { default = "1" }
variable "OSMO_WITH_BURST_IND"   { default = "1" }
variable "OSMO_WITH_LIBOSMO_DSP" { default = "1" }
variable "QEMU_CACHE_BUST"    { default = "0" }   # Dockerfile.run: forces the git pulls
variable "HUB_NODES"          { default = "3" }   # Dockerfile.stp
variable "HUB_OPS"            { default = "1" }
variable "STP_BASE_IMAGE"     { default = "ubuntu:24.04" }
# Target platform: empty = the host's. linux/arm64 = emulated build (buildx +
# qemu-user-static), then OSMO_IMG_TAG=arm64 so both coexist locally.
variable "OSMO_PLATFORM"      { default = "" }
variable "OSMO_IMG_TAG"       { default = "" }    # "" -> osmocom-nitb, "arm64" -> osmocom-nitb:arm64
# Image Dockerfile.run starts from (the run target is meant to sit on an
# existing local osmocom-nitb, not to rebuild it).
variable "RUN_BASE"           { default = "" }

function "img" {
  params = [name]
  result = OSMO_IMG_TAG == "" ? name : "${name}:${OSMO_IMG_TAG}"
}

group "default" { targets = ["nitb"] }
group "all"     { targets = ["nitb", "lite", "stp"] }

# Common to every target: context, platform.
target "_common" {
  context   = "."
  platforms = OSMO_PLATFORM == "" ? [] : [OSMO_PLATFORM]
}

# osmocom-nitb: the long build (Dockerfile, stages base -> osmo-core/qemu/lte/
# node -> bb/l1/grgsm-venv -> osmocom-nitb). --target is mandatory: the last
# stage of the Dockerfile is `debs`.
target "nitb" {
  inherits   = ["_common"]
  dockerfile = "Dockerfile"
  target     = "osmocom-nitb"
  tags       = [img("osmocom-nitb")]
  args = {
    OSMO_DEB_REFRESH   = OSMO_DEB_REFRESH
    OSMO_UBUNTU_MIRROR = OSMO_UBUNTU_MIRROR
    OSMO_FAST          = OSMO_FAST
    OSMO_WITH_GRGSM_EXE   = OSMO_WITH_GRGSM_EXE
    # libs follow the component that needs them
    OSMO_WITH_GNURADIO    = OSMO_WITH_GRGSM_EXE == "1" ? OSMO_WITH_GNURADIO : "0"
    OSMO_WITH_LTE         = OSMO_WITH_LTE
    OSMO_WITH_PMBOOTSTRAP = OSMO_WITH_PMBOOTSTRAP
    OSMO_WITH_EGPRS_WEB   = OSMO_WITH_EGPRS_WEB
    OSMO_WITH_NODE        = OSMO_WITH_EGPRS_WEB == "1" ? OSMO_WITH_NODE : "0"
    OSMO_WITH_TNCATTACH   = OSMO_WITH_TNCATTACH
    OSMO_WITH_RNS         = OSMO_WITH_RNS
    OSMO_WITH_GAPK        = OSMO_WITH_GAPK
    OSMO_WITH_SMSC        = OSMO_WITH_SMSC
    OSMO_WITH_SMS_CODING_UTILS = OSMO_WITH_SMS_CODING_UTILS
    OSMO_WITH_TRANSCEIVER = OSMO_WITH_TRANSCEIVER
    OSMO_WITH_BURST_IND   = OSMO_WITH_BURST_IND
    OSMO_WITH_LIBOSMO_DSP = (OSMO_WITH_TRANSCEIVER == "1" || OSMO_WITH_BURST_IND == "1") ? OSMO_WITH_LIBOSMO_DSP : "0"
    # the stage `lte` carries the 4G and pmbootstrap
    OSMO_STAGE_LTE        = (OSMO_WITH_LTE == "1" || OSMO_WITH_PMBOOTSTRAP == "1") ? "1" : "0"
  }
}

# The .deb cache produced by the nitb build (stage `debs`, FROM scratch),
# written to .deb-cache/out/ - what the CI publishes.
target "debs" {
  inherits   = ["nitb"]
  target     = "debs"
  tags       = []
  output     = ["type=local,dest=.deb-cache/out"]
}

# osmocom-nitb:lite: nitb without the /opt/GSM source trees, flattened.
target "lite" {
  inherits   = ["_common"]
  dockerfile = "Dockerfile.lite"
  tags       = [OSMO_IMG_TAG == "" ? "osmocom-nitb:lite" : "osmocom-nitb:lite-${OSMO_IMG_TAG}"]
  args       = { BASE = "osmocom-nitb" }
  contexts   = { "osmocom-nitb" = "target:nitb" }
}

# osmocom-stp: the SS7 hub alone; independent of nitb, so it builds in parallel.
target "stp" {
  inherits   = ["_common"]
  dockerfile = "Dockerfile.stp"
  tags       = [img("osmocom-stp")]
  args = {
    BASE_IMAGE         = STP_BASE_IMAGE
    HUB_NODES          = HUB_NODES
    HUB_OPS            = HUB_OPS
    OSMO_DEB_REFRESH   = OSMO_DEB_REFRESH
    OSMO_UBUNTU_MIRROR = OSMO_UBUNTU_MIRROR
  }
}

# osmocom-run: the daily layer (scripts, configs, git pulls) on the LOCAL
# osmocom-nitb image - no named context on purpose: it must not rebuild nitb.
target "run" {
  inherits   = ["_common"]
  dockerfile = "Dockerfile.run"
  tags       = [img("osmocom-run")]
  args = {
    BASE            = RUN_BASE == "" ? img("osmocom-nitb") : RUN_BASE
    QEMU_CACHE_BUST = QEMU_CACHE_BUST
  }
}
