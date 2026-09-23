import collections
import ctypes
import logging
import os
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")

SB_RACH = "/dev/shm/calypso_rach"
SB_SDCCH_UL = "/dev/shm/calypso_sdcch_ul"
SB_FACCH_UL = "/dev/shm/calypso_tch_facch_ul"
SB_SACCH_UL = "/dev/shm/calypso_tch_sacch_ul"
SB_TCH_UL = "/dev/shm/calypso_tch_ul"
TCH_UL_SLOT = 64
TCH_UL_FR_OFS = 16
POLL = gsm.FRAME_DUR / 8
TX_BURSTS = 24
BPLEN = 116
RELEASE_FALLBACK = 20.0
# Combien de temps garder un bloc SDCCH montant en attendant de connaitre le
# canal dedie (cf. _poll_sdcch).
SDCCH_ATTENTE = 1.0


class Sideband:
    def __init__(self, path, size):
        self.path = path
        self.size = size
        self.fd = None
        self.seq = 0

    def read(self):
        try:
            if self.fd is None:
                self.fd = os.open(self.path, os.O_RDONLY)
            return os.pread(self.fd, self.size, 0)
        except OSError:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            return b""

    def new_record(self):
        b = self.read()
        if len(b) < self.size:
            return None
        seq = struct.unpack_from("<I", b, 0)[0]
        if not seq or seq == self.seq:
            return None
        self.seq = seq
        return b

    def skip_pending(self):
        b = self.read()
        if len(b) >= 4:
            self.seq = struct.unpack_from("<I", b, 0)[0]


class TchUplinkRing:
    def __init__(self):
        self.fd = None
        self.last = 0

    def drain(self):
        try:
            if self.fd is None:
                self.fd = os.open(SB_TCH_UL, os.O_RDONLY)
            hdr = os.pread(self.fd, 8, 0)
        except OSError:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            return [], 0
        if len(hdr) < 8:
            return [], 0
        w, n = struct.unpack("<II", hdr)
        if not w or not n:
            return [], 0
        lost = 0
        if self.last == 0:
            self.last = w
        elif (w - self.last) > n:
            lost = (w - self.last) - n
            self.last = w - n
        frames = []
        while self.last < w:
            self.last += 1
            sl = os.pread(self.fd, TCH_UL_SLOT, 8 + ((self.last - 1) % n) * TCH_UL_SLOT)
            if len(sl) >= TCH_UL_FR_OFS + gsm.FR_BYTES:
                frames.append(sl[TCH_UL_FR_OFS:TCH_UL_FR_OFS + gsm.FR_BYTES])
        return frames, lost


