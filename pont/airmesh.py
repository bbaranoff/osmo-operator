#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# airmesh.py - le maillage se fait SUR LES BURSTS, plus sur les appels.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE CA CHANGE
#
# Jusqu'ici deux noeuds du banc se parlaient tout en haut de la pile : un trunk
# SIP entre deux Asterisk, un relais SMS en TCP, et du M3UA vers un hub. Chaque
# noeud avait sa propre radio, hermetique : le mobile de l'operateur 1 ne
# POUVAIT PAS entendre la BTS de l'operateur 2, parce que les bursts des deux
# ne se croisaient nulle part. Ce qu'on appelait "roaming" etait un
# raccordement telephonique entre deux reseaux qui s'ignoraient.
#
# Ici, ce qui traverse le reseau, c'est le burst. Le milieu radio devient
# commun : la BTS du noeud 2 emet, le mobile du noeud 1 l'entend, se cale
# dessus, lit ses SI, et fait sa mise a jour de localisation POUR DE VRAI. Tout
# le reste - BSC, MSC, HLR, MGW, Asterisk - reste enferme dans son noeud. Seul
# l'air est partage.
#
# ─────────────────────────────────────────────────────────────────────────────
# QUI FAIT QUOI : QEMU emet les bursts, fake_trx traduit, airmesh transporte
#
# Les bursts ne sont pas fabriques ici. Ils viennent du Calypso qui tourne dans
# QEMU : le firmware module, pont.py recupere ce que l'ARM depose dans ses
# sidebands, l'encode en bursts et le pose en TRXD. Dans l'autre sens il decode
# le descendant de la BTS et le rend au firmware. C'est LA la radio.
#
# fake_trx.py est le TRADUCTEUR de noeud : un commutateur de bursts qui relie N
# transceivers et distribue ce que l'un EMET a tous ceux dont la frequence de
# RECEPTION correspond (burst_fwd.py, forward_msg). Il ne fabrique rien, il
# aiguille.
#
# airmesh est le transport entre noeuds. Il se branche sur le traducteur, prend
# ce qui y passe, l'envoie aux pairs, et injecte ce qui en revient.
#
#     ┌──────────────────────── un noeud ─────────────────────────┐
#     │   QEMU/Calypso ──sidebands── pont.py ──TRXD 5700──┐       │
#     │   osmo-bts-trx ───────────────────────TRXD 5700───┤       │
#     │   trxcon/mobile ──────────────────────TRXD 6700───┤ fake  │
#     │   airmesh(cote mobile) ───────────────TRXD 6706───┤ _trx  │
#     │   airmesh(cote BTS) ──────────────────TRXD 6709───┘       │
#     └───────────────────────────┬───────────────────────────────┘
#                                 │  UDP AIRM (defaut 4739)
#                 ┌───────────────┴───────────────┐
#              noeud 2                         noeud 3
#
# POURQUOI DEUX BRANCHEMENTS. fake_trx apparie sur la FREQUENCE : un
# transceiver n'entend que ce qui est emis sur sa frequence de reception. Un
# seul point d'accroche n'entendrait donc qu'un sens, et un mobile qui n'entend
# pas la BTS ne s'y attache jamais.
#   - cote mobile : rx = descendant, tx = montant. Il ENTEND ce que la BTS
#     locale emet, et INJECTE le montant des mobiles distants vers elle.
#   - cote BTS    : rx = montant, tx = descendant. Il ENTEND ce que les mobiles
#     locaux emettent, et INJECTE le descendant des BTS distantes vers eux.
#
# ─────────────────────────────────────────────────────────────────────────────
# COMMENT ON S'Y BRANCHE SANS MODIFIER UNE LIGNE DE QEMU-SRC
#
# fake_trx cree un transceiver de plus par mobile declare (60-fake-trx.sh :
# --trx ue<n>@127.0.0.<g>:<port>, port = 6700 + (n-1) * 3). Ces transceivers ne
# sont "des mobiles" que par leur nom : fake_trx ne leur connait ni role ni
# bande tant qu'ils n'ont pas envoye RXTUNE et TXTUNE.
#
# On declare donc DEUX mobiles de plus que le banc n'en a - N_MS + 2 - et
# airmesh prend leurs deux places. Il accorde la premiere comme un mobile et la
# seconde a l'envers, comme une BTS. Aucune modification du lanceur, aucun
# fichier de qemu-src touche : deux emplacements deja prevus, occupes autrement.
#
# CE QU'IL FAUT SAVOIR EN LES LISANT : `pgrep -a fake_trx` montrera deux
# mobiles qui n'existent pas, et le journal de fake_trx annoncera ue3 et ue4.
# C'est voulu. Le nom vient du lanceur, pas de nous.
#
# ─────────────────────────────────────────────────────────────────────────────
# LES TROIS DIFFICULTES, ET CE QUI EST FAIT DE CHACUNE
#
# 1. L'HORLOGE. Une trame TDMA dure 4,615 ms et porte un numero (FN) sur 22
#    bits qui reboucle toutes les 3 h 28. Deux noeuds ont deux horloges sans
#    rapport : un burst etiquete fn=12345 chez l'un ne designe aucun instant
#    chez l'autre.
#    CE QUI EST FAIT : un suivi d'ECART. airmesh mesure en continu la difference
#    entre le FN local et le FN annonce par chaque pair, et REECRIT le FN a
#    l'injection. Les deux horloges avancent au meme rythme nominal (un timer
#    logiciel de 4,615 ms des deux cotes), l'ecart est donc quasi constant et
#    la derive se rattrape a chaque burst recu.
#    CE QUI SERAIT MIEUX : un noeud maitre qui DIFFUSE le FN, les autres
#    n'ayant plus d'horloge propre. C'est la bonne reponse, elle demande de
#    prendre la main sur clck_gen ; l'ecart suffit tant que les noeuds sont sur
#    le meme LAN. La fonction _fn_offset() est le seul endroit a remplacer.
#
# 2. LE DELAI. Un burst doit arriver AVANT que l'ordonnanceur local n'en ait
#    besoin. On l'injecte donc en avance de LOOKAHEAD trames (defaut 6, soit
#    ~28 ms) : un aller-retour LAN tient largement dedans, une liaison a 30 ms
#    de latence non. Les bursts arrives trop tard sont COMPTES, jamais jetes en
#    silence - un maillage radio qui perd 5 % de ses bursts se voit dans les
#    statistiques, pas dans les journaux du BSC.
#
# 3. QUI ENTEND QUI. Sans graphe, chaque mobile entendrait toutes les BTS du
#    banc a pleine puissance : plus de cellule, plus de reselection, plus rien
#    a demontrer. data/air-mesh.txt donne l'attenuation entre noeuds, en dB.
#    Au-dela d'un plancher, le burst n'est pas transmis - c'est ce qui fait un
#    MAILLAGE et non un bus.
#
# ─────────────────────────────────────────────────────────────────────────────
# LES DEUX MODES (AIRMESH_MODE)
#
#   fake  (defaut) - le burst traverse tel quel. C'est du commutation pure :
#                    aucune demodulation, aucun codage canal, le train de bits
#                    ressort identique. Exact et peu couteux.
#   pont           - le burst passe par la chaine du Calypso : demodulation en
#                    L2 (libosmocoding), remise a QEMU par les sidebands, et ce
#                    que l'ARM repond est re-module en bursts avant de repartir
#                    sur le maillage. C'est pont.py qui tient cette chaine ;
#                    airmesh lui passe la main par une FIFO et n'y touche pas.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUI N'EST PAS VALIDE
#
# Ce fichier est ecrit contre les formats et les conventions de port lus dans
# osmocom-bb (trx_toolkit : transceiver.py, data_msg.py, burst_fwd.py) et
# contre le TRXDv0 deja implemente des deux cotes par pont.py. Il n'a PAS
# encore tourne sur le banc : la partie a eprouver en premier est le suivi
# d'ecart d'horloge (point 1), qui est la seule qui repose sur une hypothese -
# que les deux clck_gen avancent au meme rythme. Les compteurs sont la pour
# ca : "hors fenetre" qui monte, c'est le point 1 ou le point 2 qui lache.

