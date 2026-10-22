"""voix_hote.py - [2026-10-22] la voix du C139 Magnetite codee par l'hote (PONT_VOIX_HOTE=1).

Le vocodeur de la mask-ROM ne tient pas encore : le C54x emule tourne a ~9,5 ms par trame
quand le codec FR tourne (budget 4,62 ms), la ROM decode le TCH descendant en BFI (parole,
FACCH, SACCH) et ne remplit jamais a_du. Le pont, lui, decode deja chaque trame FR que la BTS
envoie (Downlink._tch) et code deja le TCH montant (TchScheduler). Il ne manquait que le PCM :

    DL : trame FR de la BTS --libgsm--> anneau /dev/shm/pont_voix_dl --pacat--> gsm_audio
    UL : gsm_mic.monitor --parec--> anneau /dev/shm/pont_voix_ul --libgsm--> uplink.q_voice

Le DSP ne fait plus que le canal : CALYPSO_VSP=0 (pas de port voix, pas de codec ROM). Active
par --gapk avec --ms-magnetite (startup_scripts/14-demarrage.sh). Les trames FR sont au format
de libosmocoding net_order=1 (TS 101 318, quartet 0xD en tete), celui de libgsm.
"""
import ctypes
import logging
import os
import struct
import threading
import time

from . import vsp_audio

log = logging.getLogger("pont")

SHM_UL = os.environ.get("PONT_VOIX_SHM_UL", "/dev/shm/pont_voix_ul")
SHM_DL = os.environ.get("PONT_VOIX_SHM_DL", "/dev/shm/pont_voix_dl")
N = vsp_audio.N
ECH = 160                                   # 20 ms a 8 kHz, une trame FR

_gsm = ctypes.CDLL("libgsm.so.1")
_gsm.gsm_create.restype = ctypes.c_void_p
_gsm.gsm_decode.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_short)]
_gsm.gsm_encode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_short), ctypes.c_char_p]


class VoixHote:
    """Remplace l'anneau TCH descendant du pont DSP (DownlinkDsp.ring) : publish() recoit chaque
    trame FR decodee de la BTS. Un fil code le micro et alimente le TCH montant."""

    def __init__(self, uplink, tch, stats):
        self.uplink = uplink
        self.tch = tch
        self.stats = stats
        self.dec = _gsm.gsm_create()
        self.enc = _gsm.gsm_create()
        self.ul = vsp_audio.anneau(SHM_UL)
        self.dl = vsp_audio.anneau(SHM_DL)
        self.pcm = (ctypes.c_short * ECH)()
        self.n_dl = self.n_dl_ko = self.n_ul = 0
        # une seule source pour la parole montante : plus celle de montant.c (a_du, /dev/shm/calypso_tch_ul)
        uplink._poll_voice = lambda: None

    # -- descendant ----------------------------------------------------------------------------
    def publish(self, fr33, fn):
        if len(fr33) != 33 or _gsm.gsm_decode(self.dec, bytes(fr33), self.pcm) != 0:
            self.n_dl_ko += 1
            return
        w = struct.unpack_from("<I", self.dl, 0)[0]
        for i in range(ECH):
            struct.pack_into("<h", self.dl, 8 + 2 * ((w + i) % N), self.pcm[i])
        struct.pack_into("<I", self.dl, 0, (w + ECH) & 0xFFFFFFFF)   # compteur en dernier
        self.n_dl += 1

    # -- montant -------------------------------------------------------------------------------
    def _codeur(self):
        lu = struct.unpack_from("<I", self.ul, 0)[0]
        pcm = (ctypes.c_short * ECH)()
        out = ctypes.create_string_buffer(33)
        while True:
            w = struct.unpack_from("<I", self.ul, 0)[0]
            dispo = (w - lu) & 0xFFFFFFFF
            if dispo > N // 2:                       # retard (pont arrete, parec en rafale) : rattraper
                lu = (w - ECH) & 0xFFFFFFFF
                dispo = ECH
            if dispo < ECH:
                time.sleep(0.005)
                continue
            for i in range(ECH):
                pcm[i] = struct.unpack_from("<h", self.ul, 8 + 2 * ((lu + i) % N))[0]
            lu = (lu + ECH) & 0xFFFFFFFF
            if not self.tch.is_open():
                continue
            _gsm.gsm_encode(self.enc, pcm, out)
            with self.uplink.q_lock:
                if len(self.uplink.q_voice) == self.uplink.q_voice.maxlen:
                    self.stats.tch_ul_dropped += 1
                self.uplink.q_voice.append(out.raw)
            self.stats.tch_ul += 1
            self.n_ul += 1

    def _bilan(self):
        while True:
            time.sleep(30)
            log.info("voix hote : DL %d trames jouees (%d illisibles), UL %d trames codees en 30 s",
                     self.n_dl, self.n_dl_ko, self.n_ul)
            self.n_dl = self.n_dl_ko = self.n_ul = 0

    def start(self):
        vsp_audio.micro_reel()
        for nom, cible, args in (("voix-micro", vsp_audio.micro, (self.ul,)),
                                 ("voix-hp", vsp_audio.haut_parleur, (self.dl,)),
                                 ("voix-codeur", self._codeur, ()),
                                 ("voix-bilan", self._bilan, ())):
            threading.Thread(name=nom, target=cible, args=args, daemon=True).start()
        log.info("voix hote : FR de la BTS -> %s -> %s ; %s -> %s -> TCH montant (libgsm)",
                 SHM_DL, vsp_audio.SINK, vsp_audio.SOURCE, SHM_UL)