class Uplink(threading.Thread):
    def __init__(self, cfg, clock, stats, dedicated, tch, transmitter, feeder, cipher):
        super().__init__(name="uplink", daemon=True)
        self.cfg = cfg
        self.clock = clock
        self.stats = stats
        self.dedicated = dedicated
        self.tch = tch
        self.cipher = cipher
        self.ded_active = False
        self.tx = transmitter
        self.feed = feeder
        self.sb_rach = Sideband(SB_RACH, 12)
        self.sb_sdcch = Sideband(SB_SDCCH_UL, 39)
        self.sb_facch = Sideband(SB_FACCH_UL, 39)
        self.sb_sacch = Sideband(SB_SACCH_UL, 39)
        self.ring = TchUplinkRing()
        self.q_lock = threading.Lock()
        self.q_facch = collections.deque(maxlen=8)
        self.q_voice = collections.deque(maxlen=4)
        self.sacch_l2 = None
        self.tch_epoch = -1
        self.sdcch_attente = None
        for sb in (self.sb_rach, self.sb_sdcch, self.sb_facch, self.sb_sacch):
            sb.skip_pending()

    def _next_fn(self, min_advance, accept):
        start = self.clock.fn() + min_advance
        for k in range(104):
            fn = (start + k) % gsm.HYPERFRAME
            if accept(fn):
                return fn
        return start % gsm.HYPERFRAME

    def _queue_facch(self, l2):
        with self.q_lock:
            self.q_facch.append(bytes(l2[:gsm.MACBLOCK_LEN]))
        self.stats.facch_ul += 1
        self.feed.l2(self.clock.fn(), gsm.GSMTAP_TCH_F, l2[:gsm.MACBLOCK_LEN], self.tch.active_tn() or 0, True)

    def _poll_rach(self):
        b = self.sb_rach.new_record()
        if b is None:
            return
        _, ra, bsic, fn = struct.unpack_from("<IBBxxI", b, 0)
        burst = gsm.rach_burst(ra, bsic)
        self.tx.schedule(0, self._next_fn(4, lambda f: f % 51 in gsm.RACH_SLOTS_51), burst, False)
        self.stats.rach += 1

    def _route_sdcch(self, l2):
        """Vrai si le bloc SDCCH montant part en FACCH (consomme ici).

        [2026-09-23] Extrait tel quel de _poll_sdcch pour que le pont DSP
        (pont/dsp/uplink.py) le surcharge ; le montage grgsm garde ce code."""
        tn_tch = self.tch.active_tn()
        if tn_tch is not None and not self.tch.is_open():
            if gsm.rr_message_type(l2)[1] == gsm.RR_ASSIGNMENT_COMPLETE:
                self.tch.prove("ASSIGNMENT COMPLETE")
                self._queue_facch(l2)
                return True
        elif self.tch.is_open():
            self._queue_facch(l2)
            return True
        return False

    def _poll_sdcch(self):
        b = self.sb_sdcch.new_record()
        if b is not None:
            l2 = b[16:39]
            if self._route_sdcch(l2):
                return
            # [2026-09-21] Le bloc ATTEND que le canal soit connu, il n'est
            # plus jete. La couche 1 publie le SABM au moment meme ou elle
            # l'emet, et le canal dedie n'est lu ici qu'au plus toutes les
            # DCCH_TTL secondes : le premier bloc d'une connexion tombait
            # regulierement dans cette fenetre et disparaissait, le BTS
            # attendait son SABM jusqu'au Timeout. On relit le canal tout de
            # suite et on garde le bloc un instant s'il n'est pas encore arme.
            self.sdcch_attente = (l2, time.monotonic())
            self.dedicated.refresh()
        if self.sdcch_attente is None:
            return
        l2, depuis = self.sdcch_attente
        ded = self.dedicated.plan()
        if ded is None:
            if time.monotonic() - depuis > SDCCH_ATTENTE:
                log.info("SDCCH montant : aucun canal dedie apres %.1f s, bloc abandonne",
                         SDCCH_ATTENTE)
                self.sdcch_attente = None
            return
        self.sdcch_attente = None
        plan, ss, tn = ded

        # [2026-09-21] SDCCH ou SACCH ? La couche 1 ne peut pas le dire : le
        # firmware pose les deux dans le MEME tampon a_cu avec le MEME mot de
        # tache (prim_tx_nb.c:118, dsp_load_tx_task(DUL_DSP_TASK) dans les deux
        # cas) ; seul son drapeau interne MF_F_SACCH les separe, et il ne sort
        # jamais dans l'API RAM. C'est donc ici, sur la FORME du bloc, que ca se
        # tranche : un bloc SDCCH commence par l'adresse LAPDm (0x01 ou 0x03),
        # un bloc SACCH par ses deux octets d'en-tete L1 (puissance ordonnee,
        # TA), l'adresse ne venant qu'en position 2.
        #
        # Releve du banc, les deux blocs qui alternaient sur la voie SDCCH :
        #   01 3f 49 05 08 70 ...  -> SABM + LOCATION UPDATING REQUEST
        #   07 00 01 03 49 06 15   -> en-tete L1 (pwr 7, TA 0) + MEASUREMENT REPORT
        # Le second partait sur les trames SDCCH montantes, et la SACCH
        # montante restait vide : le BTS ne voyait plus rien sur sa liaison
        # lente et lachait le canal quelques secondes apres l'etablissement.
        #
        # [2026-09-23] Et le SAPI 3 ? Son adresse LAPDm est 0x0d / 0x0f, et une
        # trame SAPI 3 sans information (UA, SABM, RR, DISC) porte en position 2
        # un indicateur de longueur L=0, soit 0x01 -- exactement ce que le test
        # ci-dessus prenait pour l'adresse SAPI 0 d'un bloc SACCH. Releve du
        # banc, MT SMS vers le mobile du pont :
        #   0f 73 01 2b 2b ...     -> UA SAPI 3 (reponse au SABM du BTS)
        # parti sur la SACCH montante : le BTS le decodait en « Unknown (SS) »,
        # n'etablissait jamais le SAPI 3, et le CP-DATA du SMS ne partait pas
        # (MSC : WAIT_CP_ACK puis abandon au bout de 7 s, a chaque essai).
        # Octet 0 = 0x0d / 0x0f est ambigu (puissance 13 / 15 d'un en-tete
        # SACCH) : on ne tranche SACCH que si la lecture SACCH tient debout --
        # TA <= 63 (6 bits) et un vrai champ de controle LAPDm en position 3,
        # pas le bourrage 0x2b qui suit une trame SAPI 3 vide.
        sacch = l2[0] not in (0x01, 0x03) and l2[2] in (0x01, 0x03)
        if sacch and l2[0] in (0x0d, 0x0f):
            sacch = l2[1] <= 63 and l2[3] != 0x2b
        if sacch:
            base = (plan.sacch_dl102[ss % plan.n_sub] + 15) % 102
            fn0 = self._next_fn(4, lambda f: f % 102 == base)
            self.feed.l2(self.clock.fn(), gsm.GSMTAP_SACCH, l2, tn, True)
            self.stats.sacch_ul += 1
        else:
            base = plan.ul_base(ss)
            fn0 = self._next_fn(4, lambda f: f % 51 == base)
            self.feed.l2(self.clock.fn(), gsm.GSMTAP_SDCCH4, l2, tn, True)
        for j, burst in enumerate(gsm.xcch_encode(l2)):
            self.tx.schedule(tn, (fn0 + j) % gsm.HYPERFRAME, burst, True)

    def _poll_facch(self):
        tn = self.tch.active_tn()
        if tn is None:
            self.tch_epoch = -1
            return
        if self.tch_epoch != self.tch.seq:
            # [2026-09-22] NE PLUS JETER LA PREMIERE FACCH APRES L'ARMEMENT.
            #
            # `skip_pending()` avance le curseur sur TOUT ce qui est deja ecrit
            # dans la bande laterale, et le `return` sortait sans rien traiter.
            # Or `tch.seq` est incremente par `tch.arm()`, appele quand le pont
            # decode l'ASSIGNMENT COMMAND descendante -- et l'ASSIGNMENT
            # COMPLETE est justement LA PREMIERE chose que le mobile emet sur le
            # nouveau TCH. Elle tombait donc exactement dans cette fenetre et
            # etait marquee « deja vue ».
            #
            # Mesure du 2026-09-22, appel vers 600 : le mobile emet bien
            # « ASSIGNMENT COMPLETE (cause #0) » (gsm48_rr.c:4720, 18:55:47),
            # le pont journalise « FACCH montante » SANS le suffixe
            # « , ASSIGNMENT COMPLETE » -- donc ce n'etait pas elle -- et le BSC
            # conclut « Assignment failed in state WAIT_RR_ASS_COMPLETE, cause
            # EQUIPMENT FAILURE: Timeout » (assignment_fsm.c:1057).
            #
            # On garde le saut pour la SACCH (un rapport de mesure perime ne
            # sert a rien) mais on TRAITE la FACCH en attente. Le risque
            # residuel -- rejouer une FACCH de la session precedente -- est
            # borne a un bloc et LAPDm le rejettera, la ou perdre l'ASSIGNMENT
            # COMPLETE fait echouer l'appel a tous les coups.
            # PONT_FACCH_SKIP=1 retablit l'ancien comportement.
            self.tch_epoch = self.tch.seq
            self.sb_sacch.skip_pending()
            if os.environ.get("PONT_FACCH_SKIP", "0") == "1":
                self.sb_facch.skip_pending()
                return
        b = self.sb_facch.new_record()
        if b is None:
            return
        l2 = b[16:39]
        self.tch.prove("FACCH montante%s" % (", ASSIGNMENT COMPLETE" if gsm.rr_message_type(l2)[1] == gsm.RR_ASSIGNMENT_COMPLETE else ""))
        self._queue_facch(l2)

    def _poll_sacch(self):
        b = self.sb_sacch.new_record()
        if b is None:
            return
        self.sacch_l2 = bytes(b[16:39])
        self.stats.sacch_ul += 1

    def _poll_release(self):
        active = self.dedicated.plan() is not None
        if self.ded_active and not active:
            reason = "canal libere par le mobile"
        elif self.tch.release_overdue(RELEASE_FALLBACK):
            reason = "CHANNEL RELEASE sans liberation du mobile depuis %ds" % RELEASE_FALLBACK
        else:
            self.ded_active = active
            return
        self.ded_active = active
        self.tch.close(reason)
        self.cipher.release(reason)

    def _poll_voice(self):
        if not self.tch.is_open():
            return
        frames, lost = self.ring.drain()
        self.stats.tch_ul_dropped += lost
        for fr in frames:
            with self.q_lock:
                if len(self.q_voice) == self.q_voice.maxlen:
                    self.stats.tch_ul_dropped += 1
                self.q_voice.append(bytes(fr))
            self.stats.tch_ul += 1

    def run(self):
        while True:
            self._poll_release()
            self._poll_rach()
            self._poll_sdcch()
            self._poll_facch()
            self._poll_sacch()
            self._poll_voice()
            time.sleep(POLL)