import argparse, os, socket, struct, sys, threading, time, collections

# ── TRXD v0, tel qu'osmocom-bb l'ecrit ───────────────────────────────────────
# En-tete commun : octet 0 = (version << 4) | numero de slot, puis FN sur 4
# octets gros-boutiste.  (data_msg.py, parse_hdr / append_hdr_to)
#   TxMsg (L1 -> transceiver) : en-tete commun + pwr(1)            = 6 octets
#   RxMsg (transceiver -> L1) : en-tete commun + rssi(1) + toa(2)  = 8 octets
# Puis 148 octets, un par bit (durs a l'emission, souples a la reception).
TRXD_VER      = 0
CHDR_LEN      = 5
TX_HDR_LEN    = CHDR_LEN + 1
RX_HDR_LEN    = CHDR_LEN + 3
BURST_LEN     = 148

# ── Notre protocole entre noeuds ─────────────────────────────────────────────
# Volontairement plat et lisible au tcpdump : on debogue un maillage radio en
# regardant passer les paquets, pas en relisant un schema de serialisation.
#   magie(4) ver(1) sens(1) noeud(2) arfcn(2) tn(1) reserve(1)
#   fn(4) pwr(1) rssi(1) toa(2 signe) nbits(2)   = 22 octets, puis nbits octets
AIRM_MAGIC    = b"AIRM"
AIRM_VER      = 1
AIRM_HDR      = ">4sBBHHBBIbbhH"
AIRM_HDR_LEN  = struct.calcsize(AIRM_HDR)
DIR_DL        = 0      # ce qu'une BTS emet
DIR_UL        = 1      # ce qu'un mobile emet

