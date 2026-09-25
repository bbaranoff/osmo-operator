<html><head></head><body><p><a href="https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml"><img src="https://github.com/bbaranoff/osmo-operator/actions/workflows/build-iso.yml/badge.svg" alt="Build ISO"></a></p>
<h2>osmo-operator-desktop.iso</h2>
<p>the pmOS phone password is 147147, the live ISO is osmo</p>
<h3>Download</h3>
<p><strong>Download every <code>.part-NN</code> file</strong>, not just the first one.</p>
<p>GitHub caps release files at 2 GiB: the image ships in pieces. Reassemble, then verify:</p>
<pre><code class="language-sh">cat osmo-operator-desktop.iso.part-* &gt; osmo-operator-desktop.iso
sha256sum -c SHA256SUMS
</code></pre>
<p><img src="https://raw.githubusercontent.com/bbaranoff/bbaranoff/main/norf-box.gif" alt="The bench in action: CSFB call, I/Q spectra, srsUE, Wireshark, Linphone"></p>
<p>A complete GSM + LTE operator on a single live image, with a GNOME desktop (Wireshark in a window, linphone-desktop, GSM LAB wallpaper) for everything that can't be driven from the VTY. No SDR and no physical phone: the radio is emulated end to end, all the way down to the baseband.</p>
<p><code>/etc/os-release</code>: <code>IMAGE_VERSION="OSMO_EGPRS_V2"</code> — <code>/etc/osmo-role</code>: <code>OSMO_ROLE=operator</code>, <code>OSMO_LITE=0</code>.</p>
<h3>What's inside</h3>
<p><strong>2G/GSM — Osmocom</strong></p>
<ul>
<li>Full core: osmo-stp (M3UA, SCTP :2905), osmo-bsc, osmo-msc, osmo-hlr, osmo-sgsn, osmo-ggsn (GTPv1-C/U), osmo-pcu, osmo-mgw (MGCP :2427).</li>
<li>Two DCS1800 cells in LAC 1 — BTS 0 (Cell ID 6001, BSIC 7) and BTS 1 (Cell ID 6012, BSIC 8) — each on its own osmo-bts-trx.</li>
<li>Layer 1: <strong>a real emulated Calypso</strong>. <code>qemu-system-arm -M calypso -cpu arm946</code> (<a href="https://github.com/bbaranoff/qosmO">qosmo</a>) runs <code>layer1.highram.elf</code>, loaded by <code>osmocon</code> exactly as on a C123. <code>pont.py</code> converts the bursts to I/Q for <code>fake_trx.py</code>, then <code>trxcon</code> and two <code>mobile</code> (osmocom-bb) instances on the terminal side. Two demodulators to choose from at launch: gr-gsm (the default) or the Calypso's own DSP (see below).</li>
<li>Working GPRS/EDGE: BSSGP/NS to the PCU, PDP contexts through osmo-ggsn.</li>
<li>Voice: external MNCC → Asterisk (SIP :5060, FR/HR codecs) via osmo-sip-connector.</li>
<li>SMS: SMS-over-GSUP → proto-smsc-daemon, SMPP (:2775) with a test ESME, inter-operator relay (:7890).</li>
<li>A3A8 authentication with deterministic RAND (<code>*-force-rand-toy</code> patches): the bench is reproducible from one boot to the next.</li>
<li>Live GSMTAP capture, ready to open directly in Wireshark.</li>
</ul>
<p><strong>The DSP — the Calypso's TMS320C54x, running TI's real mask ROM</strong></p>
<ul>
<li>By default the handset's layer 1 is demodulated by gr-gsm (<a href="https://github.com/bbaranoff/grgsm_exE">grgsm_exe</a>). With <code>./start-direct.sh --dsp</code>, it is done instead by the baseband's own DSP: a TMS320C54x core emulated outside QEMU (<a href="https://github.com/bbaranoff/c54x_exe">c54x_exe</a>), executing the mask ROM dumped from a real Calypso (PROM0-3, DROM, PDROM, <code>/opt/GSM/calypso_dsp.*.bin</code>).</li>
<li>The ARM (QEMU) and the DSP share the API RAM through <code>/dev/shm/calypso_api_ram</code> and run in lockstep, one TDMA frame at a time, over <code>/tmp/calypso_dsp.sock</code>; downlink bursts from osmo-bts-trx reach the DSP's serial port (BSP) over UDP 6702 via <code>pont_dsp.py</code>. The rest of the stack (core, BTS, second mobile) is unchanged.</li>
<li>What the ROM does by itself (bench runs of 2026-09-23): FCCH/SCH acquisition, BCCH decoding (SI1-4), camping, location update, SMS MO and MT, MO and MT calls with A5/1 and speech audible both ways (TCH/F channel decoding by the ROM, FR codec on the host).</li>
<li>Still a work bench, not the demo path: every TCH/F frame is flagged bad (BFI) by the ROM even though the speech stays intelligible, the SACCH occasionally drops a call (LOS), the SB window is rarely armed by the ROM, and the DSP needs 4.3–4.6 ms of host time for a 4.62 ms frame. Details in the <a href="https://github.com/bbaranoff/c54x_exe">c54x_exe README</a>.</li>
</ul>
<p><strong>4G/LTE — open5gs + srsRAN</strong></p>
<ul>
<li>open5gs core (MME, SGW-C/U, SMF, UPF, PCRF, HSS…) on dedicated loopbacks, Prometheus metrics (:9090), WebUI (:9999), MongoDB behind the HSS.</li>
<li>PLMN 001/01, TAC 7. NAS security with null ciphering (EIA2/EIA1 + EEA0), on purpose: this is an analysis bench, the NAS reads in clear text in Wireshark.</li>
<li>srsRAN RAN over ZMQ: srsENB (10 MHz, EARFCN 3350, band 7) and srsUE linked by a socket, no SDR. Milenage test subscriber (IMSI 001010001000001). The UE gets an IP in a netns and reaches the Internet through NAT.</li>
</ul>
<p><strong>CSFB — the piece that ties the two together</strong></p>
<ul>
<li>SGs interface between osmo-msc and the MME (:29118), with the <code>TAI (001-01, TAC 7) → LAI (001-01, LAC 1)</code> mapping: the VLR files the subscriber under LAC 1 while it is physically on LTE.</li>
<li>Combined EPS+IMSI attach, radio presence on the GSM side: an incoming call is paged by the MME and the UE drops back to the BTS.</li>
<li>Two provisioned subscribers (100101 and 100102, one per cell): the bench is wired for an inter-cell call with fallback.</li>
</ul>
<p><strong>postmarketOS — the phone</strong></p>
<ul>
<li>An x86_64 pmOS VM with a patched kernel: upstream <code>linux-postmarketos-stable</code> doesn't enable <code>CONFIG_PPP</code>, without which an AT modem can't carry IP. The prebuilt kernel (Git LFS) is provided in <code>/opt/user_interface/kernel/pmos/</code>.</li>
<li>4G data: NetworkManager → pppd (<code>ATD*99***1#</code>) → virtio-console <code>osmo.data</code> → <code>osmo-phonesim-banc.py</code> → UE netns → srsUE → srsENB → UPF → Internet.</li>
<li>2G voice and SMS: a second virtio-console <code>osmo.modem</code>, where <code>osmo-phonesim-banc.py</code> plays the 27.007 AT modem (state read from the osmo-bsc, osmo-msc and mobile VTYs) and oFono drives it. No dongle.</li>
<li>Audio: two duplex PulseAudio chains (intel-hda) — a bridge to the osmocom-bb mobile via GAPK, and a chain with echo cancellation.</li>
<li>Result: data on 4G, voice and SMS on 2G, under the same identity. The behaviour of a real CSFB handset, at the modem level.</li>
<li><strong>pmOS password: <code>147147</code></strong></li>
</ul>
<h3>Running the image</h3>
<p>In every case: x86_64, <strong>8 GB of RAM and 4 cores</strong> minimum. The live root is a tmpfs (~6 GB in <code>toram</code> mode); logs and captures are bounded there, and purged at every boot. The bench itself runs two QEMUs (the Calypso and the postmarketOS VM): in a virtual machine, enable <strong>nested virtualization</strong>, otherwise the pmOS VM falls back to software emulation and becomes very slow.</p>
<p><strong>QEMU</strong></p>
<pre><code class="language-sh">qemu-system-x86_64 -cdrom osmo-operator-desktop.iso -m 8G -enable-kvm \
  -cpu host -smp 4 -nic user,hostfwd=tcp::8080-:8080
</code></pre>
<p><strong>VirtualBox</strong></p>
<ul>
<li>New VM, type Linux / Ubuntu (64-bit), 8 GB of RAM, 4 processors, 3D disabled.</li>
<li>System → Processor: tick <em>Nested VT-x/AMD-V</em> (if the box is greyed out: <code>VBoxManage modifyvm "&lt;name&gt;" --nested-hw-virt on</code>).</li>
<li>Storage: attach the ISO to the optical drive. No disk needed, it's a live image.</li>
<li>NAT network: add a port forwarding rule host 8080 → guest 8080 to reach the bench from the host machine.</li>
</ul>
<p><strong>VMware (Workstation / Player / Fusion)</strong></p>
<ul>
<li>New VM from the ISO, Linux / Ubuntu 64-bit, 8 GB, 4 cores.</li>
<li>Processors: tick <em>Virtualize Intel VT-x/EPT or AMD-V/RVI</em>.</li>
<li>Skip Easy Install: it's a live image, it boots from the ISO.</li>
</ul>
<p><strong>USB stick</strong> (the ISO is hybrid, it can be copied raw)</p>
<pre><code class="language-sh">sudo dd if=osmo-operator-desktop.iso of=/dev/sdX bs=4M status=progress conv=fsync
</code></pre>
<p>On Windows, <strong>Rufus</strong>: select the ISO and, if Rufus offers the choice, write in <em>DD Image mode</em> rather than ISO. Then boot from the stick, in UEFI or BIOS, either works. On real hardware, KVM is available directly: this is the most comfortable setup.</p>
<h3>Getting started</h3>
<p>Everything launches from the dock, where three launchers are pinned as favourites. 2G and 4G are independent and can be started in any order; the smartphone is launched <strong>last</strong>, once both networks are up.</p>

  | Launcher | What it starts
-- | -- | --
<img src="https://raw.githubusercontent.com/bbaranoff/osmo-operator/main/data/osmo-launch.svg" width="32"> | 2G — the red handset | The GSM core and the emulated radio: osmo-stp / bsc / msc / hlr / sgsn / ggsn / pcu, the Calypso under QEMU, the two BTS and the two osmocom-bb mobiles, Asterisk, the SMSC.
<img src="https://raw.githubusercontent.com/bbaranoff/osmo-operator/main/data/osmo-lte.svg" width="32"> | 4G — the signal bars | open5gs, srsENB and srsUE over ZMQ, and the SGs interface to the MSC (the CSFB).
📱 | Smartphone — the Adwaita theme's phone icon | The postmarketOS VM: oFono on the virtual modem, data on 4G, voice and SMS on 2G. Launch it last.


<p>The 2G and 4G icons are SVGs from the repo (<code>data/</code>), hand-drawn rather than taken from the theme: <code>call-start</code> is green in Adwaita with no red variant, and a missing theme icon is silently replaced by a grey rectangle. An embedded SVG can't go missing.</p>
<p>To run the 2G handset on the DSP instead of gr-gsm, from a terminal: <code>cd /opt/GSM/osmo-operator &amp;&amp; sudo ./start-direct.sh --dsp</code> (the <code>--menu</code> option asks the same question interactively: layer 1 <code>grgsm_exe</code> or <code>c54x_exe</code>).</p>
<p>Check that everything is in place: <code>checks/diag-stp-operator.sh</code>.</p></body></html>
