"""vsp_audio.py - the voice port (VSP) of the Calypso DSP connected to PulseAudio.

c54x_exe models the SP0 serial port of the ROM (qosmo
hw/arm/calypso/l1-dsp/calypso_vsp.c, CALYPSO_VSP=1): for every sample it sets
DRR from the ring /dev/shm/calypso_pcm_ul and picks DXR up into
/dev/shm/calypso_pcm_dl, at exactly 8 kHz relative to the BTS fn. This module
does the rest, outside the DSP real-time loop:

    gsm_mic.monitor --parec--> calypso_pcm_ul      (the mobile's microphone)
    calypso_pcm_dl  --pacat--> gsm_audio            (its loudspeaker)

These are the points where GAPK plugs the mobile (alsa gsm_in / gsm_out) and
the ones the "voice" stage of banc-max injects into and listens to: the test
stays the same judge.

Rings: header uint32 written (count of samples written), uint32 size, then
size x int16. A single writer per ring. Started by c54x_exe/run.sh (step 5b)
when CALYPSO_VSP=1:  python3 -m pont.vsp_audio
"""
import fcntl
import mmap
import os
import struct
import subprocess
import sys
import termios
import threading
import time

SHM_UL = "/dev/shm/calypso_pcm_ul"
SHM_DL = "/dev/shm/calypso_pcm_dl"
N = 16000                       # = VSP_SHM_N (calypso_vsp.h)
TAILLE = 8 + 2 * N
TAUX = 8000
SOURCE = os.environ.get("VSP_SOURCE", "gsm_mic.monitor")
SINK = os.environ.get("VSP_SINK", "gsm_audio")
GIGUE = int(os.environ.get("VSP_GIGUE_MS", "60")) * TAUX // 1000
DL_CIBLE = int(os.environ.get("VSP_DL_CIBLE_MS", "150")) * TAUX // 1000   # pipe to pacat


def anneau(chemin):
    fd = os.open(chemin, os.O_RDWR | os.O_CREAT, 0o666)
    os.ftruncate(fd, TAILLE)
    m = mmap.mmap(fd, TAILLE)
    os.close(fd)
    struct.pack_into("<I", m, 4, N)
    return m


def journal(*a):
    print("[vsp-audio]", *a, flush=True)