FN_MAX        = 2715648          # 26 * 51 * 2048, le rebouclage du FN GSM
FRAME_S       = 4.615e-3


def arfcn_to_khz(arfcn, uplink=False):
    """Frequence en kHz. GSM900 / DCS1800, les deux bandes du banc.

    fake_trx n'apparie pas sur l'ARFCN mais sur la FREQUENCE : se tromper de
    bande ne donne pas une erreur, cela donne un transceiver qui n'entend
    simplement jamais rien - la panne la plus longue a trouver.
    """
    if 512 <= arfcn <= 885:                      # DCS 1800
        dl = 1805200 + 200 * (arfcn - 512)
        return dl - 95000 if uplink else dl
    if 0 <= arfcn <= 124:                        # GSM 900
        dl = 935000 + 200 * arfcn
        return dl - 45000 if uplink else dl
    if 975 <= arfcn <= 1023:                     # E-GSM 900
        dl = 935000 + 200 * (arfcn - 1024)
        return dl - 45000 if uplink else dl
    raise ValueError("ARFCN hors des bandes connues : %d" % arfcn)


class Stats:
    """Ce qu'on regarde quand le maillage "marche a moitie"."""
    def __init__(self):
        self.lock = threading.Lock()
        self.c = collections.Counter()

    def bump(self, k, n=1):
        with self.lock:
            self.c[k] += n

    def render(self):
        with self.lock:
            return " ".join("%s=%d" % (k, v) for k, v in sorted(self.c.items()))


ST = Stats()


class Topologie:
    """Qui entend qui, et a quel prix.

    data/air-mesh.txt, une arete par ligne :
        <noeud a> <noeud b> <attenuation dB> [uni]
    Sans le mot "uni" l'arete vaut dans les deux sens. Une paire absente du
    fichier ne s'entend pas : c'est un maillage, pas un bus - deux noeuds ne se
    voient que si quelqu'un l'a ecrit.
    """

    def __init__(self, chemin, defaut_db):
        self.aretes = {}
        self.defaut = defaut_db
        self.ouvert = False
        if chemin and os.path.isfile(chemin):
            self._charger(chemin)
            self.ouvert = True

    def _charger(self, chemin):
        with open(chemin, "r", encoding="utf-8", errors="replace") as f:
            for ligne in f:
                ligne = ligne.split("#", 1)[0].strip()
                if not ligne:
                    continue
                ch = ligne.split()
                if len(ch) < 3:
                    continue
                try:
                    a, b, att = int(ch[0]), int(ch[1]), float(ch[2])
                except ValueError:
                    continue
                self.aretes[(a, b)] = att
                if len(ch) < 4 or ch[3] != "uni":
                    self.aretes[(b, a)] = att

    def attenuation(self, src, dst):
        """dB entre deux noeuds, ou None si l'un n'entend pas l'autre.

        Sans fichier, tout le monde s'entend a l'attenuation par defaut : c'est
        le comportement d'un bus, utile pour un premier essai a deux noeuds, et
        il est ANNONCE au demarrage pour qu'on ne le prenne pas pour une
        topologie.
        """
        if not self.ouvert:
            return self.defaut
        return self.aretes.get((src, dst))


