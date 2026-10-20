# English notes per Dockerfile stage (read by tools/dockerfile-to-install-md.sh --lang en)

One section per stage name (`## <stage>`); the text is inserted under the stage heading of the English
install guide. The Dockerfile comments themselves are in French and are reproduced only in the French guide.

## base

Ubuntu 24.04 (noble) and everything that is long to install and rarely changes: the whole apt package list
(one list for the entire project, `apt-fast` to download it), Wireshark allowed for non-root capture, the
`osmo-deb` helper that caches every compiled tree as a `.deb` in `/var/cache/osmo-debs`, the Asterisk and
ALSA configuration files, the `osmocom` system user and the `/opt/GSM` tree that every script expects.
On a bare machine the `.deb` cache is empty: every `osmo-deb install` fails and the build branch runs.

## osmo-core

The Osmocom stack compiled from source, in dependency order and at pinned versions (libosmocore,
libosmo-netif, libosmo-abis, libosmo-sigtran, libsmpp34, libgtpnl, osmo-hlr, osmo-mgw, osmo-ggsn,
osmo-sgsn, osmo-msc, osmo-bsc, osmo-trx, osmo-bts, osmo-pcu, osmo-sip-connector, libosmo-gprs), then the
project patches kept in `patches/`: osmo-trx IPC device aligned on the TDMA frame and a per-RA RACH
modulation table, and the "force RAND" toy patches for osmo-bts, osmo-hlr and osmo-msc (the RAND of the
authentication challenge is forced only when the `RAND` environment variable is set). The stage ends with
osmo-gapk (voice codecs), the GSUP SMSC protocol library, the SMS coding utilities and libosmo-dsp.

## bb

osmocom-bb (the `mobile` application, `osmocon`, layer23) with the patches from `patches/osmocom-bb-*`
(clock generator frame tolerance, PLMN handling, SIM PLMN from BCD), the Calypso firmware images
(`layer1.highram.elf` and friends) and the two gcc flavours the old trees need (gcc-9 selected through
`update-alternatives` while building, gcc-11 restored afterwards). It also builds the
`osmocom-bb-transceiver` tree (Sylvain Munaut's jolly/testing branch: the `trx` firmware application and the
host `transceiver` program that turns the phone into a BTS transceiver) with
`patches/osmocom-bb-transceiver-qemu-bench.patch`, and the `burst-ind` tree.

## qemu

The single QEMU tree of the project, `/opt/GSM/qosmo`: a QEMU fork with the Calypso machine (ARM core,
TPU/TSP, DSP API RAM, LCD and keypad emulation) built with `--enable-l1-grgsm`, the gr-gsm layer 1 shunt.
The C54x DSP itself is no longer run inside QEMU: see the `l1` stage.

## l1

The two layer-1 engines that run outside QEMU: `c54x_exe` (the TMS320C54x core emulated from the qosmo
sources, loading the real TI mask ROM, see the appendix) and `grgsm_exe` (the gr-gsm based layer 1).
The DSP ROM images come from the FreeCalypso dump and are split into the seven sections `c54x_exe` reads.

## grgsm-venv

GNU Radio 3.10, gr-osmosdr and gr-gsm installed in the Python virtual environment `/root/.env`, with the
project patches for gr-gsm (optional Qt GUI import, receiver publishing BSIC and frame number). The venv
is activated from root's profile at the end of the final stage.

## node

Node 22 and the web dashboard `osmo-egprs-web` (the operations console served as a systemd unit), plus
its npm dependencies.

## lte

The 4G side of the bench: srsRAN_4G built with the ZeroMQ radio (no SDR needed) and Open5GS, both under
`/opt/LTE`, with their configuration files.

## osmocom-nitb

The assembly stage, the image that is actually published. Nothing is compiled here: the `.deb` packages
produced by the previous stages are installed (`dpkg -i`), then the project files are laid out: the
`/etc/osmocom` configurations, the scripts under `/usr/local/bin`, the systemd units, the PulseAudio
system daemon configuration (GSM audio), the runtime directories, the shell prompt, the desktop pieces
and the `/opt/GSM` helper scripts. On a single machine the `COPY --from=<stage>` instructions are no-ops:
everything is already installed where the previous stages put it. The container entrypoint and stop
signal are Docker metadata only.

## debs

A `scratch` stage holding only `/var/cache/osmo-debs`, used by the CI to extract the compiled packages
without materialising the full image. Nothing to do on a machine.