def micro(ul):
    """parec -> UL ring (single writer)."""
    cmd = ["parec", f"--device={SOURCE}", "--format=s16le", f"--rate={TAUX}", "--channels=1",
           "--raw", "--latency-msec=20"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    journal("micro :", " ".join(cmd))
    w = struct.unpack_from("<I", ul, 0)[0]
    while True:
        bloc = p.stdout.read(320)                     # 20 ms
        if not bloc:
            journal("parec s'est arrete"); return
        for (ech,) in struct.iter_unpack("<h", bloc[: len(bloc) // 2 * 2]):
            struct.pack_into("<h", ul, 8 + 2 * (w % N), ech)
            w = (w + 1) & 0xFFFFFFFF
        struct.pack_into("<I", ul, 0, w)              # counter last


def en_attente(fd):
    """Bytes already written to the pipe to pacat and not yet read by it."""
    try:
        return struct.unpack("i", fcntl.ioctl(fd, termios.FIONREAD, b"\0\0\0\0"))[0]
    except OSError:
        return 0


def haut_parleur(dl):
    """DL ring -> pacat, with bounded delay.

    pacat consumes at exactly 8 kHz: silence added while the ring is empty
    (DSP behind), then DSP samples arriving in a burst, would pile up in the
    pipe (64 KiB = 4 s) without ever draining. The pipe is therefore only
    filled up to DL_CIBLE (default 150 ms); silence is only used if the pipe
    is about to run dry; the ring keeps at most GIGUE samples of delay (the
    surplus is dropped, once, and counted)."""
    cmd = ["pacat", "--playback", f"--device={SINK}", "--format=s16le", f"--rate={TAUX}",
           "--channels=1", "--raw", "--latency-msec=60"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    journal("haut-parleur :", " ".join(cmd))
    fd = p.stdin.fileno()
    cible = DL_CIBLE
    lu = None
    n_total = n_silence = n_jete = 0
    file_max = 0
    t_journal = time.monotonic()
    while True:
        w = struct.unpack_from("<I", dl, 0)[0]
        if lu is None:
            lu = (w - GIGUE) & 0xFFFFFFFF
        dispo = (w - lu) & 0xFFFFFFFF
        if dispo > N or dispo > GIGUE + cible:           # ring behind: catch up
            n_jete += (dispo - GIGUE) if dispo <= N else 0
            lu = (w - GIGUE) & 0xFFFFFFFF
            dispo = GIGUE
        file = en_attente(fd) // 2
        file_max = max(file_max, file)
        manque = cible - file
        if manque >= 160:
            k = min(dispo, manque)
            out = bytearray()
            for i in range(k):
                out += dl[8 + 2 * ((lu + i) % N): 10 + 2 * ((lu + i) % N)]
            lu = (lu + k) & 0xFFFFFFFF
            n_total += k
            if file + k < 320:                           # the pipe is about to run dry: silence
                out += bytes(2 * (320 - file - k)); n_silence += 320 - file - k
            if out:
                p.stdin.write(out); p.stdin.flush()
        time.sleep(0.01)
        if time.monotonic() - t_journal > 30:
            journal(f"DL : {n_total} echantillons du DSP, {n_silence} de silence, {n_jete} jetes (retard), "
                    f"tuyau vers pacat <= {file_max * 1000 // TAUX} ms (cible {cible * 1000 // TAUX} ms) en 30 s")
            n_total = n_silence = n_jete = file_max = 0; t_journal = time.monotonic()


def pactl(*args):
    r = subprocess.run(["pactl", *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def micro_reel():
    """The operator's real microphone up to gsm_mic, hence up to DRR.

    The wiring exists (lib/audio.sh: echo canceller osmo_mic_ec, then
    module-loopback osmo_mic_ec -> gsm_mic), but lib/audio.sh only sets the
    volume when the canceller is created; a hardware input at 0 % or a muted
    osmo_mic_ec leaves the DSP with only the tone injected by banc-max. Mute
    and volume are therefore checked again here, at every start of the voice
    port. VSP_MICRO_REEL=0 leaves the microphone as is."""
    if os.environ.get("VSP_MICRO_REEL", "1") == "0":
        return
    sources = [l.split("\t")[1] for l in pactl("list", "short", "sources").splitlines() if "\t" in l]
    materiel = [s for s in sources if s.startswith("alsa_input") and not s.endswith(".monitor")]
    micro = "osmo_mic_ec" if "osmo_mic_ec" in sources else (materiel[0] if materiel else None)
    if not micro:
        journal("micro reel : aucune entree materielle")
        return
    volume = os.environ.get("VSP_MICRO_VOLUME", os.environ.get("EC_MIC_VOLUME", "25%"))
    for s in dict.fromkeys(materiel[:1] + [micro]):
        pactl("set-source-mute", s, "0")
        if " 0%" in pactl("get-source-volume", s) or "/   0%" in pactl("get-source-volume", s):
            pactl("set-source-volume", s, volume)
    boucles = [l for l in pactl("list", "short", "modules").splitlines()
               if "module-loopback" in l and "sink=gsm_mic" in l]
    if not any(f"source={micro} " in l + " " for l in boucles):
        pactl("load-module", "module-loopback", f"source={micro}", "sink=gsm_mic",
              "sink_dont_move=true", "source_dont_move=true", "latency_msec=40")
        journal(f"micro reel : bouclage {micro} -> gsm_mic pose")
    journal(f"micro reel : {micro} -> gsm_mic (sourdine levee, volume {volume} si a 0)")


def main():
    ul, dl = anneau(SHM_UL), anneau(SHM_DL)
    journal(f"{SOURCE} -> {SHM_UL} ; {SHM_DL} -> {SINK} ; gigue {GIGUE} echantillons")
    micro_reel()
    threading.Thread(target=micro, args=(ul,), daemon=True).start()
    haut_parleur(dl)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