class TrxLien:
    """Une L1 vue de fake_trx : CTRL et DATA, exactement comme trxcon.

    Conventions de port lues dans transceiver.py (Transceiver.__init__) :
    le transceiver BINDE base+1 (CTRL) et base+2 (DATA) ; la L1 binde base+101
    et base+102 et emet vers les premiers. On est du cote L1.
    """

    def __init__(self, nom, host, base, arfcn, rx_uplink):
        self.nom  = nom
        self.host = host
        self.base = base
        self.arfcn = arfcn
        self.rx_uplink = rx_uplink        # True : on ecoute le montant
        self.ctrl = self._sock(base + 101)
        self.data = self._sock(base + 102)
        self.ctrl_seq = 0
        self.slots = set()

    @staticmethod
    def _sock(port):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        return s

    # ── CTRL ────────────────────────────────────────────────────────────────
    def cmd(self, texte, attente=1.0):
        """Envoie une commande CTRL et attend sa reponse.

        On ATTEND la reponse plutot que de tirer les commandes a la suite :
        fake_trx repond RSP <cmd> <code>, et un code non nul (frequence hors
        bande, slot refuse) passait inapercu. Un transceiver mal accorde
        n'emet aucune erreur ensuite - il se tait, simplement.
        """
        self.ctrl.sendto(("CMD " + texte + "\0").encode(), (self.host, self.base + 1))
        self.ctrl.settimeout(attente)
        try:
            rep, _ = self.ctrl.recvfrom(512)
        except socket.timeout:
            return None
        finally:
            self.ctrl.settimeout(None)
        return rep.rstrip(b"\0").decode(errors="replace")

    def accorder(self, slots):
        """POWERON complet : accord des deux frequences puis ouverture des slots.

        L'ordre compte. fake_trx refuse SETSLOT sur un transceiver qui n'a pas
        de frequence, et POWERON sur un transceiver sans slot ne sert a rien :
        il tourne et n'entend rien.
        """
        rx = arfcn_to_khz(self.arfcn, uplink=self.rx_uplink)
        tx = arfcn_to_khz(self.arfcn, uplink=not self.rx_uplink)
        for cmd in ("RXTUNE %d" % rx, "TXTUNE %d" % tx):
            rep = self.cmd(cmd)
            if rep is None or " 0" not in rep:
                raise RuntimeError("%s : %s refuse (%s)" % (self.nom, cmd, rep))
        for tn in slots:
            # type 1 = TCH/F pour fake_trx ; ce qui compte ici est que le slot
            # soit ACTIF, le contenu reel est porte par les bursts eux-memes.
            self.cmd("SETSLOT %d 1" % tn)
            self.slots.add(tn)
        rep = self.cmd("POWERON")
        if rep is None or " 0" not in rep:
            raise RuntimeError("%s : POWERON refuse (%s)" % (self.nom, rep))

    def eteindre(self):
        try:
            self.cmd("POWEROFF", attente=0.3)
        except OSError:
            pass

    # ── DATA ────────────────────────────────────────────────────────────────
    def lire(self):
        """Un burst que fake_trx nous livre : ce que le voisin local a EMIS."""
        paquet, _ = self.data.recvfrom(1024)
        if len(paquet) < RX_HDR_LEN + BURST_LEN:
            ST.bump("rx_court")
            return None
        ver = paquet[0] >> 4
        if ver != TRXD_VER:
            ST.bump("rx_version_inattendue")
            return None
        tn   = paquet[0] & 0x0F
        fn   = struct.unpack(">L", paquet[1:5])[0]
        rssi = -paquet[5]
        toa  = struct.unpack(">h", paquet[6:8])[0]
        bits = paquet[RX_HDR_LEN:RX_HDR_LEN + BURST_LEN]
        return tn, fn, rssi, toa, bits

    def ecrire(self, tn, fn, pwr, bits):
        """Injecte un burst : fake_trx le distribuera a qui est accorde dessus."""
        hdr = bytearray(TX_HDR_LEN)
        hdr[0] = (TRXD_VER << 4) | (tn & 0x0F)
        hdr[1:5] = struct.pack(">L", fn % FN_MAX)
        hdr[5] = pwr & 0xFF
        self.data.sendto(bytes(hdr) + bytes(bits), (self.host, self.base + 2))


