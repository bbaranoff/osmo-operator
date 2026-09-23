import heapq
import logging
import os
import socket
import struct
import threading
import time

from . import gsm

log = logging.getLogger("pont")

# [2026-09-22] L'HORLOGE DU BANC SUIT LE DSP, PAS LE MUR.
#
# En montage DSP le C54x est emule : il coute ~5,8 ms par trame TDMA contre
# 4,615 ms de temps reel. La BTS, elle, tourne sur l'horloge que ce fichier lui
# envoie (IND CLOCK, run_clock). Avec une horloge murale elle emettait 1,25
# trame pour chacune que le DSP consommait : le BSP rejouait un anneau de plus
# en plus vieux (mesure du 2026-09-22 : pont a fn=99674 pendant que le BSP
# jouait la trame BTS 80410, soit 87 s de retard au bout de huit minutes),
# l'IMMEDIATE ASSIGNMENT arrivait apres T3126 et le canal dedie sortait des
# blocs incomplets (« Dropping frame with 110 bit errors »).
#
# c54x_exe publie la trame BTS que son BSP reclame (calypso_bsp.c,
# bsp_horloge_publier). On s'y asservit EN FREQUENCE, pas par recalage : la
# duree effective d'une trame (self.dur) suit la cadence mesuree du DSP, avec
# une correction proportionnelle qui tient l'avance de phase a AVANCE trames.
#
# Pourquoi pas un simple recalage de t0 : essaye d'abord, mesure immediate --
# « UL bursts=11 tard=232 ». Transmitter.run() jette tout burst dont la trame
# s'ecarte de plus de window_tol (1 trame) de l'horloge au moment de l'envoi ;
# une horloge qui avance par a-coups de quelques trames sort de cette fenetre a
# chaque fois. Plus un seul SABM n'arrivait a la BTS, donc plus de UA, donc
# « MDL-ERROR-IND cause 1 » et plus aucune mise a jour de localisation. Une
# horloge asservie doit rester CONTINUE : on ne change que sa vitesse, et on
# rebase t0 a chaque changement pour que fn() ne saute pas.
#
# PONT_HORLOGE=0 revient a l'horloge murale ; le fichier absent (montage sans
# DSP, couche 1 gr-gsm) laisse aussi l'horloge libre, sans rien a configurer.
HORLOGE = "/dev/shm/calypso_horloge"
#
# [2026-09-22] REGLAGE DE LA BOUCLE. Les premieres valeurs (periode 0,25 s,
# rattrapage en 400 trames) donnaient une boucle a ~0,07 Hz, SOUS la cadence a
# laquelle la vitesse du DSP elle-meme bouge. L'asservissement n'arrivait plus
# a suivre : la phase partait en cycle limite de +/- 100 trames, et a chaque
# demi-tour ou l'ecart passait negatif le pont se retrouvait DERRIERE la trame
# reclamee -- 12000 trames entierement sautees sur 120201 ticks, 10 %. Les
# trames perdues ainsi ne sont comptees NULLE PART (ni « tard », ni
# « manques » cote BSP) : c'est ce silence qui m'a fait accuser la
# demodulation du DSP. Mesurer plus souvent et rattraper plus vite remonte la
# boucle a ~1,3 Hz, au-dessus de la perturbation.
# Ne PAS « corriger » ca en augmentant PONT_HORLOGE_AVANCE : ca masque le
# cycle limite derriere une marge, sans le supprimer, et ca retarde tout le
# montant d'autant.
# [2026-09-22, 16:10] REGLABLES PAR L'ENVIRONNEMENT. J'ai change ces valeurs a
# l'aveugle une fois de trop : la premiere mesure apres coup a donne
# manques=2000 sur 10490 ticks (19 %), PIRE que les 10 % d'avant. On les sort
# donc pour pouvoir balayer sans recompiler et choisir sur mesure.
HORLOGE_PERIODE = float(os.environ.get("PONT_HORLOGE_PERIODE", "0.05"))
HORLOGE_KP = float(os.environ.get("PONT_HORLOGE_KP", "1.0"))
HORLOGE_PHASE_N = float(os.environ.get("PONT_HORLOGE_PHASE_N", "100.0"))