class TchScheduler(threading.Thread):
    def __init__(self, cfg, clock, stats, tch, uplink, transmitter):
        super().__init__(name="tch-tx", daemon=True)
        self.cfg = cfg
        self.clock = clock
        self.stats = stats
        self.tch = tch
        self.uplink = uplink
        self.tx = transmitter
        self.buf = (gsm.ubit * (TX_BURSTS * BPLEN))()
        self.mask = 0
        self.sent_sacch_block = None
        tch.on_close.append(self._reset)

    def _reset(self):
        ctypes.memset(self.buf, 0, TX_BURSTS * BPLEN)
        self.mask = 0
        self.sent_sacch_block = None
        with self.uplink.q_lock:
            self.uplink.q_facch.clear()
            self.uplink.q_voice.clear()

    def _load_block(self):
        ctypes.memmove(self.buf, ctypes.byref(self.buf, 4 * BPLEN), 20 * BPLEN)
        ctypes.memset(ctypes.byref(self.buf, 20 * BPLEN), 0, 4 * BPLEN)
        self.mask = (self.mask << 4) & 0xFFFFFFFF
        with self.uplink.q_lock:
            facch = self.uplink.q_facch.popleft() if self.uplink.q_facch else None
            voice = self.uplink.q_voice.popleft() if self.uplink.q_voice else None
        gsm.tch_fr_encode_into(self.buf, facch if facch is not None else voice)

    def _sacch(self, tn, fn_air):
        if not gsm.sacch_tf_block_start(fn_air, tn):
            return
        block = fn_air - (fn_air % 104)
        if self.uplink.sacch_l2 is None or self.sent_sacch_block == block:
            return
        self.sent_sacch_block = block
        for j, burst in enumerate(gsm.xcch_encode(self.uplink.sacch_l2)):
            self.tx.schedule(tn, (fn_air + 26 * j) % gsm.HYPERFRAME, burst, True)

    def run(self):
        fn_air = None
        while True:
            tn = self.tch.active_tn()
            if tn is None or not self.tch.is_open():
                fn_air = None
                time.sleep(0.05)
                continue
            if fn_air is None:
                fn_air = (self.clock.fn() + self.cfg.ul_fn_advance + 1) % gsm.HYPERFRAME
            else:
                fn_air = (fn_air + 1) % gsm.HYPERFRAME
            self.clock.sleep_until_fn((fn_air - self.cfg.ul_fn_advance) % gsm.HYPERFRAME)
            self._sacch(tn, fn_air)
            if not gsm.is_tch_carrier(fn_air):
                continue
            bid = gsm.tch_burst_index(fn_air) % 4
            if bid == 0:
                self._load_block()
            elif not (self.mask & 0x01):
                continue
            base = bid * BPLEN
            burst = gsm.burst_from_coded(bytes(self.buf)[base:base + BPLEN])
            self.mask |= 1 << bid
            self.tx.schedule(tn, fn_air, burst, True)
            self.stats.tch_ul_bursts += 1