class Maillage:
    def __init__(self, cfg):
        self.cfg = cfg
        self.noeud = cfg.node
        self.topo = Topologie(cfg.topologie, cfg.attenuation_defaut)
        self.pairs = cfg.pairs                      # [(id, ip, port)]
        self.stop = threading.Event()

        # L'horloge : FN local vu en dernier, et ecart estime par pair.
        self._fn_local = 0
        self._fn_vu_a  = time.monotonic()
        self._ecart    = {}                         # id pair -> ecart en trames
        self._verrou   = threading.Lock()

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((cfg.bind, cfg.port))

        # Cote mobile : entend le descendant local, injecte le montant distant.
        self.ms  = TrxLien("airmesh-ms",  "127.0.0.1", cfg.trx_ms,
                           cfg.arfcn, rx_uplink=False)
        # Cote BTS : entend le montant local, injecte le descendant distant.
        self.bts = TrxLien("airmesh-bts", "127.0.0.1", cfg.trx_bts,
                           cfg.arfcn, rx_uplink=True)

    # ── Horloge ─────────────────────────────────────────────────────────────
    def _note_fn_local(self, fn):
        with self._verrou:
            self._fn_local = fn
            self._fn_vu_a  = time.monotonic()

    def _fn_maintenant(self):
        """Le FN local, extrapole depuis le dernier burst vu.

        On n'a pas d'horloge a nous : le seul FN de reference est celui que
        fake_trx nous livre avec chaque burst. Entre deux bursts on avance a la
        montre - 4,615 ms par trame. C'est suffisant pour une avance de six
        trames ; ce serait insuffisant pour dater quoi que ce soit.
        """
        with self._verrou:
            base, quand = self._fn_local, self._fn_vu_a
        return (base + int((time.monotonic() - quand) / FRAME_S)) % FN_MAX

    def _fn_offset(self, pair, fn_distant):
        """Ecart entre l'horloge d'un pair et la notre, lisse.

        C'est LE point fragile du maillage, et le seul endroit a remplacer le
        jour ou un noeud maitre diffusera le FN : ici, on suppose seulement que
        les deux horloges avancent au meme rythme.
        """
        vu = (self._fn_maintenant() - fn_distant) % FN_MAX
        with self._verrou:
            ancien = self._ecart.get(pair)
            if ancien is None:
                self._ecart[pair] = vu
                return vu
            # Moyenne glissante sur l'ecart circulaire : sans le repliement,
            # un rebouclage du FN ferait sauter l'ecart de deux millions de
            # trames et le maillage se tairait pendant trois heures.
            d = (vu - ancien + FN_MAX // 2) % FN_MAX - FN_MAX // 2
            neuf = (ancien + d // 8) % FN_MAX
            self._ecart[pair] = neuf
            return neuf

    # ── Emission vers les pairs ─────────────────────────────────────────────
    def _diffuser(self, sens, tn, fn, rssi, toa, bits):
        for (pid, ip, port) in self.pairs:
            att = self.topo.attenuation(self.noeud, pid)
            if att is None:
                ST.bump("hors_portee")
                continue
            r = max(-120, min(-1, int(rssi - att)))
            if r <= self.cfg.plancher:
                ST.bump("sous_plancher")
                continue
            paquet = struct.pack(AIRM_HDR, AIRM_MAGIC, AIRM_VER, sens,
                                 self.noeud, self.cfg.arfcn, tn, 0,
                                 fn % FN_MAX, 0, r, toa, len(bits)) + bytes(bits)
            try:
                self.sock.sendto(paquet, (ip, port))
                ST.bump("emis_dl" if sens == DIR_DL else "emis_ul")
            except OSError:
                ST.bump("emission_echec")

    def _boucle_locale(self, lien, sens):
        """Ce que le voisin LOCAL emet part vers les pairs."""
        while not self.stop.is_set():
            try:
                lu = lien.lire()
            except OSError:
                break
            if lu is None:
                continue
            tn, fn, rssi, toa, bits = lu
            self._note_fn_local(fn)
            self._diffuser(sens, tn, fn, rssi, toa, bits)

    # ── Reception depuis les pairs ──────────────────────────────────────────
    def _boucle_maillage(self):
        while not self.stop.is_set():
            try:
                paquet, _ = self.sock.recvfrom(2048)
            except OSError:
                break
            if len(paquet) < AIRM_HDR_LEN:
                ST.bump("mesh_court")
                continue
            (magie, ver, sens, src, arfcn, tn, _res,
             fn, _pwr, rssi, toa, nbits) = struct.unpack(AIRM_HDR, paquet[:AIRM_HDR_LEN])
            if magie != AIRM_MAGIC or ver != AIRM_VER:
                ST.bump("mesh_etranger")
                continue
            bits = paquet[AIRM_HDR_LEN:AIRM_HDR_LEN + nbits]
            if len(bits) != nbits or nbits != BURST_LEN:
                ST.bump("mesh_tronque")
                continue
            if arfcn != self.cfg.arfcn:
                # Un pair sur une autre porteuse : c'est normal et c'est meme
                # le but - deux operateurs voisins n'occupent pas le meme
                # canal. On ne le compte pas comme une erreur.
                ST.bump("autre_arfcn")
                continue

            # Ou ce burst tombe-t-il dans NOTRE temps.
            fn_local = (fn + self._fn_offset(src, fn)) % FN_MAX
            cible    = (self._fn_maintenant() + self.cfg.lookahead) % FN_MAX
            retard   = (cible - fn_local + FN_MAX // 2) % FN_MAX - FN_MAX // 2
            if retard > self.cfg.tolerance:
                ST.bump("hors_fenetre_tard")
                continue
            fn_inj = cible

            if sens == DIR_DL:
                # Un descendant distant : c'est une BTS d'ailleurs. On l'injecte
                # par le cote BTS, celui dont les mobiles locaux ecoutent le tx.
                self.bts.ecrire(tn, fn_inj, self._pwr(rssi), bits)
                ST.bump("injecte_dl")
            else:
                self.ms.ecrire(tn, fn_inj, self._pwr(rssi), bits)
                ST.bump("injecte_ul")

    @staticmethod
    def _pwr(rssi):
        """TxMsg porte une attenuation (0 = pleine puissance), pas un RSSI.

        On reporte donc l'attenuation deja appliquee par la topologie, bornee
        a l'octet : c'est ce qui donne au mobile une raison de preferer une
        cellule a une autre.
        """
        return max(0, min(255, -rssi - 40))

    # ── Vie du processus ────────────────────────────────────────────────────
    def _boucle_stats(self):
        while not self.stop.wait(self.cfg.stats_s):
            ecarts = " ".join("n%d:%+d" % (k, v if v < FN_MAX // 2 else v - FN_MAX)
                              for k, v in sorted(self._ecart.items()))
            print("[airmesh] fn=%d %s | ecarts %s" %
                  (self._fn_maintenant(), ST.render(), ecarts or "aucun"),
                  flush=True)

    def demarrer(self):
        print("[airmesh] noeud %d  arfcn %d  pairs %s" %
              (self.noeud, self.cfg.arfcn,
               ", ".join("%d@%s:%d" % p for p in self.pairs) or "aucun"), flush=True)
        if not self.topo.ouvert:
            print("[airmesh] AUCUNE topologie (%s) : tous les pairs s'entendent "
                  "a %.0f dB - c'est un bus, pas un maillage."
                  % (self.cfg.topologie, self.cfg.attenuation_defaut), flush=True)
        if self.cfg.mode != "fake":
            print("[airmesh] mode '%s' : les bursts passent par la chaine "
                  "Calypso de pont.py (FIFO %s)" % (self.cfg.mode, self.cfg.fifo),
                  flush=True)

        slots = [int(x) for x in self.cfg.slots.split(",") if x != ""]
        self.ms.accorder(slots)
        self.bts.accorder(slots)

        fils = [
            threading.Thread(target=self._boucle_locale, args=(self.ms, DIR_DL),
                             name="local-dl", daemon=True),
            threading.Thread(target=self._boucle_locale, args=(self.bts, DIR_UL),
                             name="local-ul", daemon=True),
            threading.Thread(target=self._boucle_maillage, name="maillage", daemon=True),
            threading.Thread(target=self._boucle_stats, name="stats", daemon=True),
        ]
        for f in fils:
            f.start()
        try:
            while not self.stop.is_set():
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            self.ms.eteindre()
            self.bts.eteindre()
            print("[airmesh] arret. %s" % ST.render(), flush=True)


def paire(txt):
    """--pair 2:192.168.1.12:4739"""
    ch = txt.split(":")
    if len(ch) != 3:
        raise argparse.ArgumentTypeError("attendu <noeud>:<ip>:<port>, recu %r" % txt)
    return (int(ch[0]), ch[1], int(ch[2]))


def main():
    p = argparse.ArgumentParser(
        prog="airmesh",
        description="Maillage de bursts GSM entre noeuds : le milieu radio devient commun.")
    p.add_argument("--node", type=int, required=True, help="numero de CE noeud")
    p.add_argument("--arfcn", type=int, default=int(os.environ.get("AIRMESH_ARFCN", "514")))
    p.add_argument("--pair", dest="pairs", action="append", type=paire, default=[],
                   metavar="NOEUD:IP:PORT", help="un pair du maillage (repetable)")
    p.add_argument("--bind", default=os.environ.get("AIRMESH_BIND", "0.0.0.0"))
    p.add_argument("--port", type=int, default=int(os.environ.get("AIRMESH_PORT", "4739")))
    # 6700 + (n-1)*3 : les deux emplacements de mobile qui suivent les vrais.
    # Avec deux MS reels, le banc doit tourner en N_MS=4 et airmesh prend 3 et 4.
    p.add_argument("--trx-ms", type=int, default=int(os.environ.get("AIRMESH_TRX_MS", "6706")),
                   help="base TRXD de l'emplacement pris cote mobile (defaut : MS 3)")
    p.add_argument("--trx-bts", type=int, default=int(os.environ.get("AIRMESH_TRX_BTS", "6709")),
                   help="base TRXD de l'emplacement pris cote BTS (defaut : MS 4)")
    p.add_argument("--slots", default=os.environ.get("AIRMESH_SLOTS", "0,1,2,3,4,5,6,7"))
    p.add_argument("--lookahead", type=int, default=int(os.environ.get("AIRMESH_LOOKAHEAD", "6")),
                   help="trames d'avance a l'injection (6 = ~28 ms)")
    p.add_argument("--tolerance", type=int, default=int(os.environ.get("AIRMESH_TOL", "2")),
                   help="trames de retard tolerees avant de compter le burst perdu")
    p.add_argument("--topologie", default=os.environ.get("AIRMESH_TOPO", "data/air-mesh.txt"))
    p.add_argument("--attenuation-defaut", type=float,
                   default=float(os.environ.get("AIRMESH_ATT", "20")))
    p.add_argument("--plancher", type=int, default=int(os.environ.get("AIRMESH_PLANCHER", "-110")),
                   help="dBm sous lesquels le burst n'est pas transmis")
    # fake : le burst traverse tel quel, airmesh n'est qu'un transport.
    # pont : il passe par la chaine Calypso de pont.py - demodulation, remise a
    # QEMU, remodulation - avant de repartir. C'est le mode qui fait vraiment
    # emettre le firmware pour le compte du maillage.
    p.add_argument("--mode", choices=("fake", "pont"),
                   default=os.environ.get("AIRMESH_MODE", "fake"))
    p.add_argument("--fifo", default=os.environ.get("AIRMESH_FIFO", "/dev/shm/airmesh_pont"))
    p.add_argument("--stats-s", type=float, default=float(os.environ.get("AIRMESH_STATS", "10")))
    cfg = p.parse_args()

    try:
        Maillage(cfg).demarrer()
    except RuntimeError as e:
        print("[airmesh] %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