class Clock:
    def __init__(self):
        self.t0 = time.monotonic()
        self.dur = gsm.FRAME_DUR
        self._verrou = threading.Lock()
        self._asservie = os.environ.get("PONT_HORLOGE", "1") not in ("0", "", "no")
        self._avance = int(os.environ.get("PONT_HORLOGE_AVANCE", "12"))
        self._fd = None
        self._echeance = 0.0
        self._t_prec = None
        self._dsp_prec = None
        self._dit = False

    def _lire_dsp(self):
        """Trame BTS que le DSP reclame, ou None s'il n'est pas encore cale."""
        try:
            if self._fd is None:
                self._fd = os.open(HORLOGE, os.O_RDONLY)
            b = os.pread(self._fd, 16, 0)
        except OSError:
            if self._fd is not None:
                os.close(self._fd)
                self._fd = None
            return None
        if len(b) < 16:
            return None
        seq, cale, fn_bts, _tick = struct.unpack("<IIII", b)
        return fn_bts % gsm.HYPERFRAME if (seq and cale) else None

    def _reguler(self, now):
        """Appele sous verrou, au plus une fois par HORLOGE_PERIODE."""
        if now < self._echeance:
            return
        self._echeance = now + HORLOGE_PERIODE
        dsp = self._lire_dsp()
        if dsp is None:
            self._t_prec = self._dsp_prec = None
            return
        if not self._dit:
            self._dit = True
            log.info("horloge asservie au DSP (%s, avance visee %d trames)", HORLOGE, self._avance)
        t_prec, dsp_prec = self._t_prec, self._dsp_prec
        self._t_prec, self._dsp_prec = now, dsp
        if t_prec is None:
            return
        avancees = (dsp - dsp_prec) % gsm.HYPERFRAME
        if avancees <= 0 or avancees > gsm.HYPERFRAME // 2:
            return                                   # DSP arrete ou recale : on garde la vitesse
        dur_dsp = (now - t_prec) / avancees          # cadence mesuree du DSP
        # Ecart de phase, en trames, signe : > 0 = l'horloge du banc devance.
        f = (now - self.t0) / self.dur
        ecart = (int(f) - (dsp + self._avance)) % gsm.HYPERFRAME
        if ecart > gsm.HYPERFRAME // 2:
            ecart -= gsm.HYPERFRAME
        cible = dur_dsp * (1.0 + HORLOGE_KP * ecart / HORLOGE_PHASE_N)
        cible = min(max(cible, gsm.FRAME_DUR * 0.5), gsm.FRAME_DUR * 4.0)
        dur = 0.7 * self.dur + 0.3 * cible
        self.t0 = now - f * dur                      # rebase : fn() reste continue
        self.dur = dur

    def fn(self):
        now = time.monotonic()
        if not self._asservie:
            return int((now - self.t0) / self.dur) % gsm.HYPERFRAME
        with self._verrou:
            self._reguler(now)
            return int((now - self.t0) / self.dur) % gsm.HYPERFRAME

    def time_of(self, fn):
        now = time.monotonic()
        if self._asservie:
            with self._verrou:
                self._reguler(now)
                t0, dur = self.t0, self.dur
        else:
            t0, dur = self.t0, self.dur
        cur = int((now - t0) / dur)
        delta = (fn - cur) % gsm.HYPERFRAME
        if delta > gsm.HYPERFRAME // 2:
            delta -= gsm.HYPERFRAME
        return t0 + (cur + delta) * dur

    def sleep_until_fn(self, fn):
        dt = self.time_of(fn) - time.monotonic()
        if dt > 0:
            time.sleep(dt)


def _udp(bind_host, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((bind_host, port))
    return s


class Trx:
    def __init__(self, cfg, clock, stats, cipher, record, dedicated=None, tch=None):
        self.cfg = cfg
        self.clock = clock
        self.stats = stats
        self.cipher = cipher
        self.record = record
        self.dedicated = dedicated
        self.tch = tch
        self.sk_clck = _udp(cfg.trx_bind, cfg.trx_base)
        self.sk_ctrl = _udp(cfg.trx_bind, cfg.trx_base + 1)
        self.sk_data = _udp(cfg.trx_bind, cfg.trx_base + 2)
        self.bts_data = None
        self.bts_clck = None

    def run_ctrl(self):
        while True:
            data, addr = self.sk_ctrl.recvfrom(1500)
            req = data.decode("latin1").strip("\0").strip()
            if not req.startswith("CMD"):
                continue
            parts = req.split()
            cmd = parts[1] if len(parts) > 1 else ""
            args = (" " + " ".join(parts[2:])) if len(parts) > 2 else ""
            self.sk_ctrl.sendto(("RSP %s 0%s" % (cmd, args)).encode() + b"\0", addr)
            if self.bts_clck is None:
                self.bts_clck = (addr[0], self.cfg.trx_base + 100)
                log.info("BTS %s : horloge armee vers le port %d", addr[0], self.bts_clck[1])
            if cmd not in ("SETPOWER", "NOHANDOVER"):
                log.info("CTRL %s%s", cmd, args)

    def run_clock(self):
        while True:
            if self.bts_clck:
                self.sk_clck.sendto(("IND CLOCK %u" % self.clock.fn()).encode() + b"\0", self.bts_clck)
            time.sleep(gsm.FRAME_DUR * self.cfg.clock_period)

    def run_data(self, on_burst):
        while True:
            data, addr = self.sk_data.recvfrom(2000)
            self.bts_data = addr
            if len(data) < 6 + 148:
                continue
            tn = data[0] & 0x07
            fn = struct.unpack_from(">L", data, 1)[0]
            bits = gsm.normalize_bits(data[6:154])
            if self.cfg.dsp_port:
                # [2026-09-17] Le meme burst, tel que le BSP du DSP l'attend
                # (calypso_bsp.c bsp_trxd_readable) : 8 octets d'en-tete
                # [tn, fn BE32, attenuation, 0, 0] puis 148 bits 0/1. Le BSP les
                # convertit lui-meme en I/Q (table cos) et les depose en DARAM.
                #
                # [2026-09-22] LE DESCENDANT DU CANAL DEDIE EST DECHIFFRE ICI.
                # Asymetrie constatee : send_ul() CHIFFRE le montant (le pont
                # tient la place de la voie d'emission du DSP), mais le
                # descendant partait brut vers le DSP. Or il n'y a aucun A5
                # dans le modele Calypso -- `d_a5mode` n'existe que dans
                # l1-grgsm/, rien dans l1-dsp/ : personne ne dechiffre.
                # Mesure du 2026-09-22 (ENCRYPTION="a5 1") : la transaction
                # allait plus loin que jamais -- SABM/UA, IDENTITY, puis
                # AUTHENTICATION REQUEST/RESPONSE, tout en clair -- et la
                # tempete de « Dropping frame with 96 bit errors » commencait
                # a la ligne EXACTE du `CIPHERING MODE COMPLETE`, pour ne plus
                # s'arreter. En « a5 0 » la meme transaction va au bout.
                # A5 est symetrique : appliquer le flux descendant dechiffre.
                # SEULEMENT sur l'intervalle dedie : la BCCH et la CCCH ne sont
                # jamais chiffrees, les toucher detruirait le campement.
                bits_dsp = bits
                if self.cipher.dl_active and self._burst_dedie(tn, fn):
                    bits_dsp = self.cipher.apply(bits, fn, False)
                hdr = bytes([tn & 0x07]) + struct.pack(">L", fn) + bytes([data[5] if len(data) > 5 else 0, 0, 0])
                self.sk_data.sendto(hdr + bytes(1 if b else 0 for b in bits_dsp), ("127.0.0.1", self.cfg.dsp_port))
            on_burst(tn, fn, bits)

    def _burst_dedie(self, tn, fn):
        """Vrai si CE burst appartient au canal dedie du mobile.

        [2026-09-22] Le test portait sur le seul intervalle (`tn == tn_dedie`).
        En CCCH+SDCCH/4 le canal dedie vit sur TS0, celui qui porte AUSSI la
        FCCH, la SCH, la BCCH et la CCCH -- jamais chiffrees, par definition :
        le mobile doit pouvoir les lire avant d'avoir une cle. Des que A5
        s'activait, tout TS0 partait donc XORe vers le DSP et le campement se
        defaisait sous les pieds de la transaction en cours. En SDCCH/8 sur un
        intervalle a lui le defaut ne se voyait pas, d'ou son age.
        On refait ici le meme tri que Downlink._signalling : le bloc doit etre
        celui du sous-canal `ss` du mobile, SDCCH ou SACCH.
        Lecture mise en cache par Dedicated (DCCH_TTL), donc appelable a chaque
        burst."""
        if self.tch is not None and self.tch.is_open():
            # Sur un TCH assigne tout l'intervalle est a la transaction (trafic,
            # FACCH et SACCH) : pas de sous-canal a trier.
            if tn == self.tch.active_tn():
                return True
        if self.dedicated is None:
            return False
        ded = self.dedicated.plan()
        if ded is None:
            return False
        plan, ss, tn_ded = ded
        if tn != tn_ded:
            return False
        m51 = fn % 51
        base = next((b for b in plan.ded_bases if b <= m51 <= b + 3), None)
        if base is None:
            return False
        ss %= plan.n_sub
        if base in plan.sdcch_dl:
            return base == plan.sdcch_dl[ss]
        return (fn - (m51 - base)) % 102 == plan.sacch_dl102[ss]

    def send_ul(self, tn, fn, burst, cipher):
        if self.bts_data is None:
            return
        if cipher:
            burst = self.cipher.apply(burst, fn, True)
        hdr = bytes([tn & 0x07]) + struct.pack(">L", fn) + bytes([self.cfg.rssi & 0xFF]) + struct.pack(">h", 0)
        self.sk_data.sendto(hdr + bytes(255 if b else 0 for b in burst), self.bts_data)
        self.stats.ul_sent += 1
        if self.record:
            self.record.feed_ul(fn, tn, burst)


class Transmitter(threading.Thread):
    def __init__(self, cfg, clock, trx, stats):
        super().__init__(name="tx", daemon=True)
        self.cfg = cfg
        self.clock = clock
        self.trx = trx
        self.stats = stats
        self.cond = threading.Condition()
        self.heap = []
        self.seq = 0

    def schedule(self, tn, fn_air, burst, cipher, essais=0):
        post = self.clock.time_of((fn_air - self.cfg.ul_fn_advance) % gsm.HYPERFRAME)
        with self.cond:
            self.seq += 1
            heapq.heappush(self.heap, (post, self.seq, tn, fn_air, burst, cipher, essais))
            self.cond.notify()

    def run(self):
        while True:
            with self.cond:
                while not self.heap:
                    self.cond.wait()
                post = self.heap[0][0]
                dt = post - time.monotonic()
                if dt > 0:
                    self.cond.wait(dt)
                    continue
                _, _, tn, fn_air, burst, cipher, essais = heapq.heappop(self.heap)
            cur = self.clock.fn()
            off = (fn_air - (cur + self.cfg.ul_fn_advance) + gsm.HYPERFRAME // 2) % gsm.HYPERFRAME - gsm.HYPERFRAME // 2
            # [2026-09-22] TROP TOT N'EST PAS TROP TARD.
            # `post` est calcule a la mise en file, a partir de la cadence de
            # l'horloge A CE MOMENT-LA. Depuis que celle-ci suit le DSP (voir
            # Clock plus haut), elle n'avance plus au rythme du mur : le DSP
            # marque le pas, l'horloge avec lui, et le reveil tombe avant que la
            # trame visee ne soit arrivee. Le burst etait alors compte « en
            # retard » et JETE, alors qu'il etait en avance.
            # Mesure du 2026-09-22 : « UL bursts=116 tard=18 », 13 % des bursts
            # montants perdus. Un bloc en demande quatre : ~40 % des blocs
            # montants n'arrivaient pas entiers a la BTS. C'est exactement ce
            # qu'on voyait en bout de chaine -- TMSI REALLOCATION COMPLETE et
            # CP-ACK jamais recus, SABM retransmis par T200.
            # On re-attend donc, avec un `post` recalcule sur l'horloge
            # courante ; seul un burst VRAIMENT en retard est perdu.
            if off > self.cfg.window_tol:
                if essais < self.cfg.window_essais:
                    self.schedule(tn, fn_air, burst, cipher, essais + 1)
                else:
                    self.stats.ul_late += 1
                continue
            if off < -self.cfg.window_tol:
                # [2026-09-23] EN RETARD N'EST PAS PERDU. osmo-bts-trx range un
                # burst montant par SON fn, compare au dernier fn traite du meme
                # canal logique (scheduler.c, trx_sched_route_burst_ind) ; l'heure
                # d'arrivee n'y entre pas -- un vrai transceiver livre toujours le
                # montant apres coup. Le jeter ici ne protegeait donc rien, et
                # coutait cher : 141 bursts emis pour 314 jetes (69 %) sur le run
                # de 11:04, chaque trame LAPDm retransmise 2 a 5 fois par T200,
                # le SMS MT a 12 s au lieu de 2. Le retard vient du reveil du
                # thread (GIL partage avec l'enregistrement I/Q) et des variations
                # de l'horloge asservie au DSP, pas du BTS.
                # On l'envoie tant qu'il reste dans la multitrame (la BTS refuse
                # au-dela de mf_period, « Too many contiguous TDMA frames »).
                # PONT_UL_RETARD_MAX=0 retablit l'ancien comportement (jeter).
                self.stats.ul_late += 1
                if -off > self.cfg.ul_retard_max:
                    continue
            self.trx.send_ul(tn, fn_air, burst, cipher)
