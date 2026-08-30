#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# pont.py — Pont TRX burst-level entre osmo-bts-trx et l'API RAM du Calypso.
#
# Voie A (validée) : L2 DE BOUT EN BOUT. Le pont ne transporte JAMAIS d'IQ ni de
# burst brut dans d_burst_d ; il code/décode le CANAL via libosmocoding (ctypes),
# puis réutilise le chemin SHUNT_LEGIT déjà en place :
#   - DL (BTS->UE) : burst TRXD -> libosmocoding decode -> L2 -> GSMTAP 4730/4731
#                    (le shunt in-QEMU écrit a_cd / feed_sb ; on ne touche pas QEMU).
#   - UL (UE->BTS) : L2 déposée par l'ARM dans /dev/shm/calypso_* -> libosmocoding
#                    encode -> bursts -> TRXD -> BTS.
#
# Process SÉPARÉ : ne patche NI QEMU NI osmocom-bb NI gapk.
#
# RÈGLE DE SENS (en rôle, pas "DL/UL" absolu) :
#   ce que la BTS ÉMET sur DATA (son TX)  -> reçu par le Calypso (on décode->GSMTAP).
#   ce que le Calypso ÉMET (sidebands)    -> renvoyé à la BTS comme son RX (on encode->TRXD).

import socket, struct, threading, time, os, ctypes, sys, collections, signal
import gc

# ── LE RAMASSE-MIETTES CYCLIQUE EST COUPE ────────────────────────────────────
# Ce pont fait du temps reel : un burst dure 4,615 ms et arrive ~1700 fois par
# seconde. Le gc generationnel de CPython s'declenche sur un COMPTEUR
# d'allocations, donc au milieu du traitement d'un burst, et sa pause n'est pas
# bornee. Or tout ce que ce programme alloue en boucle est acyclique (bytes,
# tuples, tableaux ctypes) : le comptage de references seul suffit a le liberer.
# Le gc cyclique ne ramasse donc RIEN ici -- il ne fait que payer le parcours.
# gc.freeze() met en prime les objets du demarrage hors des generations, pour
# que le collecteur manuel (si on le rallume) n'ait pas a les revisiter.
# PONT_GC=1 le rallume.
if os.environ.get("PONT_GC", "0") != "1":
    gc.disable()
    try:
        gc.freeze()          # Python 3.7+
    except AttributeError:
        pass

# =========================== CONFIG (tête de fichier) ===========================
TRX_BIND      = os.environ.get("PONT_TRX_BIND",   "127.0.0.1")
TRX_REMOTE    = os.environ.get("PONT_TRX_REMOTE", "127.0.0.1")
TRX_BASE      = int(os.environ.get("PONT_TRX_BASE", "5700"))   # CLCK+0 CTRL+1 DATA+2
BSIC          = int(os.environ.get("PONT_BSIC", "7"))
ARFCN         = int(os.environ.get("PONT_ARFCN", "514"))

# POINT 3 — TIMING UL. Un burst UL hors fenêtre est JETÉ EN SILENCE par la BTS.
# Décalage d'avance UL en frames TDMA : on poste le burst quand l'horloge atteint
# (l1s_fn - UL_FN_ADVANCE). À AJUSTER empiriquement via le compteur hors-fenêtre.
UL_FN_ADVANCE = int(os.environ.get("PONT_UL_FN_ADVANCE", "3"))
WINDOW_TOL    = int(os.environ.get("PONT_WINDOW_TOL", "1"))
# RSSI annonce a la BTS pour nos bursts montants (uint8 = -dBm).
PONT_RSSI     = int(os.environ.get("PONT_RSSI", "60"))

GSMTAP_HOST   = "127.0.0.1"
PORT_GSMTAP   = int(os.environ.get("CALYPSO_SHUNT_GSMTAP_PORT", "4730") or "4730")  # SI/CCCH/SDCCH/SACCH
PORT_SCH      = int(os.environ.get("CALYPSO_SHUNT_SCH_PORT",    "4731") or "4731")  # SCH/BSIC
# ------------------------------- TAP D'OBSERVATION --------------------------
# Le pont decode DEJA tout le descendant en L2 (SI, CCCH, SDCCH, SACCH, FACCH)
# et le pousse en GSMTAP vers le shunt sur PORT_GSMTAP. Cette L2 n'allait donc
# nulle part ou un analyseur puisse la lire. On en fait un MIROIR vers un port
# d'observation, et on tape aussi le MONTANT, que le pont a en main avant de
# l'encoder en bursts.
# POURQUOI CE CHEMIN PLUTOT QUE LE CFILE. L'I/Q d'AIRREC est reconstruite a
# partir des bits ; je n'ai pas su la rendre decodable par gr-gsm (4 variantes
# de modulation testees, 0 ligne decodee), et de toute facon grgsm_decode ne
# decode PAS le montant : il se cale sur FCCH/SCH, qui n'existent qu'en
# descendant. Le tap donne le meme resultat sans demodulation du tout.
# ⚠️ 4729 est aussi le port ou le firmware du mobile tape SA propre L2 : les
# deux sources coexistent dans la meme capture. Celle du pont porte le point
# de vue RESEAU (ce qui est passe sur le lien), celle du mobile son point de
# vue local. Elles peuvent diverger — et c'est justement l'ecart interessant.
# PONT_TAP_PORT=4727 (p.ex.) pour les separer.
TAP           = os.environ.get("PONT_TAP", "1") not in ("0", "", "no")
TAP_PORT      = int(os.environ.get("PONT_TAP_PORT", "4729"))
SB_SDCCH_UL   = "/dev/shm/calypso_sdcch_ul"     # 48o: seq u32 | l1s%51 u8 | l1s_fn u32 | l2[23]
SB_RACH       = "/dev/shm/calypso_rach"
DCCH_CFG      = "/dev/shm/calypso_dcch_cfg"
BSC_CFG       = os.environ.get("PONT_BSC_CFG", "/etc/osmocom/osmo-bsc.cfg")

GSM_HYPERFRAME = 26 * 51 * 2048         # 2 715 648
FRAME_DUR      = 60.0 / 13000.0         # 4.615 ms (POINT 4 : durée d'une trame TDMA)

# =========================== libosmocoding (ctypes) ============================
# Réutilise l'encodeur/décodeur de RÉFÉRENCE (GSM 05.03), le MÊME que qemu_wrap.c.
_cod = ctypes.CDLL("libosmocoding.so", use_errno=True)
ubit = ctypes.c_int8       # ubit_t : 0/1
sbit = ctypes.c_int8       # sbit_t : soft-bit signé (+/-127)

# ── ubit -> sbit EN UNE PASSE C, PLUS EN PYTHON ──────────────────────────────
# La conversion « 0 -> +127, tout le reste -> -127 » (convention osmo_ubit2sbit)
# se faisait par une boucle Python bit a bit, a deux endroits du chemin chaud :
#   xcch_decode_4   : 4 x 116 = 464 iterations par bloc descendant
#   tch_dl_burst    : 8 x 116 = 928 iterations par bloc de parole
# Sur un run mesure (dl_dec=2479 + crc_fail=4319 = ~6800 blocs xcch), cela fait
# ~3,2 millions d'iterations Python pour le seul xcch -- dans un pont deja a
# 83 % d'un coeur, mono-thread sous le GIL. bytes.translate fait la meme chose
# en une passe C, et from_buffer_copy remplit le tableau ctypes d'un seul memcpy.
# 129 = 0x81, soit -127 lu comme int8.
_TBL_SOFT = bytes([127] + [129] * 255)
_cod.gsm0503_xcch_encode.argtypes      = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8)]
_cod.gsm0503_xcch_decode.argtypes      = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit),
                                          ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_cod.gsm0503_rach_ext_encode.argtypes  = [ctypes.POINTER(ubit), ctypes.c_uint16, ctypes.c_uint8, ctypes.c_bool]
_cod.gsm0503_rach_ext_decode_ber.argtypes = [ctypes.POINTER(ctypes.c_uint16), ctypes.POINTER(sbit),
                                          ctypes.c_uint8, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_cod.gsm0503_sch_encode.argtypes       = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8)]
# TCH/F plein debit : 8 bursts x 114 bits, entrelacement DIAGONAL (bloc tous les 4 bursts).
_cod.gsm0503_tch_fr_encode.argtypes    = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8),
                                          ctypes.c_int, ctypes.c_int]
_cod.gsm0503_tch_fr_decode.argtypes    = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit),
                                          ctypes.c_int, ctypes.c_int,
                                          ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_cod.gsm0503_sch_decode.argtypes       = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit)]

# ============================ CHIFFREMENT A5 (host-side) ======================
# On court-circuite la crypto du DSP comme on court-circuite deja la demodulation.
# Le Kc est celui capte par osmocon (L1CTL_CRYPTO_REQ) dans /dev/shm/calypso_kc :
#   [0..3]seq u32 | [4]algo | [5]key_len=8 | [6..13]Kc | [14]cksn
# On applique le keystream osmo_a5() sur les 2x57 bits UTILES du burst normal
# (positions 3..59 et 88..144 — les 2 bits de vol, 60 et 87, ne sont PAS chiffres).
#   DL (recu de la BTS) : dechiffrer AVANT le decodage canal.
#   UL (emis vers la BTS) : chiffrer APRES l'encodage canal.
# C'est exactement ce que faisait ul_cipher_burst (qemu_wrap.c:1902), au meme
# etage logique — mais cote pont, puisque l'ipc-device est eteint en mode pont.
_gsm = ctypes.CDLL("libosmogsm.so", use_errno=True)
_gsm.osmo_a5.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32,
                         ctypes.POINTER(ubit), ctypes.POINTER(ubit)]
KC_PATH   = "/dev/shm/calypso_kc"
A5_FORCE  = int(os.environ.get("PONT_A5", "0"))      # 0 = suit l'algo du Kc ; 1..3 = force
A5_FN_ADJ = int(os.environ.get("PONT_A5_FN_ADJ", "0"))

_kc_fd = None
_kc_cache = (0, None)
_kc_next = 0.0
KC_TTL = 0.1        # 100 ms : bien plus court qu'une transaction, 0 syscall par burst

def kc_read():
    """(algo, Kc[8]) si un Kc valide est publie, sinon (0, None).

    ⚠️ COUT : appele a CHAQUE burst (DL et UL). L'ancienne version faisait
    open+pread+close par appel, soit ~4800 syscalls/s — assez pour voler du temps
    d'ordonnancement a trxcon/fake_trx (MS#2), qui sont temps-reel : leurs bursts
    montants partaient une trame en retard et fake_trx les jetait ("Stale TRXD").
    On garde donc UN fd et on ne relit qu'au plus toutes les KC_TTL secondes.
    pread reste obligatoire (un lecteur bufferise figerait la valeur, regle projet)."""
    global _kc_fd, _kc_cache, _kc_next
    now = time.monotonic()
    if now < _kc_next:
        return _kc_cache
    _kc_next = now + KC_TTL
    try:
        if _kc_fd is None:
            _kc_fd = os.open(KC_PATH, os.O_RDONLY)
        b = os.pread(_kc_fd, 32, 0)
    except OSError:
        try:
            if _kc_fd is not None:
                os.close(_kc_fd)
        except OSError:
            pass
        _kc_fd = None
        _kc_cache = (0, None)
        return _kc_cache
    if len(b) < 14:
        _kc_cache = (0, None); return _kc_cache
    algo = b[4]
    kc = b[6:14]
    if algo < 1 or algo > 3 or not any(kc):
        _kc_cache = (0, None); return _kc_cache
    _kc_cache = ((A5_FORCE if A5_FORCE else algo), kc)
    return _kc_cache

# ── LE Kc SURVIT A UN EFFACEMENT PARASITE ─────────────────────────────────────
# osmocon (osmocom-bb, hors de ce depot) remet /dev/shm/calypso_kc a zero sur
# DM_EST_REQ **et** DM_REL_REQ :
#     } else if (buf[0] == 0x05 /* DM_EST_REQ */ || buf[0] == 0x12 /* DM_REL_REQ */)
# L'intention -- « nouveau canal dedie ou release -> repart en clair » -- est
# juste pour le RELEASE. Elle est fausse pour l'ESTABLISH : le mobile emet aussi
# un DM_EST_REQ pour ouvrir un lien SUPPLEMENTAIRE sur un canal DEJA chiffre
# (le SAPI 3 du SMS, une re-etablissement LAPDm). La cle disparait alors que le
# reseau, lui, continue de chiffrer.
#
# MESURE DU 2026-08-27 : une seule CRYPTO_REQ sur tout le run
#     [osmocon] CRYPTO_REQ FILTRE: algo=1 key_len=8 key=86b592477f041c00
#     [osmocon] Kc ecrit (seq=1 algo=1 cksn=0xff)
# et pourtant /dev/shm/calypso_kc a zero, avec
#     SOUS-VOIE ACTIVE : clair 50/277   chiffre 0/96
# Zero bloc chiffre decode sur 96. Le LU mourait pile apres l'AUTHENTICATION
# RESPONSE, a l'instant ou le reseau bascule en chiffre, puis T3210.
#
# On ne peut pas corriger osmocon d'ici. On rend donc le pont robuste : la cle
# reste valable tant que le CANAL DEDIE n'a pas change. Le discriminant est le
# `seq` de calypso_dcch_cfg, incremente a chaque nouveau canal par le firmware --
# la meme source que _dcch_cfg(). Un vrai changement de canal libere la cle ; un
# effacement parasite en cours de canal ne la perd plus.
# ── LE Kc SURVIT A UN EFFACEMENT PARASITE, ET SE LACHE SUR LA SABM ───────────
#
# LE PROBLEME. osmocon (osmocom-bb, hors de ce depot) remet /dev/shm/calypso_kc a
# zero sur DM_EST_REQ **et** DM_REL_REQ. L'intention -- « nouveau canal dedie ou
# release -> repart en clair » -- est juste pour le RELEASE, fausse pour
# l'ESTABLISH : le mobile emet aussi un DM_EST_REQ pour ouvrir un lien
# SUPPLEMENTAIRE sur un canal DEJA chiffre (SAPI 3 du SMS, re-etablissement
# LAPDm). La cle disparait alors que le reseau continue de chiffrer. Mesure du
# 27/08 : une seule CRYPTO_REQ de tout le run, et pourtant le fichier a zero,
# avec « SOUS-VOIE ACTIVE : clair 50/277  chiffre 0/96 » -- zero bloc chiffre
# decode sur 96, et le LU qui mourait pile apres l'AUTHENTICATION RESPONSE.
#
# LA PREMIERE TENTATIVE ETAIT FAUSSE, et il faut le dire : elle retenait la cle
# tant que le `seq` de calypso_dcch_cfg ne bougeait pas. Or l1ctl_sock.c ne
# l'incremente que `if (kind >= 0 && chan_nr != last_chan_nr)`, et chan_nr reste
# 0x41 du LU jusqu'a l'appel. La cle etait donc retenue INDEFINIMENT (13500
# retenues mesurees), le canal de l'appel -- qui demarre EN CLAIR -- se voyait
# appliquer l'A5, l'UA revenait brouillee : T200 x6, MDL-ERROR cause 1, appel
# mort avant le CM SERVICE. Exactement ce que le reset d'osmocon evitait.
#
# LE BON MARQUEUR EST LA SABM. Un lien LAPDm qui (re)demarre le fait TOUJOURS par
# une SABM, et TOUJOURS en clair -- c'est la definition de l'etablissement. Le
# pont voit cette trame en clair, avant encodage et avant chiffrement, dans
# ul_sdcch_from_sideband (l2 = b[16:39], la L2 telle que le mobile l'a posee).
# On lache donc la cle la, et on la reprend au CRYPTO_REQ suivant. Un effacement
# parasite en cours de session ne la perd plus ; un vrai (re)demarrage la libere.
#
# PONT_KC_RETENTION=0 revient au comportement d'avant (aucune retenue).
# [2026-08-27] DEFAUT REMIS A 0. Deux discriminants essayes, deux faux :
#   - le `seq` de calypso_dcch_cfg : il ne bouge pas (chan_nr identique du LU a
#     l'appel), la cle etait retenue indefiniment -> l'A5 s'appliquait au canal
#     de l'appel qui demarre en clair -> appel mort.
#   - la SABM montante : une SABM ne signifie PAS toujours « on repart en
#     clair ». Un re-etablissement LAPDm sur un canal deja chiffre (SAPI 3 du
#     SMS) est lui-meme chiffre. On lachait donc la cle en pleine session.
# Le defaut d'origine (osmocon efface le Kc sur DM_EST_REQ) est reel et
# mesurable, mais il faut un marqueur qui distingue « nouveau canal » de
# « nouveau lien sur le meme canal ». Piste non essayee : l'IMMEDIATE
# ASSIGNMENT descendant, qui est le seul octroi d'un canal NEUF. Tant que ce
# n'est pas verifie, on n'ajoute pas de variable mobile de plus.
# PONT_KC_RETENTION=1 reactive la retenue pour experimenter.
# [2026-08-27, soir] LE MARQUEUR MANQUANT ETAIT L'IMMEDIATE ASSIGNMENT.
# La note ci-dessus le disait deja : « Piste non essayee : l'IMMEDIATE
# ASSIGNMENT descendant, qui est le seul octroi d'un canal NEUF. » Elle est
# essayee maintenant, parce que la mesure ne laisse plus le choix.
#
# MESURE, run de 19:3x, SMS qui ne passent pas :
#   446 DEDIE-TRACE, dont 338 « A5=non decode=NON » et 12 « A5=non decode=OUI »
#   -> A5=non sur la TOTALITE des blocs du canal dedie, et 97 % d'echecs
# et pourtant, cote osmocon, la cle etait bien captee NEUF fois :
#   [osmocon] CRYPTO_REQ FILTRE: algo=1 key_len=8 key=6c39560b5bd77000
#   [osmocon] Kc ecrit (seq=6..9 algo=1 cksn=0xff)
# Entre les deux, l'effaceur de osmocon (DM_EST_REQ **et** DM_REL_REQ) remettait
# le fichier a zero, et sans retenue le pont lisait algo=0 : il laissait en clair
# un canal que le reseau chiffrait. Tout ce qui vit sur le dedie meurt la --
# le SMS (SAPI 3) en premier, puisqu'il ouvre justement un lien SUPPLEMENTAIRE
# sur un canal DEJA chiffre, donc un DM_EST_REQ de plus, donc un effacement de
# plus, en plein milieu de la session.
#
# LES DEUX MARQUEURS ESSAYES AVANT, ET POURQUOI CELUI-CI EST DIFFERENT :
#   - le `seq` de calypso_dcch_cfg : ne bouge pas du LU a l'appel -> cle retenue
#     indefiniment, A5 applique a un canal qui demarre en clair.
#   - la SABM montante : une SABM ne veut PAS dire « on repart en clair ». Un
#     re-etablissement LAPDm sur canal chiffre en est une, et le SAPI 3 du SMS
#     aussi. Mesure du meme run : 11 « Kc LACHE (SABM montante) » -- onze
#     lachers en pleine session.
#   - l'IMMEDIATE ASSIGNMENT descendant, lui, est le SEUL message par lequel le
#     reseau octroie un canal dedie NEUF, et un canal neuf demarre TOUJOURS en
#     clair (le chiffrement n'arrive qu'au CIPHERING MODE COMMAND suivant). Il
#     ne se confond ni avec un lien de plus sur le canal courant (SAPI 3), ni
#     avec l'ASSIGNMENT COMMAND vers le TCH -- lequel CONSERVE le chiffrement,
#     et c'est precisement ce qu'il fallait cesser de casser.
# On y ajoute le CHANNEL RELEASE : le canal est rendu, la cle avec.
#
# PONT_KC_RETENTION=0 revient au comportement d'avant (aucune retenue).
# [2026-08-27, soir, 2e passe] LA RETENUE N EST PLUS LE BON OUTIL : LA SOURCE
# A CHANGE. Tout ce qui precede raisonne sur un fichier alimente par un TIERS
# qui espionne le L1CTL au passage (osmocon) et qui l EFFACE sur DM_EST_REQ.
# Retenir la cle etait un pansement sur cet effaceur, et il fallait deviner
# quand la lacher -- trois marqueurs essayes, trois faux departs.
#
# Desormais QEMU publie /dev/shm/calypso_kc depuis le NDB du DSP
# (calypso_dsp_shunt.c, shunt_publish_kc) : d_a5mode et a_kc[4], que le
# firmware charge lui-meme par dsp_load_ciph_param(). C est l etat de
# chiffrement REEL de la couche 1, reaffirme toutes les ~100 ms, et remis a
# zero par le firmware lui-meme quand il repart en clair.
#
# Un zero venu de LA veut donc dire << la L1 est en clair >>, et le retenir
# serait chiffrer un canal qui ne l est pas. Retenue OFF, et c est le bon
# reglage pour la premiere fois : il n y a plus d effacement parasite a
# compenser. PONT_KC_RETENTION=1 la reactive pour comparer.
KC_RETENTION = os.environ.get("PONT_KC_RETENTION", "0") == "1"
_kc_tenu = None          # (algo, kc) retenu, ou None
_kc_retenues = 0
_kc_laches = 0

def _est_sabm(l2):
    """Vrai si cette L2 LAPDm est une SABM (etablissement).
    Trame U : bits 0-1 du controle a 11. SABM = 0x2F, avec ou sans le bit P
    (0x10) -- d'ou le masque 0xEF. GSM 04.06 3.4/3.6."""
    if not l2 or len(l2) < 2:
        return False
    ctrl = l2[1]
    return (ctrl & 0x03) == 0x03 and (ctrl & 0xEF) == 0x2F

def kc_lacher(motif):
    """Un lien redemarre en clair : la cle retenue cesse d'etre valable."""
    global _kc_tenu, _kc_laches
    if _kc_tenu is not None:
        _kc_tenu = None
        _kc_laches += 1
        ST.log("Kc LACHE (%s) -- le lien repart en clair (#%d)" % (motif, _kc_laches))
_kc_seq_fd = None

def _dcch_seq():
    """seq de calypso_dcch_cfg : incremente a CHAQUE nouveau canal dedie.
    UN fd persistant + pread, comme _dcch_cfg (cf. l'audit des descripteurs)."""
    global _kc_seq_fd
    try:
        if _kc_seq_fd is None:
            _kc_seq_fd = os.open(DCCH_CFG, os.O_RDONLY)
        b = os.pread(_kc_seq_fd, 4, 0)
        return struct.unpack_from("<I", b, 0)[0] if len(b) >= 4 else 0
    except OSError:
        try:
            if _kc_seq_fd is not None:
                os.close(_kc_seq_fd)
        except OSError:
            pass
        _kc_seq_fd = None
        return 0

_a5_last = {"applied": False, "algo": 0, "kc4": ""}

def a5_apply(burst148, fn, uplink):
    """XOR du keystream A5 sur les 114 bits utiles. Renvoie le burst modifie."""
    algo, kc = kc_read()
    global _kc_tenu, _kc_retenues, _a5_last
    if algo:
        _kc_tenu = (algo, kc)                 # cle fraiche : on la retient
    elif KC_RETENTION and _kc_tenu is not None:
        algo, kc = _kc_tenu                   # effacement parasite : on tient
        _kc_retenues += 1
        if _kc_retenues == 1 or (_kc_retenues % 2000) == 0:
            ST.log("Kc EFFACE EN COURS DE SESSION -- on garde la cle (#%d) ; "
                   "elle sera lachee a la prochaine SABM. Cf. osmocon DM_EST_REQ."
                   % _kc_retenues)
    if not algo:
        # [audit A2] _a5_last = etat de SESSION DL (badge/DEDIE-TRACE) : SEUL le
        # thread DL l'ecrit (rebind atomique), le montant n'y touche plus -> plus
        # de lecture dechiree du badge par une passe UL concurrente.
        if not uplink:
            _a5_last = {"applied": False, "algo": 0, "kc4": ""}
        return burst148                       # pas de Kc -> on ne touche a rien
    if not uplink:
        _a5_last = {"applied": True, "algo": algo, "kc4": kc[:4].hex()}
    key = (ctypes.c_uint8 * 8)(*kc)
    dl = (ubit * 114)(); ul = (ubit * 114)()
    _gsm.osmo_a5(algo, key, ctypes.c_uint32((fn + A5_FN_ADJ) & 0xffffffff), dl, ul)
    ks = ul if uplink else dl
    # ⚠️ DEUX DOMAINES D'OCTETS DIFFERENTS — c'etait LE bug :
    #   UL (interne)  : 0x01 = bit 1, 0xFF = bit 0  (ce que construit normal_from_burst116)
    #   DL (TRXD brut): 0x01 = bit 1, 0x00 = bit 0  (octets recus tels quels de la BTS)
    # Inverser 0x01 -> 0xFF cote DL laissait le bit A 1 (plus loin, `-127 if v else 127`
    # traite 0xFF comme vrai) : la moitie du XOR etait un NO-OP.
    b = bytearray(burst148)
    if uplink:
        def _flip(x): return 0xFF if x == 0x01 else 0x01
    else:
        def _flip(x): return 0x00 if x else 0x01
    for i in range(57):                       # bloc 1 : positions 3..59
        if ks[i]:
            b[3 + i] = _flip(b[3 + i])
    for i in range(57):                       # bloc 2 : positions 88..144
        if ks[57 + i]:
            b[88 + i] = _flip(b[88 + i])
    if uplink: ST.n_a5_ul += 1
    else:      ST.n_a5_dl += 1
    return bytes(b)

# ---- Mapping burst normal <-> 116 bits codés (identique à qemu_wrap.c:856-868) ----
TSC7 = bytes([1,1,1,0,1,1,1,1,0,0,0,1,0,0,1,0,1,1,1,0,1,1,1,1,0,0])
# Un burst normal (148 bits actifs) : [3 tail][58 e][26 TSC][58 e][3 tail].
# Les 2x58 = 116 bits codés ; xcch travaille sur 4 bursts = 4x116.

def burst116_from_normal(b148):
    """DL : extrait les 116 bits codés (soft) d'un burst normal TRXD de 148 bits."""
    return b148[3:61] + b148[87:145]         # 58 + 58

def normal_from_burst116(cB):
    """UL : place 116 bits codés (ubit) dans un burst normal de 148 bits (+/-1 soft)."""
    ab = bytearray(148)
    p = 0
    for _ in range(3):          ab[p]=0xFF; p+=1                 # tail (-1)
    for i in range(58):         ab[p]=1 if cB[i] else 0xFF; p+=1 # data 1
    for i in range(26):         ab[p]=1 if TSC7[i] else 0xFF; p+=1
    for i in range(58):         ab[p]=1 if cB[58+i] else 0xFF; p+=1
    for _ in range(3):          ab[p]=0xFF; p+=1                 # tail
    return ab                    # 0x01 = +1, 0xFF = -1 (soft-bit signé)

def xcch_decode_4(bursts4_116):
    """DL : 4x116 soft-bits -> L2[23]. bursts4_116 = liste de 4 séquences de 116."""
    # Convention osmocom (osmo_ubit2sbit) : ubit 1 -> sbit -127, ubit 0 -> +127.
    # L'inverse fait echouer TOUS les CRC. Cf. _TBL_SOFT.
    buf = (sbit * (4*116)).from_buffer_copy(
            b"".join(bytes(b).translate(_TBL_SOFT) for b in bursts4_116))
    l2 = (ctypes.c_uint8 * 23)()
    ne = ctypes.c_int(); nb = ctypes.c_int()
    rc = _cod.gsm0503_xcch_decode(l2, buf, ctypes.byref(ne), ctypes.byref(nb))
    return (bytes(l2), rc, ne.value) if rc == 0 else (None, rc, ne.value)

def xcch_encode_4(l2_23):
    """UL : L2[23] -> 4 bursts normaux (148 bits) prêts pour TRXD."""
    l2 = (ctypes.c_uint8 * 23)(*l2_23[:23])
    e  = (ubit * (4*116))()
    _cod.gsm0503_xcch_encode(e, l2)
    return [normal_from_burst116([e[k*116+i] for i in range(116)]) for k in range(4)]

# =========================== POINT 2 — slot mapping ============================
# NE PAS coder en dur : on LIT le channel-description depuis osmo-bsc.cfg.
# Fallback = table normative GSM 05.02 (TS0 = CCCH+SDCCH/4).
def load_ts_config(path):
    """Retourne {tn: phys_chan_config} lu du PREMIER trx de la PREMIERE bts.

    C'est osmo-bsc.cfg qui fait autorite sur le plan des slots : y ecrire
    « phys_chan_config SDCCH8 » sur le timeslot 1, ou « TCH/F », doit suffire a
    ce que le pont suive. Rien n'est code en dur ici, le repli ne sert qu'a un
    fichier absent.

    ⚠️ ON S'ARRETE A LA PREMIERE BTS. La version precedente annoncait « 1er trx »
    dans sa docstring mais parcourait le fichier ENTIER : la seconde BTS (le
    side-car, qui declare ses propres timeslot 0 et 1) ecrasait la premiere.
    Tant que les deux portaient le meme plan, rien ne se voyait ; le jour ou on
    change le TS1 de la BTS principale, le pont prend celui du side-car et le
    dedie tombe a cote - sans qu'une ligne ne le signale."""
    ts = {}
    try:
        cur = None
        n_bts = 0
        for line in open(path, encoding="utf-8", errors="ignore"):
            s = line.strip()
            if s.startswith("bts "):
                n_bts += 1
                if n_bts > 1:
                    break                     # la suite appartient a une autre BTS
                cur = None
            elif s.startswith("timeslot "):
                cur = int(s.split()[1])
            elif s.startswith("phys_chan_config") and cur is not None:
                ts[cur] = s.split(None, 1)[1].strip(); cur = None
    except OSError:
        pass
    if not ts:
        ts = {0: "CCCH+SDCCH4", 1: "SDCCH8", 2: "TCH/F", 3: "TCH/F"}
    return ts

TS_CONFIG = load_ts_config(BSC_CFG)

# Sous-voies SDCCH/4 combiné (TS0) : positions DL fn%51 et SACCH fn%102 (GSM 05.02).
SD4_DL_BASE   = [22, 26, 32, 36]        # 4 bursts consécutifs à base..base+3
SD4_SACCH_102 = [42, 46, 93, 97]        # SACCH fn%102 (POINT 1 : période 102, pas 51)
BCCH_FN51     = [2, 6, 12, 16]          # BCCH bloc (info système) fn%51

# =========================== compteurs / instrumentation ======================
class Stats:
    def __init__(s):
        s.n_dl_bursts=0; s.n_dl_decoded=0; s.n_dl_crc_fail=0
        # Blocs dedies ecartes parce que le dedie est sur un AUTRE slot. A
        # comparer a n_dl_crc_fail : c'est la part de bruit qu'on ne paie plus.
        s.n_dl_ded_skip=0
        # Bursts de remplissage (dummy burst de C0) ecartes avant tout decodage.
        s.n_dl_dummy=0
        s.n_ul_sent=0;   s.n_ul_out_of_window=0; s.n_rach=0
        s.n_tch_dl=0;    s.n_tch_ul=0;           s.n_tch_crc=0
        s.n_a5_dl=0;     s.n_a5_ul=0
        s.n_dcch_err=0
        s.n_facch_dl=0;  s.n_facch_ul=0;  s.n_tch_gap=0
        s.n_by_base={}   # base51 -> [decodes, crc_fail]
        s.n_act_clear=[0,0]  # sous-voie ACTIVE, en clair  : [decodes, total]
        s.n_act_ciph =[0,0]  # sous-voie ACTIVE, chiffree : [decodes, total]
        s.n_bsp_fed=0;   s.n_bsp_err=0   # relais des bursts DL vers le BSP
        s.n_tch_ul_court=0               # slots montants tronques (doit rester 0)
        s.n_tch_ul_drop=0                # trames voix jetees : file pleine
        s.n_tch_ul_vole=0                # voix cedee a une FACCH (normatif)
        # Trames REELLEMENT ecrasees dans l'anneau avant qu'on les lise. A
        # distinguer de n_tch_ul_drop, qui compte ce que la file d'aval refuse :
        # ici c'est perdu en AMONT, et aucune file n'y peut rien.
        s.n_tch_ul_perdu=0
        s.n_tch_burst=0                  # bursts TCH montants reellement emis
        s.n_tap_dl=0;    s.n_tap_ul=0     # trames L2 mirroitees vers l'analyseur
    def log(s, msg): print("[pont] %s" % msg, flush=True)
ST = Stats()

# =========================== horloge FN (POINT 4) =============================
# FN = f(t - t0) sur time.monotonic() ABSOLU, jamais accumulation de sleep()
# (sinon drift cumulatif -> UL hors fenêtre après quelques minutes).
_T0 = None
def now_fn():
    return int((time.monotonic() - _T0) / FRAME_DUR) % GSM_HYPERFRAME

# =========================== sockets ==========================================
def mksock(bind_port):
    # PAS de SO_REUSEADDR : en UDP il autorise DEUX ponts a binder le meme port
    # sans erreur -> deux horloges concurrentes (t0 differents) -> la BTS voit
    # "GSM clock skew: old fn=X, new fn=Y" en boucle. Sans lui, un second pont
    # echoue BRUYAMMENT (EADDRINUSE), ce qui est le comportement voulu.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # [2026-08-27] BORNE SO_RCVBUF RETIREE -- ELLE DETRUISAIT LA VOIX.
    # J'avais borne le tampon a 10 Ko en pensant que la file (mesuree a 163840
    # o) contenait des bursts perimes traites pour rien. C'etait faux : le pont
    # est borne par le CPU (83 % d'un coeur, mono-thread sous le GIL), pas par
    # la socket. Borner le tampon ne l'accelere donc pas -- ca lui retire la
    # marge qui lui permet de rattraper pendant les creux. Mesure immediate :
    #     Recv-Q=11520 (deborde)   drops=15310 bursts jetes par le noyau
    #     CPU du pont : 83,6 %, inchange
    # et la voix disparait. Le tampon par defaut du noyau est le bon choix tant
    # que le cout par burst n'a pas baisse : la file est un SYMPTOME du CPU, pas
    # sa cause. PONT_RCVBUF=<octets> permet d'experimenter, sans defaut.
    _rb = os.environ.get("PONT_RCVBUF", "")
    if _rb:
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, int(_rb))
        except (OSError, ValueError):
            pass
    try:
        s.bind((TRX_BIND, bind_port))
    except OSError as e:
        print("[pont] ECHEC bind %s:%d (%s) — un autre pont tourne deja ?"
              % (TRX_BIND, bind_port, e), flush=True)
        raise
    return s

# CLCK/CTRL/DATA côté BTS-facing (osmo-bts-trx s'y connecte).
sk_clck = mksock(TRX_BASE + 0)     # 5700 : IND CLOCK -> BTS
sk_ctrl = mksock(TRX_BASE + 1)     # 5701 : CMD/RSP
sk_data = mksock(TRX_BASE + 2)     # 5702 : bursts (bidir)
sk_gsmtap = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)  # -> shunt in-QEMU

# ------------------------- relais des bursts DL vers le BSP -------------------
# Le module BSP de QEMU (calypso_bsp.c) ECOUTE des bursts TRXD sur 6702 —
# `BSP_TRXD_PORT 6702  /* bridge forwards DL bursts here (5702 is bridge's own) */`.
# C'etait l'ancien bridge qui l'alimentait ; en mode pont plus personne ne le
# fait, donc le BSP est a sec.
#
# ⚠️ CE QUE CA DONNE, ET CE QUE CA NE DONNE PAS. Sous DSP_SHUNT le BSP draine
# l'UDP, publie l'I/Q (feed_iq) et APPREND son peer UL — puis il `return` AVANT
# de remplir la DARAM (calypso_bsp.c ~l.545 : « le vrai DSP ne consomme JAMAIS
# la DARAM », sinon la queue sature et la backpressure tue l'IPC/BTS). Donc ceci
# reanime l'I/Q partagee (enregistrement cfile, grgsm relay) et prepare le peer,
# mais ne fait PAS demoduler le DSP : ca reste gate derriere le revive c54x
# (CALYPSO_DSP_RUN_C54X=1), lui-meme bloque par le mur de vitesse de
# l'interpreteur. Ne pas lire une reprise du natif la-dedans.
#
# Format attendu (calypso_bsp.c, TRXDv0 DL) : tn(1) fn(4 BE) rssi(1) toa(2)
# bits(148) = 156 o ; le module fait `nbits = n - 8` et `bits = buf + 8`.
# La BTS, elle, nous envoie un en-tete de 6 o (ver|tn, fn BE, pwr) : on reprend
# ces 6 o tels quels (buf[5] devient `bsp.last_att`) et on insere les 2 o de ToA.
BSP_FEED      = os.environ.get("PONT_BSP_FEED", "1") == "1"
BSP_HOST      = os.environ.get("PONT_BSP_HOST", "127.0.0.1")
BSP_PORT      = int(os.environ.get("PONT_BSP_PORT", "6702"))
sk_bsp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

_bts_addr = {"clck": None, "data": None}   # appris à la 1re trame reçue

# =========================== GSMTAP (DL -> shunt) =============================
GSMTAP_BCCH=0x01; GSMTAP_CCCH=0x04; GSMTAP_SDCCH4=0x07; GSMTAP_SACCH=0x07|0x80
# Types RR relayes (identiques a si_bridge.py:20-25) : sans ce tri, le shunt
# recoit du bourrage et le mobile ne voit jamais de sysinfo.
SI_TYPES   = {0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e}          # SI1 SI2 SI3 SI4 SI2bis SI2ter
CCCH_TYPES = {0x3f, 0x39, 0x3a, 0x21, 0x22, 0x24}          # IMM-ASSIGN(+EXT/REJ), PAG-REQ 1/2/3
def gsmtap(fn, chan, l2, tn=0, uplink=False):
    # En-tête GSMTAP v2 (16 o) : version=2, hdr_len=4 (mots 32b), type=UM(0x01),
    # timeslot, arfcn(H), signal(b), snr(B), frame_number(I), sub_type=chan,
    # antenna, sub_slot, res. Format attendu par le shunt (feed_si).
    # GSMTAP_ARFCN_F_UPLINK = 0x4000 : sans ce drapeau Wireshark interprete une
    # trame montante comme descendante et se trompe de sens de dissection.
    arfcn = ARFCN | (0x4000 if uplink else 0)
    h = struct.pack(">BBBBHbBIBBBB", 2, 4, 0x01, tn, arfcn, 0, 0, fn, chan, 0, 0, 0)
    return h + bytes(l2)

def tap(fn, chan, l2, tn=0, uplink=False):
    """Miroir d'observation. Best-effort : jamais d'exception sur ce chemin, il
    est appele depuis les boucles temps reel."""
    if not TAP:
        return
    try:
        sk_gsmtap.sendto(gsmtap(fn, chan, l2, tn, uplink), (GSMTAP_HOST, TAP_PORT))
        ST.n_tap_ul += 1 if uplink else 0
        ST.n_tap_dl += 0 if uplink else 1
    except OSError:
        pass

def feed_dl_l2(fn, chan, l2, port):
    # [audit m4] sendto garde comme tap() : ce chemin tourne dans th_data_rx, une
    # OSError (ENOBUFS sous pression) non gardee tuerait 1 s de decodage DL.
    try:
        sk_gsmtap.sendto(gsmtap(fn, chan, l2), (GSMTAP_HOST, port))
    except OSError:
        ST.n_feed_err = getattr(ST, "n_feed_err", 0) + 1
        if ST.n_feed_err <= 3:
            ST.log("feed_dl_l2 sendto ECHEC #%d (best-effort, ignore)" % ST.n_feed_err)
    tap(fn, chan, l2)          # miroir vers l'analyseur — meme L2, autre port

# ============================== VOIX TCH/F ====================================
# Contrats RELEVES dans le code (jamais supposes) :
#   /dev/shm/calypso_tch_cfg : 16 o — seq u32@0 | tn@4 | tsc@5 | arfcn u16@6 (LE)
#                              publie a l'ASSIGNMENT COMMAND (si_bridge _tch_write_cfg).
#   /dev/shm/calypso_tch_dl  : anneau — entete 8 o (w_seq u32@0 | n_slots u32@4),
#                              16 slots de 48 o : seq@0 l1s_fn@4 fn@8 fr[33]@16.
#                              ⚠️ ORDRE OBLIGATOIRE : le SLOT d'abord, w_seq ENSUITE.
#   /dev/shm/calypso_tch_ul  : meme format d'anneau, ecrit par le shunt (voix montante).
# TCH/F sur multitrame 26 : fn%26 0-11 et 13-24 = TCH, 12 = SACCH, 25 = idle.
TCH_ENABLED  = os.environ.get("PONT_TCH", "1") == "1"
TCH_CFG      = "/dev/shm/calypso_tch_cfg"
TCH_DL_PATH  = "/dev/shm/calypso_tch_dl"
TCH_UL_PATH  = "/dev/shm/calypso_tch_ul"
TCH_DL_SLOTS = 16          # = TCH_DL_RING_N du shunt, ne pas desynchroniser
TCH_DL_SLOT  = 48          # slot DESCENDANT : seq@0 | fn@4 | fr[33]@8
FR_BYTES     = 33
# ⚠️ LES DEUX ANNEAUX N'ONT PAS LE MEME SLOT. Le montant est publie par
# `tch_ul_publish_speech` (calypso_dsp_shunt.c) avec TCH_UL_SLOT_SZ=64 et une
# charge `seq@0 | l1s_fn@4 | fn@8 | fr[33]@16` — le commentaire du shunt dit
# « format IDENTIQUE au descendant », ce qui est vrai de la DISCIPLINE (entete
# 8 o, slot d'abord / w_seq ensuite) mais PAS de la taille de slot ni de
# l'offset de la trame. Reutiliser TCH_DL_SLOT ici lisait au pas de 48 dans un
# anneau de pas 64 (derive de +16 o par slot) et, comme `pread(48)` ne peut pas
# rendre les 49 octets exiges par la garde `len(sl) >= 16 + 33`, le `continue`
# etait INCONDITIONNEL : la voix montante du pont n'a jamais pu emettre une
# seule trame, par construction.
TCH_UL_SLOT  = 64          # slot MONTANT : seq@0 | l1s_fn@4 | fn@8 | fr[33]@16
TCH_UL_FR_OFS = 16
GSM_MACBLOCK_LEN = 23      # une FACCH decodee rend 23 (et non 33)
# [2026-08-16] 0x08 etait FAUX : 0x08 = GSMTAP_CHANNEL_SDCCH8. Le sous-type
# canonique de la FACCH/F est 0x09. Le shunt filtre sur un ensemble ferme
# {0x01, 0x04, 0x07, 0x87, 0x09, 0x89} et jette tout le reste (« autres canaux :
# drop ») : avec 0x08 la FACCH descendante etait DETRUITE a l'entree du shunt.
# Mesure du run : feed_facch = 0, alors que feed_si=2495 / feed_agch=4964 /
# feed_sdcch=50 / feed_sacch=16 — donc ni UA, ni ALERTING, ni CONNECT
# n'atteignaient le mobile pendant l'appel.
# ⚠️ C'est la REGRESSION d'un defaut deja solde le 12/08 cote gr-gsm
# (sous-type FACCH compare a 0x08 au lieu de 0x09), reintroduit ici.
GSMTAP_FACCH = 0x09        # GSMTAP_CHANNEL_FACCH_F

_tch_tn   = None           # timeslot TCH arme (None = pas d'appel)
_tch_seq  = 0
# ── ARMER N'EST PAS AVOIR BASCULE ────────────────────────────────────────────
# tch_cfg est publie des qu'on voit l'ASSIGNMENT COMMAND DESCENDANT. C'est la
# DEMANDE du reseau, pas la preuve que le mobile l'a suivie. Les deux etaient
# confondus, et le pont se comportait comme si le mobile avait bascule.
#
# MESURE DU 2026-08-27, appel qui echoue : mobile.log contient ZERO
# « ASSIGNMENT COMMAND » (le mobile ne l'a jamais recu, il est reste sur le
# SDCCH TS1 a retransmettre son SETUP), pendant que le pont, lui, l'avait
# decode et arme TN=2. Consequences mesurees :
#   TCHUL bursts = 4463  pour  TCH ul = 1 bloc reel
#     -> un flux montant continu sur un TS2 ou le mobile n'emet pas, d'ou le
#        deluge cote BTS : « no space for uplink measurement, num_ul_meas=104 »
#        (le tampon de 104 mesures deborde en permanence) ;
#   puis DUL->FACCH #1..#10 : le VRAI montant SDCCH detourne vers TS2, donc
#        meme les retransmissions du SETUP cessent d'atteindre le BSC
#        -> REJ, RR, T200 TIMER_RECOV, RELEASE ;
#   et cote BSC : rll_ready=no -> WAIT_RLL_RTP_ESTABLISH Timeout
#        -> « Assignment failed, cause RADIO INTERFACE MESSAGE FAILURE ».
#
# On separe donc les deux etats. Tant que le mobile n'a pas PROUVE qu'il est
# passe sur le TCH, le montant reste dans la fenetre SDCCH et AUCUN burst TCH
# n'est emis. La preuve, c'est son ASSIGNMENT COMPLETE (RR PD=0x06 MT=0x29) :
# le mobile ne peut l'envoyer que depuis le nouveau canal.
#
# Si la preuve ne vient pas, l'appel echoue toujours -- mais il echoue SANS que
# le pont brouille la piste, et la sonde ci-dessous le dit au lieu de le taire.
_tch_mobile_ok = False     # le mobile a-t-il prouve qu'il est sur le TCH ?
_tch_arme_t    = None      # instant d'armement, pour la sonde de non-confirmation
_tch_arme_dit  = False     # la non-confirmation a-t-elle deja ete signalee ?
_tch_dl_ok_t   = None      # dernier bloc DESCENDANT du TCH effectivement decode
_tch_dl_w = 0              # w_seq de l'anneau descendant
_tch_fd   = None
_tch_acc  = []             # fenetre glissante des 8 derniers bursts (114 bits)
_ded_n    = 0              # compteur de blocs dedies traces
_tch_last_fn = None        # derniere FN TCH vue (continuite de la fenetre)

def _tch_next_fn(fn):
    """FN suivante PORTANT DE LA VOIX sur le TCH/F (saute 12=SACCH, 25=idle)."""
    n = (fn + 1) % GSM_HYPERFRAME
    while n % 26 in (12, 25):
        n = (n + 1) % GSM_HYPERFRAME
    return n

# --- PRODUCTEUR de calypso_tch_cfg (c'etait si_bridge, eteint en mode pont) ---
# Sans ce fichier, tch_cfg_read() rend None et TOUT le code TCH est mort
# (compteurs TCH dl=0 ul=0). On decode donc l'ASSIGNMENT COMMAND nous-memes,
# en miroir de si_bridge.check_assignment / _tch_write_cfg.
SB_FACCH_UL = "/dev/shm/calypso_tch_facch_ul"
_tch_wseq = 0

def tch_write_cfg(tn, tsc, arfcn):
    """Publie TN/TSC/ARFCN (16 o : seq u32@0 | tn@4 | tsc@5 | arfcn u16@6).
    seq ECRIT EN DERNIER = publication atomique (contrat si_bridge)."""
    global _tch_wseq
    _tch_wseq += 1
    buf = bytearray(16)
    buf[4] = tn & 0xff
    buf[5] = tsc & 0xff
    buf[6:8] = int(arfcn).to_bytes(2, "little")
    buf[0:4] = _tch_wseq.to_bytes(4, "little")
    fd = os.open(TCH_CFG, os.O_CREAT | os.O_WRONLY, 0o644)
    try:    os.pwrite(fd, bytes(buf), 0)
    finally: os.close(fd)
    # Nouvelle assignation = nouvelle attente de preuve. Sans cette remise a
    # zero, un appel heriterait de la confirmation du precedent.
    global _tch_mobile_ok, _tch_arme_t, _tch_arme_dit
    _tch_mobile_ok = False
    _tch_arme_t    = time.monotonic()
    _tch_arme_dit  = False
    ST.log("ASSIGNMENT COMMAND -> TCH arme : TN=%d TSC=%d ARFCN=%d (seq=%u) "
           "-- EN ATTENTE de l'ASSIGNMENT COMPLETE du mobile (aucun burst "
           "montant TCH d'ici la)" % (tn, tsc, arfcn, _tch_wseq))

def check_assignment(l2, fn):
    """Detecte un ASSIGNMENT COMMAND (RR PD=0x06, MT=0x2e) sur le SDCCH DL et
    publie le TCH. Channel Description 2 (GSM 04.08 10.5.2.5), 3 octets :
      b0 chan_nr -> TN = b0 & 7
      b1 : TSC=(b1>>5)&7, H=(b1>>4)&1, ARFCN_high = b1 & 3
      b2 : ARFCN_low -> ARFCN = (high<<8)|low   [si H=0]"""
    # [audit A1] Balayage restreint {0,3} (comme est_assignment_complete /
    # est_channel_release ; les 3 detecteurs RR avaient 3 plages incoherentes) :
    # off==0 (L3 nue) etait MANQUE, et le 2..6 large armait un TCH fantome sur
    # une I-frame de contenu portant 0x06,0x2e alignes.
    for off in (0, 3):
        if len(l2) <= off + 4 or l2[off] != 0x06 or l2[off + 1] != 0x2e:
            continue
        if off == 3 and (l2[2] >> 2) < 2:      # en-tete LAPDm B : L3 >= PD+MT
            continue
        b0, b1, b2 = l2[off + 2], l2[off + 3], l2[off + 4]
        if (b1 >> 4) & 1:
            # Saut de frequence : REFUS EXPLICITE (comme si_bridge). Fabriquer
            # une ARFCN depuis MAIO/HSN donnerait un nombre FAUX en silence.
            ST.log("ASSIGNMENT COMMAND avec SAUT DE FREQUENCE (H=1) : TCH NON arme (fn=%u)" % fn)
            return
        tch_write_cfg(b0 & 0x07, (b1 >> 5) & 0x07, ((b1 & 0x03) << 8) | b2)
        return

def est_assignment_complete(l2):
    """ASSIGNMENT COMPLETE montant : RR (PD=0x06) MT=0x29, GSM 04.08 9.1.3.
    Meme balayage d'offset que check_assignment : selon que la L2 porte un
    en-tete LAPDm B (addr/ctrl/len) ou une SABM avec information, la L3 ne
    commence pas au meme octet -- on ne fige donc pas la position."""
    # [audit M1] Balayage RESTREINT a {0,3} : le large 0..7 atteignait les octets
    # d'en-tete LAPDm (ctrl/len) et une I-frame ordinaire (N(S)=3 -> ctrl=0x06,
    # len=0x29) matchait a off=1 -> bascule TCH fantome qui detournait tout le
    # montant SDCCH (cause n1 des 'appels/SMS 1 fois sur 3').
    for off in (0, 3):
        if len(l2) > off + 1 and l2[off] == 0x06 and l2[off + 1] == 0x29:
            if off == 3 and (len(l2) < 3 or (l2[2] >> 2) < 2):
                continue
            return True
    return False

# ── ARMER SANS JAMAIS DESARMER, C'EST PIRE QUE NE PAS ARMER ──────────────────
# [2026-08-27] La preuve de bascule (ci-dessus) a ouvert le montant TCH, et
# RIEN ne le refermait. Mesure du run de 19:2x, un appel puis plus rien :
#   TCH dl=460 ul=98   (fige des la liberation)
#   TCHUL bursts=3489 -> 14486 ... +1000 par intervalle de 5 s, INDEFINIMENT
# Le pont continuait d'arroser le TS du TCH bien apres la fin de l'appel --
# exactement le deluge decrit plus haut (« no space for uplink measurement,
# num_ul_meas=104 » cote BTS). Et surtout, tant que `_tch_mobile_ok` tient,
# ul_sdcch_from_sideband DETOURNE tout le montant SDCCH vers la FACCH de ce TS :
# apres le premier appel, plus une SABM, plus un CM SERVICE REQUEST, plus un
# SMS n'atteignait le BSC. Symptomes rapportes : « les calls passent une fois
# sur 3 », « les SMS passent pas », et dans mobile.log les appels suivants qui
# meurent tous en MMCC_REL_IND depuis MM_CONNECTION_PEND -- la couche MM
# n'arrivait meme plus a s'etablir.
#
# Le TN n'est pas fige : osmo-bsc est en `channel allocator mode assignment
# ascending` (et `chan-req descending` pour le SDCCH), donc le TCH peut tomber
# sur n'importe quel TS libre. Tout ce qui suit lit le TN arme, ne le suppose
# jamais.
TCH_DL_SILENCE_S = 3.0     # sans un seul bloc DL decode pendant ce temps, on ferme

def est_channel_release(l2):
    """RR CHANNEL RELEASE descendant : PD=0x06 MT=0x0D (GSM 04.08 9.1.7).
    C'est le message par lequel le reseau reprend le canal a la fin de l'appel.
    Balayage RESTREINT aux deux seules positions ou la L3 peut commencer : 0
    (L3 nue) et 3 (en-tete LAPD B : addr, ctrl, length). Le balayage large de
    est_assignment_complete se paie ici en faux positifs -- un desarmement a
    tort couperait un appel EN COURS."""
    for off in (0, 3):
        if len(l2) > off + 1 and l2[off] == 0x06 and l2[off + 1] == 0x0d:
            return True
    return False

def tch_preuve_bascule(source, tn):
    """Le mobile a PROUVE qu'il est sur le TCH : on ouvre le montant, et on
    arme du meme coup le chien de garde qui le refermera."""
    global _tch_mobile_ok, _tch_dl_ok_t
    if _tch_mobile_ok:
        return
    _tch_mobile_ok = True
    _tch_dl_ok_t   = time.monotonic()
    ST.log("le mobile est sur le TCH TN=%s (preuve : %s) -- ouverture du "
           "montant TCH" % (tn, source))

def _tch_dl_vivant():
    """Un bloc descendant du TCH vient d'etre decode : le canal vit."""
    global _tch_dl_ok_t
    _tch_dl_ok_t = time.monotonic()
    # [audit m3] Canal SUSPENDU par le watchdog mais toujours arme : un bloc DL
    # qui revient rouvre le montant -> l'appel survit au hoquet d'ordonnancement.
    if not _tch_mobile_ok and _tch_tn is not None:
        tch_preuve_bascule("bloc DL redecode apres suspension", _tch_tn)

def tch_suspend(motif):
    """[audit m3] Desarme SOFT : SUSPEND l'emission montante (le mobile n'est plus
    repute present) mais GARDE le canal arme (_tch_tn/_tch_seq intacts). Un trou DL
    bref (~3 s, hoquet QEMU) ne tue donc plus un appel que le radio-link-timeout
    reel (~15 s) tolererait ; des qu'un bloc DL est redecode, _tch_dl_vivant ->
    tch_preuve_bascule rouvre le montant. On ne remet PAS _tch_seq=0."""
    global _tch_mobile_ok, _tch_dl_ok_t, _tch_tx_mask
    if not _tch_mobile_ok:
        return
    _tch_mobile_ok = False
    _tch_dl_ok_t   = None
    _tch_tx_mask   = 0
    ctypes.memset(_tch_tx_buf, 0, TCH_TX_NBURSTS * BPLEN)
    with _tch_q_lock:
        _tch_q_facch.clear(); _tch_q_voice.clear()
    ST.log("TCH TN=%s SUSPENDU (%s) -- montant rendu au SDCCH, canal garde arme"
           % (_tch_tn, motif))

def tch_desarme(motif):
    """Referme le TCH : plus un burst montant, et le montant SDCCH redevient
    du SDCCH. On ne touche PAS au fichier calypso_tch_cfg : tch_cfg_read ne
    relit son TN que si le `seq` a change, donc remettre _tch_tn a None suffit
    a tenir jusqu'au prochain ASSIGNMENT COMMAND, qui incrementera ce seq."""
    global _tch_tn, _tch_mobile_ok, _tch_arme_t, _tch_arme_dit
    global _tch_last_fn, _tch_dl_ok_t, _tch_tx_mask
    if _tch_tn is None and not _tch_mobile_ok:
        return
    tn = _tch_tn
    _tch_tn = None; _tch_mobile_ok = False
    _tch_arme_t = None; _tch_arme_dit = False
    _tch_last_fn = None; _tch_dl_ok_t = None
    del _tch_acc[:]
    # [audit m2] Reset du tampon d'emission : sans ca _tch_tx_mask garde bit0=1 et
    # _tch_tx_buf le contenu (voix+FACCH) de l'appel precedent -> bursts perimes
    # emis au re-ancrage de l'appel suivant.
    _tch_tx_mask = 0
    ctypes.memset(_tch_tx_buf, 0, TCH_TX_NBURSTS * BPLEN)
    with _tch_q_lock:
        _tch_q_facch.clear()
        _tch_q_voice.clear()
    ST.log("TCH TN=%s DESARME (%s) -- montant rendu au SDCCH" % (tn, motif))

def ul_facch_from_sideband():
    """FACCH montante : l'ASSIGNMENT COMPLETE du mobile part par la. Sans elle,
    le BSC reste en rll_ready=no et l'assignation echoue (EQUIPMENT FAILURE).
    Meme layout 48 o que le SDCCH UL : seq@0 l1s_fn@4 fn@8 task_u@12 l1s%51@14 l2[23]@16."""
    fd = None; last = 0
    while True:
        tn = tch_cfg_read()
        if tn is None or not TCH_ENABLED:
            time.sleep(0.1); continue
        try:
            if fd is None:
                fd = os.open(SB_FACCH_UL, os.O_RDONLY)
            b = os.pread(fd, 48, 0)
            if len(b) >= 39:
                seq = struct.unpack_from("<I", b, 0)[0]
                if seq and seq != last:
                    last = seq
                    l2 = b[16:39]
                    # FACCH = bloc L2 de 23 o encode par gsm0503_tch_fr_encode
                    # avec len=GSM_MACBLOCK_LEN : la lib pose les bits de vol.
                    # [2026-08-16] ALIMENTATEUR, PLUS EMETTEUR. Ce thread postait
                    # lui-meme 8 bursts via emit_with_timing, en meme temps que
                    # tch_ul_loop faisait pareil pour la voix : deux threads sans
                    # aucun verrou (il n'y a AUCUN Lock dans ce fichier) qui
                    # calculaient chacun leur next_tch_fn() sur le MEME slot. Les
                    # deux sequences de 8 bursts s'entrelacaient et se
                    # detruisaient mutuellement -> voix hachee ET liberation
                    # d'appel qui n'aboutit pas (le DISC part sur FACCH).
                    # Desormais on FILE le bloc L2 ; l'ordonnanceur unique
                    # l'emettra, en volant la voix comme le fait une vraie FACCH.
                    tap(now_fn(), GSMTAP_FACCH, l2[:GSM_MACBLOCK_LEN],
                        tch_cfg_read() or 0, True)
                    # ── LA PREUVE DE LA BASCULE ARRIVE *ICI*, PAS SUR LE SDCCH ──
                    # [2026-08-27] Le garde `_tch_mobile_ok` n'etait pose que dans
                    # ul_sdcch_from_sideband, sur l'hypothese « le firmware ne poste
                    # que DUL, donc l'ASSIGNMENT COMPLETE ressort par
                    # calypso_sdcch_ul ». Elle est FAUSSE des que le shunt capture la
                    # FACCH du TCH : /dev/shm/calypso_tch_facch_ul existe et se
                    # remplit pendant l'appel. Le montant arrivait donc par CE thread,
                    # qui empilait sans jamais poser la preuve -- et tch_ul_scheduler,
                    # qui l'attend, se taisait. VERROU MORT : la preuve dormait dans
                    # la file qu'elle devait debloquer.
                    #
                    # MESURE DU RUN DE 19:16 (appel MS#1 -> MS#2, echec) :
                    #   [pont] TCH arme TN=2 depuis 5 s SANS ASSIGNMENT COMPLETE
                    #   FACCH dl=0 ul=7 | TCHUL bursts=0 file_v=0 file_f=7 drop=0
                    # 7 blocs en file = la SABM + ses 6 retransmissions (T200 x6),
                    # ZERO burst emis. Cote mobile : ASSIGNMENT COMPLETE (cause #0)
                    # puis 6 x « Timeout T200 state=LAPD_STATE_SABM_SENT » et
                    # ASSIGNMENT FAILURE (cause #1) ; cote BSC :
                    # WAIT_RLL_RTP_ESTABLISH Timeout (rll_ready=no) -> « Assignment
                    # failed, cause RADIO INTERFACE MESSAGE FAILURE » ; cote MSC :
                    # « Assignment Failure, releasing call ». Le mobile avait bien
                    # bascule -- c'est le pont qui refusait de le suivre.
                    #
                    # Un bloc present dans calypso_tch_facch_ul est CAPTE SUR LE TCH
                    # par le shunt : sa seule existence prouve que le mobile y est.
                    # On n'exige donc pas d'y reconnaitre le MT 0x29 -- on le TRACE
                    # quand c'est lui, pour que la piste reste lisible.
                    tch_preuve_bascule(
                        "bande laterale FACCH%s"
                        % (", ASSIGNMENT COMPLETE"
                           if est_assignment_complete(l2) else ""), tn)
                    with _tch_q_lock:
                        _tch_q_facch.append(bytes(l2[:GSM_MACBLOCK_LEN]))
                    ST.n_facch_ul += 1
        except OSError:
            fd = None; time.sleep(0.05)
        time.sleep(FRAME_DUR / 8)

_tch_cfg_fd = None
_tch_cfg_t  = 0.0
TCH_CFG_TTL = float(os.environ.get("PONT_TCH_CFG_TTL", "0.1"))

def tch_cfg_read():
    """TN du TCH assigne, ou None. Publie a l'ASSIGNMENT, donc jamais devine.
    [audit M4] fd PERSISTANT + cache TTL (comme kc_read/_dcch_cfg) : l'ancienne
    version faisait open+pread+close A CHAQUE appel (chaque burst DL + l'emetteur
    UL temps-reel), la charge syscall que kc_read avait supprimee ('Stale TRXD',
    voix hachee). PONT_TCH_CFG_TTL=0 pour relire a chaque appel."""
    global _tch_tn, _tch_seq, _tch_cfg_fd, _tch_cfg_t
    now = time.monotonic()
    if _tch_cfg_fd is not None and TCH_CFG_TTL and (now - _tch_cfg_t) < TCH_CFG_TTL:
        return _tch_tn
    _tch_cfg_t = now
    try:
        if _tch_cfg_fd is None:
            _tch_cfg_fd = os.open(TCH_CFG, os.O_RDONLY)
        b = os.pread(_tch_cfg_fd, 16, 0)
    except OSError:
        try:
            if _tch_cfg_fd is not None:
                os.close(_tch_cfg_fd)
        except OSError:
            pass
        _tch_cfg_fd = None
        return _tch_tn
    if len(b) >= 8:
        seq = struct.unpack_from("<I", b, 0)[0]
        if seq and seq != _tch_seq:
            _tch_seq = seq
            _tch_tn  = b[4] & 7
            ST.log("TCH arme : TN=%d TSC=%d ARFCN=%d (seq=%u)"
                   % (_tch_tn, b[5], struct.unpack_from("<H", b, 6)[0], seq))
    return _tch_tn

def _tch_dl_open():
    """Cree/ouvre l'anneau descendant au format attendu par le shunt."""
    global _tch_fd, _tch_dl_w
    if _tch_fd is not None:
        return _tch_fd
    _tch_fd = os.open(TCH_DL_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    os.ftruncate(_tch_fd, 8 + TCH_DL_SLOTS * TCH_DL_SLOT)
    os.pwrite(_tch_fd, (0).to_bytes(4, "little") + TCH_DL_SLOTS.to_bytes(4, "little"), 0)
    _tch_dl_w = 0
    ST.log("anneau voix DL pret : %s (%d slots de %d o)" % (TCH_DL_PATH, TCH_DL_SLOTS, TCH_DL_SLOT))
    return _tch_fd

def tch_dl_publish(fr33, fn):
    """Publie une trame FR dans l'anneau : SLOT d'abord, w_seq ENSUITE."""
    global _tch_dl_w
    fd = _tch_dl_open()
    _tch_dl_w += 1
    # [2026-08-16] OFFSET CORRIGE — la trame FR se pose a 8, pas a 16.
    # Contrat REEL du shunt (calypso_dsp_shunt.c) : slot de TCH_DL_SLOT=48 o, et
    # la trame est lue par `memcpy(g_shunt.tch_dl_fr, buf + 8, 33)` — deux sites,
    # le tirage direct et le depilage de la file. Donc : seq@0 | fn@4 | fr[33]@8.
    # L'arithmetique suffit a le prouver : a l'offset 16 il faudrait 16+33 = 49 o
    # dans un slot de 48.
    # CE QUE L'ANCIENNE VERSION PRODUISAIT : elle ecrivait seq@0 | fn@4 | fn@8 |
    # 0x00 x4 @12 | fr@16, et son bourrage `b"\x00" * (48 - 16 - 33)` valait
    # `b"\x00" * -1` = b"" — donc rec faisait 49 o et le `rec[:48]` AMPUTAIT
    # fr[32]. Le shunt recopiait alors buf+8 = les 4 octets de fn, 4 zeros, puis
    # seulement fr[0..24] : signature FR a 0x7 au lieu de 0xD, 25 octets de voix
    # sur 33, decales de 8. gapk ne pouvait rendre que du bruit.
    rec = (_tch_dl_w.to_bytes(4, "little")
           + (fn & 0xffffffff).to_bytes(4, "little")
           + bytes(fr33)[:FR_BYTES])
    rec += b"\x00" * (TCH_DL_SLOT - len(rec))     # 48 - 41 = 7 o de bourrage
    assert len(rec) == TCH_DL_SLOT
    os.pwrite(fd, rec, 8 + ((_tch_dl_w - 1) % TCH_DL_SLOTS) * TCH_DL_SLOT)
    os.pwrite(fd, _tch_dl_w.to_bytes(4, "little"), 0)     # w_seq EN DERNIER
    ST.n_tch_dl += 1

def tch_dl_burst(fn, burst148):
    """DL : accumule les bursts TCH et decode un bloc voix tous les 4 bursts
    (entrelacement diagonal : la fenetre porte les 8 derniers)."""
    m26 = fn % 26
    if m26 in (12, 25):          # 12 = SACCH du TCH, 25 = idle : pas de voix
        return
    burst148 = a5_apply(burst148, fn, False)      # TCH : canal dedie -> chiffre
    # ⚠️ CONTINUITE DES FN. La fenetre de 8 bursts n'a de sens que si les bursts
    # sont CONSECUTIFS sur le canal. On accumulait a l'aveugle : un seul burst
    # manquant (perdu, ou un autre timeslot intercale) desalignait le bloc et
    # TOUT echouait ensuite en silence (mesure : 29 decodes pour 3653 echecs).
    # On repart donc de zero des qu'il y a un trou.
    global _tch_last_fn
    exp = _tch_next_fn(_tch_last_fn) if _tch_last_fn is not None else None
    if exp is not None and fn != exp:
        del _tch_acc[:]                          # trou -> fenetre invalide
        ST.n_tch_gap += 1
    _tch_last_fn = fn
    _tch_acc.append(burst116_from_normal(burst148))
    if len(_tch_acc) > 8:
        del _tch_acc[0]
    # ⚠️ CORRIGE (audit) : l'indice de burst n'est PAS fn%26 — le trou SACCH a
    # m26==12 le decale. idx = m26 si m26<12, sinon m26-1. Les frontieres de bloc
    # (idx 7,11,15,19,23) tombent donc sur m26 ∈ {7,11,16,20,24}.
    idx = _tch_burst_idx(fn)
    # [audit M3] Instantane ATOMIQUE : tch_suspend/tch_desarme (thread scheduler)
    # peut faire 'del _tch_acc[:]' entre le garde de longueur et le join. list()
    # est une copie C atomique sous GIL -> un del concurrent donne au pire un acc
    # court, capte par le garde len(acc)<8 au lieu de lever ValueError et de tuer
    # th_data_rx (1 s sans recvfrom = tout le DL decroche).
    acc = list(_tch_acc)
    if len(acc) < 8 or (idx % 4) != 3:
        return
    # ⚠️ CORRIGE (audit) : gsm0503_tch_fr_decode indexe &bursts[i*116] — 8x116,
    # PAS 8x114 (les 2 bits de vol sont DANS les 116, poses par tch_burst_map).
    # L'ancienne allocation 8*114 faisait lire 928 octets dans 912 (hors bornes)
    # avec un pas decale : le codec ne pouvait produire que du bruit.
    buf = (sbit * (8 * 116)).from_buffer_copy(
            b"".join(bytes(b).translate(_TBL_SOFT) for b in acc))
    fr = (ctypes.c_uint8 * FR_BYTES)()
    ne = ctypes.c_int(); nb = ctypes.c_int()
    # net_order = 1 (3e argument). osmo-bts et trxcon decodent TOUS DEUX avec 1
    # (sched_lchan_tchf.c : `gsm0503_tch_fr_decode(..., 1, 0, ...)`). A 0,
    # tch_fr_reassemble range autrement les bits de la trame de parole : les
    # parametres GSM 06.10 atterrissent aux mauvaises places et gapk rend un son
    # robotise. La FACCH (rc == 23) ne passe pas par ce chemin et restait donc
    # correcte — d'ou une signalisation saine et une voix fausse.
    rc = _cod.gsm0503_tch_fr_decode(fr, buf, 1, 0, ctypes.byref(ne), ctypes.byref(nb))
    if rc == FR_BYTES:
        _tch_dl_vivant()                       # le canal vit : chien de garde repousse
        tch_dl_publish(bytes(fr), fn)          # 33 o = trame voix FR
    elif rc == GSM_MACBLOCK_LEN:
        # ⚠️ CORRIGE (audit) : la lib rend 23 quand les bits de vol disent FACCH.
        # On jetait donc UA / ALERTING / CONNECT en les comptant « CRC fail ».
        _tch_dl_vivant()
        feed_dl_l2(fn, GSMTAP_FACCH, bytes(fr)[:GSM_MACBLOCK_LEN], PORT_GSMTAP)
        ST.n_facch_dl += 1
        # La fin d'appel arrive par la : le reseau reprend le canal avec un RR
        # CHANNEL RELEASE sur la FACCH. C'est le signal le plus PRECOCE dont on
        # dispose -- le chien de garde de tch_ul_scheduler n'est que le filet.
        if est_channel_release(bytes(fr)[:GSM_MACBLOCK_LEN]):
            tch_desarme("CHANNEL RELEASE descendant sur la FACCH")
            kc_lacher("CHANNEL RELEASE (FACCH)")
    else:
        ST.n_tch_crc += 1

def tch_ul_loop():
    """UL : consomme l'anneau voix montant EN ORDRE et emet 8 bursts TCH."""
    fd = None; last = 0
    while True:
        tn = tch_cfg_read()
        if tn is None or not TCH_ENABLED:
            time.sleep(0.1); continue
        try:
            if fd is None:
                fd = os.open(TCH_UL_PATH, os.O_RDONLY)
            hdr = os.pread(fd, 8, 0)
            if len(hdr) < 8:
                time.sleep(0.02); continue
            w, n = struct.unpack("<II", hdr)
            if not w or not n:
                time.sleep(0.02); continue
            # ── LE RATTRAPAGE JETAIT CE QU'IL POUVAIT ENCORE LIRE ───────────
            # Deux situations distinctes etaient traitees par la meme ligne, et
            # la seconde y perdait 15 trames sur 16.
            #
            #   PREMIER TOUR (last == 0) : l'anneau vit dans /dev/shm, il
            #     SURVIT a un redemarrage du pont. Ce qu'il contient appartient
            #     a la session precedente. Rejouer meme une seule de ces trames
            #     injecte 20 ms de voix d'un appel deja fini. On se cale donc
            #     sur w : rien d'ancien.
            #
            #   DEPASSEMENT ((w - last) > n) : on a pris du retard et les plus
            #     vieilles trames ont ete ECRASEES. Mais les n dernieres, elles,
            #     sont toujours la. « last = w - 1 » n'en gardait qu'UNE et
            #     jetait les 15 autres - 300 ms de voix parfaitement lisibles,
            #     a chaque hoquet du thread. C'est ce qui restait du son
            #     robotise apres l'ajout de la file : la file absorbe la gigue
            #     EN AVAL, elle ne peut rien pour ce que la lecture a deja
            #     jete EN AMONT.
            #     On repart donc de la plus ancienne trame ENCORE VALIDE.
            if last == 0:
                last = w                          # session precedente : on ignore
            elif (w - last) > n:
                ST.n_tch_ul_perdu += (w - last) - n
                last = w - n                      # tout ce qui reste lisible
            while last < w:
                last += 1
                sl = os.pread(fd, TCH_UL_SLOT, 8 + ((last - 1) % n) * TCH_UL_SLOT)
                if len(sl) < TCH_UL_FR_OFS + FR_BYTES:
                    ST.n_tch_ul_court += 1       # ne doit JAMAIS bouger : slot tronque
                    continue
                fr = sl[TCH_UL_FR_OFS:TCH_UL_FR_OFS + FR_BYTES]
                # ALIMENTATEUR, PLUS EMETTEUR — cf. le commentaire de
                # ul_facch_from_sideband. En prime, emit_with_timing attendait
                # ACTIVEMENT chaque burst : 40 a 160 ms par trame vocale, quand
                # la voix arrive toutes les 20 ms. Ce thread ne pouvait pas
                # suivre, le garde « retard > 1 tour » remettait last = w-1 et
                # des TOURS ENTIERS de l'anneau partaient a la poubelle. C'est
                # ca, le son robotise. Une file bornee absorbe la gigue et le
                # trop-plein est compte, pas tu.
                with _tch_q_lock:
                    if len(_tch_q_voice) == _tch_q_voice.maxlen:
                        ST.n_tch_ul_drop += 1
                    _tch_q_voice.append(bytes(fr))
                ST.n_tch_ul += 1
        except OSError:
            fd = None; time.sleep(0.05)
        time.sleep(0.002)

# ====================== ORDONNANCEUR UNIQUE DU TCH MONTANT ====================
# Portage fidele de `tx_tchf_fn` (trxcon, sched_lchan_tchf.c) — la reference du
# cote MS, celle que qemu_wrap.c:1555-1560 suit deja et qui AVAIT la voix.
#
# CE QU'ON REMPLACE. Le pont emettait 8 bursts d'un coup depuis un tampon NEUF a
# chaque trame, depuis deux threads concurrents et sans verrou. Trois defauts en
# un : (1) blocs consecutifs qui se detruisent, faute du recouvrement de 4 bursts
# qu'impose l'entrelacement diagonal ; (2) voix et FACCH qui se marchent dessus
# sur le meme slot ; (3) debit impossible a tenir (attente active).
#
# LA DISCIPLINE, telle que la fixe tx_tchf_fn :
#   - tampon PERSISTANT de 24 bursts de 116 bits ;
#   - a chaque frontiere de bloc (bid == 0) : decalage de 4 bursts vers la
#     gauche, mise a zero des 4 derniers, masque decale de 4 ;
#   - on retire alors UNE trame voix et UN bloc FACCH, et la FACCH GAGNE : c'est
#     le vol de trame, le comportement normatif ;
#   - `gsm0503_tch_fr_encode(buf, NULL, 0, 1)` quand il n'y a rien : la lib pose
#     un bloc muet a CRC3 inverse. Le silence se TRANSMET, il ne s'omet pas ;
#   - on emet EXACTEMENT UN burst par trame porteuse, celui d'indice bid ;
#   - a bid > 0, si le bit 0 du masque n'est pas pose, aucun bloc n'a ete charge :
#     on n'emet rien plutot que du tampon vide.
TCH_TX_NBURSTS = 24
BPLEN          = 116
_tch_tx_buf    = (ubit * (TCH_TX_NBURSTS * BPLEN))()
_tch_tx_mask   = 0
_tch_q_lock    = threading.Lock()
_tch_q_facch   = collections.deque(maxlen=8)    # blocs L2 de 23 o
_tch_q_voice   = collections.deque(maxlen=4)    # trames FR de 33 o (80 ms de gigue)

def _tch_tx_load_block():
    """Frontiere de bloc : decale le tampon et y encode le prochain contenu."""
    global _tch_tx_mask
    ctypes.memmove(_tch_tx_buf, ctypes.byref(_tch_tx_buf, 4 * BPLEN), 20 * BPLEN)
    ctypes.memset(ctypes.byref(_tch_tx_buf, 20 * BPLEN), 0, 4 * BPLEN)
    _tch_tx_mask = (_tch_tx_mask << 4) & 0xFFFFFFFF
    with _tch_q_lock:
        facch = _tch_q_facch.popleft() if _tch_q_facch else None
        voice = _tch_q_voice.popleft() if _tch_q_voice else None
    msg = facch if facch is not None else voice     # la FACCH VOLE la voix
    if msg is None:
        # NULL -> bloc muet a CRC3 inverse (tx_tchf_fn fait exactement ca).
        _cod.gsm0503_tch_fr_encode(_tch_tx_buf, None, 0, 1)
    else:
        data = (ctypes.c_uint8 * len(msg))(*msg)
        # net_order = 1 : valeur de TOUTES les implementations qui font autorite
        # (osmo-bts, trxcon, qemu_wrap). A 0, tch_fr_disassemble range les bits
        # de la trame de parole autrement -> voix robotisee. Sans effet sur la
        # FACCH, qui ne passe pas par ce chemin : d'ou une signalisation saine
        # et un son faux, exactement le tableau observe.
        _cod.gsm0503_tch_fr_encode(_tch_tx_buf, data, len(msg), 1)
    if facch is not None and voice is not None:
        ST.n_tch_ul_vole += 1      # la voix cedee a la FACCH, c'est normatif

def tch_ul_scheduler():
    """UN SEUL emetteur sur le TCH montant : un burst par trame porteuse."""
    global _tch_tx_mask
    last_fn = None
    while True:
        tn = tch_cfg_read()
        if tn is None or not TCH_ENABLED:
            time.sleep(0.05); last_fn = None; continue
        # Emettre avant la preuve, c'est arroser un slot ou le mobile n'est pas :
        # 4463 bursts pour 1 bloc reel, et le tampon de mesures du BTS qui
        # deborde a chaque trame. On se tait.
        if not _tch_mobile_ok:
            global _tch_arme_dit
            if (not _tch_arme_dit and _tch_arme_t is not None
                    and time.monotonic() - _tch_arme_t > 5.0):
                _tch_arme_dit = True
                ST.log("TCH arme TN=%d depuis 5 s SANS ASSIGNMENT COMPLETE : le "
                       "mobile n'a pas bascule (il n'a probablement pas recu "
                       "l'ASSIGNMENT COMMAND). Montant maintenu sur le SDCCH." % tn)
            time.sleep(0.05); last_fn = None; continue
        # ── LE FILET : un TCH vivant PARLE en descendant ─────────────────────
        # Pendant un appel la BTS emet en continu sur ce TS -- on y decode un
        # bloc (voix ou FACCH) plusieurs dizaines de fois par seconde. Des que
        # le canal est rendu, ca s'arrete net. Si le CHANNEL RELEASE s'est
        # perdu (il traverse une FACCH dont 45 % des blocs echouent au CRC sur
        # ce banc), c'est ce silence-la qui referme le TCH -- sans lui, un seul
        # RELEASE manque et le pont arrose le slot jusqu'au prochain
        # redemarrage, en emportant tout le montant SDCCH avec lui.
        if (_tch_dl_ok_t is not None
                and time.monotonic() - _tch_dl_ok_t > TCH_DL_SILENCE_S):
            tch_suspend("aucun bloc descendant decode depuis %.0f s"
                        % TCH_DL_SILENCE_S)
            time.sleep(0.05); last_fn = None; continue
        fn_air = (now_fn() + UL_FN_ADVANCE) % GSM_HYPERFRAME
        if fn_air == last_fn:
            time.sleep(FRAME_DUR / 4); continue
        last_fn = fn_air
        if fn_air % 26 in (12, 25):        # SACCH / idle : pas de burst TCH
            continue
        bid = _tch_burst_idx(fn_air) % 4
        if bid == 0:
            _tch_tx_load_block()
        elif not (_tch_tx_mask & 0x01):
            continue                        # aucun bloc charge : on se tait
        base = bid * BPLEN
        b148 = normal_from_burst116([_tch_tx_buf[base + i] for i in range(BPLEN)])
        _tch_tx_mask |= (1 << bid)
        send_trxd_ul(tn, fn_air, b148, cipher=True)
        ST.n_tch_burst += 1

def _tch_burst_idx(fn):
    """Indice du burst dans le multiframe 26, SANS les trames 12 (SACCH) et
    25 (idle) : m26<12 -> m26 ; 13..24 -> m26-1. Va de 0 a 23."""
    m = fn % 26
    return m if m < 12 else m - 1

def next_tch_fn(min_advance=4):
    """Prochaine FN de NOTRE horloge ouvrant un BLOC TCH/FACCH.

    ⚠️ Pas n'importe quelle trame porteuse : un bloc occupe 8 bursts et commence
    sur une FRONTIERE (indice multiple de 4). Demarrer au milieu produit un bloc
    que la BTS ne reassemble jamais — c'est ce qui laissait le BSC en
    « rll_ready=no » malgre une FACCH montante bien emise."""
    start = now_fn() + min_advance
    for k in range(52):
        fn = (start + k) % GSM_HYPERFRAME
        if fn % 26 in (12, 25):
            continue
        if _tch_burst_idx(fn) % 4 == 0:
            return fn
    return start % GSM_HYPERFRAME

# =========================== DISPATCH par canal (POINT 2) =====================
# (tn, fn) -> quel codage + où router. v1 : SCH, BCCH/CCCH, SDCCH+SACCH, RACH.
# TCH réservé (entrées présentes, non câblées) — cf. ordre de mise au point.
def dl_dispatch(tn, fn, burst148):
    """Décode un burst DL reçu de la BTS et le route vers le shunt. Gère le
    réassemblage 4-bursts pour xcch (POINT 1)."""
    # ⚠️ PAS de dechiffrement global ici : BCCH / SCH / FCCH / CCCH (AGCH, PCH)
    # ne sont JAMAIS chiffres. Leur appliquer le keystream les DETRUIT (mesure :
    # dl_dec effondre a 26 %, A5 dl=40198). Le A5 ne s'applique QU'AU CANAL DEDIE
    # (SDCCH/SACCH/TCH), et seulement la — cf. _acc_dl et tch_dl_burst.
    phys = TS_CONFIG.get(tn, "")
    m51 = fn % 51
    # --- SCH : 1 burst (pas de réassemblage) ---
    if tn == 0 and m51 in (1, 11, 21, 31, 41):
        # Burst SCH = [3 tail][39 data][64 training etendu][39 data][3 tail] = 148.
        # gsm0503_sch_decode attend les 2x39 bits de DONNEES (78), pas le burst
        # brut. Et meme convention sbit que xcch : ubit 1 -> -127, 0 -> +127.
        d78 = list(burst148[3:42]) + list(burst148[106:145])
        buf = (sbit*78)(*[-127 if b else 127 for b in d78])
        sb = (ctypes.c_uint8*4)()
        if _cod.gsm0503_sch_decode(sb, buf) == 0:
            # SCH -> feed_sb (4731) : BSIC + FN
            try:
                sk_gsmtap.sendto(b"SCH1" + struct.pack("<iii", BSIC, fn, 0), (GSMTAP_HOST, PORT_SCH))
            except OSError:
                pass
        return
    # --- xcch : UNIQUEMENT les slots de signalisation. Les TS TCH/F envoient
    # de la voix/du dummy : les passer a xcch_decode ne produit que des CRC
    # fail et noie le compteur. v1 = CCCH+SDCCH4 / SDCCH8 seulement.
    if TCH_ENABLED and tn == tch_cfg_read():
        tch_dl_burst(fn, burst148)            # TS du TCH assigne -> voix
        return
    if not (phys.startswith("CCCH") or phys.startswith("SDCCH")):
        return
    _acc_dl(tn, phys, fn, burst148)

_DL_ACC = {}   # clé bloc -> {fn0, bursts[4]}

# GSM 05.02 — multiframe 51 sur TS0 (référence si_bridge.py:10-13, fn51_role) :
#   FCCH {0,10,20,30,40} · SCH {1,11,21,31,41} · BCCH {2..5} · idle 50
#   blocs de 4 bursts, bases : 2(BCCH) 6,12,16(CCCH) 22,26,32,36(SDCCH/4 SS0..3)
#   42,46(SACCH) — c'est la table que si_bridge utilise (_SD4_DL=[22,26,32,36]).
# Le groupement fn//4 de la v1 était FAUX : il coupait les blocs n'importe où,
# d'où 100 % de CRC fail.
# [2026-08-21] PLAN DE BLOCS PAR COMBINAISON — le trou qui tuait la LU sur MS1.
# Ces deux tables etaient l'UNIQUE plan du pont, et c'est celui du TS0 combine.
# `TS_CONFIG` lisait bien « SDCCH8 » dans osmo-bsc.cfg et le journal l'affichait
# au demarrage, mais la valeur ne servait QU'A un `startswith` (« ce slot est-il
# de la signalisation ? ») : le plan de trames, lui, restait /4 partout. Un
# portier ouvert sur une piece qui n'existe pas. Des que le BSC a alloue du
# SDCCH/8 (channel allocator descending), la SABM partait sur le TS0 aux bases
# du /4 -> la BTS n'entendait rien -> rll_ready=no -> T200 -> LU echouee.
#
# Les deux AUTRES implementations du banc connaissent deja le /8 :
#   calypso_dsp_shunt.c:set_dcch()  /4 -> {22,26,32,36}[ss]  ·  /8 -> ss*4
#   qemu_wrap.c:2089               UL /8 -> (ss*4 + 15) % 51
# On reprend leur table a l'identique. Trois implementations qui divergeraient
# sur ces bases produiraient un montant hors fenetre EN SILENCE.
UL_OFFSET51 = 15        # GSM 05.02 : le bloc montant demarre 15 trames apres le DL

class SlotPlan:
    """Plan 51-multitrame d'un slot de signalisation : ou sont les blocs de 4
    bursts, lesquels sont du canal DEDIE (donc chiffrables A5), ou repondre."""
    def __init__(s, name, sdcch_dl, sacch_dl, other_dl):
        s.name     = name
        s.n_sub    = len(sdcch_dl)          # 4 ou 8 sous-voies
        s.sdcch_dl = tuple(sdcch_dl)        # base DL fn%51, index = sous-voie
        s.sacch_dl = tuple(sacch_dl)        # bases DL fn%51 des SACCH
        s.other_dl = tuple(other_dl)        # BCCH/CCCH : jamais chiffre, jamais dedie
        # SACCH : la base fn%51 NE SUFFIT PAS a identifier la sous-voie — elles
        # se partagent les memes bases et ne se separent que sur la 102-multitrame
        # (moitie basse pour les sous-voies hautes). D'ou une table sur 102 :
        # /4 -> 42,46,93,97   ·   /8 -> 32,36,40,44,83,87,91,95.
        _half = len(sacch_dl)
        s.sacch_dl102 = tuple(sacch_dl[i % _half] + (51 if i >= _half else 0)
                              for i in range(s.n_sub))
        s.ded_bases   = tuple(sorted(set(s.sdcch_dl + s.sacch_dl)))
        s.block_bases = tuple(sorted(set(s.sdcch_dl + s.sacch_dl + s.other_dl)))
    def ul_base(s, ss):
        """Base fn%51 du bloc MONTANT de la sous-voie `ss`."""
        return (s.sdcch_dl[ss % s.n_sub] + UL_OFFSET51) % 51

# TS0 combine (combinaison V) : FCCH/SCH aux 0,10,20,30,40 / 1,11,21,31,41,
# BCCH 2, CCCH 6,12,16, SDCCH/4 22,26,32,36, SACCH/C4 42,46, idle 50.
PLAN_SD4 = SlotPlan("CCCH+SDCCH4", (22, 26, 32, 36), (42, 46), (2, 6, 12, 16))
# SDCCH/8 non combine (combinaison VII) : 8 blocs dedies a ss*4, SACCH/C8 a
# 32,36,40,44 (sous-voies 0..3 ; 4..7 sur l'autre moitie de la 102-multitrame),
# 48-50 idle. AUCUN BCCH/CCCH : ce slot ne porte pas de canal commun.
PLAN_SD8 = SlotPlan("SDCCH8", (0, 4, 8, 12, 16, 20, 24, 28), (32, 36, 40, 44), ())

def plan_for(phys):
    """Plan du slot d'apres son phys_chan_config, ou None s'il n'en porte pas."""
    if phys.startswith("SDCCH8"):
        return PLAN_SD8
    if phys.startswith("CCCH"):
        return PLAN_SD4
    return None

def _block_key(tn, phys, fn):
    """Identifie le bloc de 4 bursts auquel `fn` appartient.
    Retourne (tn, fn_du_1er_burst) ou None si `fn` n'est pas dans un bloc
    (FCCH, SCH, idle) — ces bursts ne vont PAS dans xcch."""
    plan = plan_for(phys)
    if plan is None:
        return None
    m51 = fn % 51
    for b in plan.block_bases:
        if b <= m51 <= b + 3:
            return (tn, fn - (m51 - b))     # clé = FN du 1er burst du bloc
    return None

# Sentinelle : « ce slot ne porte AUCUN dedie a nous, et on le SAIT ».
# Distincte de None, qui veut dire « on ne sait pas, on traite tout ».
_DCCH_AUCUN = object()

def _dcch_active_ss(tn, plan):
    """Sous-voie qui NOUS appartient sur ce slot.

    Trois reponses, et la troisieme manquait :
      ss          -> c'est notre sous-voie sur ce slot, ne decoder qu'elle
      None        -> on NE SAIT PAS (dcch_cfg pas encore lu) : on traite tout,
                     comme avant. Une porte ne se ferme pas sur une ignorance.
      _DCCH_AUCUN -> on SAIT que le dedie est ailleurs : ce slot n'a aucun bloc
                     dedie qui nous concerne.

    POURQUOI LA TROISIEME. Un banc porte les DEUX combinaisons a la fois : TS0
    en SDCCH/4 combine (avec BCCH et CCCH) et TS1 en SDCCH/8. Le dedie n'est que
    sur l'un des deux. Sans cette reponse, le slot qui ne le porte pas retombait
    sur None - « traite tout » - et le pont decodait les huit sous-voies vides
    de l'autre plan. Mesure sur ce banc : 906 blocs sur 960 traces portaient sur
    les bases 26/36/46 du SDCCH/4 de TS0, ou personne n'est jamais venu. Toutes
    echouaient au CRC, par construction.
    Deux consequences, et la seconde compte :
      - crc_fail ne voulait plus rien dire : 65 % d'echec annonces, dont ~94 %
        de blocs vides. On cherchait une panne radio dans un compteur de bruit.
      - c'etait du xcch_decode_4 pur (4 x 116 iterations) paye ~40 fois par
        seconde pour rien, sur le meme thread qui doit tenir le relais de bursts
        a l'heure. Le temps rendu ici va au temps reel."""
    kind, ss, dtn = _dcch_cfg()
    # Repli (dcch_cfg absent ou tronque) : (0,0,0) est indiscernable d'un vrai
    # SDCCH/4 SS0 TS0. On ne conclut rien.
    if not _dcch_ok:
        return None
    if dtn != tn:
        return _DCCH_AUCUN
    if (PLAN_SD8 if kind else PLAN_SD4) is not plan:
        # Le firmware designe bien ce slot, mais avec l'AUTRE combinaison. Le
        # plan physique et l'avis du firmware se contredisent : on ne tranche
        # pas, on traite tout - et l'ecart se verra dans les compteurs.
        return None
    return ss % plan.n_sub

# ── LE DUMMY BURST : NE PAS LE COMPTER COMME UN ECHEC ───────────────────────
# osmo-bts-trx remplit TOUS les timeslots de C0 avec le dummy burst
# (src/osmo-bts-trx/scheduler_trx.c:198 « Initialize all timeslots on C0/TRX0
# with dummy burst »), pour que la porteuse balise garde une puissance
# constante. Un slot dedie INACTIF emet donc en permanence ce motif fige de la
# TS 05.02 5.2.6 -- qui ne porte aucune donnee et ne peut, par construction,
# passer aucun CRC.
#
# On les envoyait quand meme dans xcch_decode_4, et chaque bloc comptait comme
# un crc_fail. Mesure : notre SDCCH TS1/0 affichait 161 decodages sur 676
# tentatives, soit 76 pour cent d'echec -- alors que les 515 blocs manquants
# n'etaient pas des blocs, c'etait du remplissage. Le compteur accusait la
# radio pour un silence normatif, et gr-gsm a d'ailleurs un bloc entier pour ca
# (dummy_burst_filter).
#
# La sequence est REPRISE de la source d'osmo-bts, pas retapee : deux copies
# d'une constante de 148 bits finissent toujours par diverger sur un chiffre.
# Tolerance : le motif arrive tel quel du TRXD (bits durs), donc une egalite
# stricte suffirait ; on laisse quelques bits d'ecart pour rester juste si un
# jour la source devient bruitee.
_DUMMY_BURST = (0,0,0,1,1,1,1,1,0,1,1,0,1,1,1,0,1,1,0,0,0,0,0,1,0,1,0,0,1,0,0,1,1,1,0,0,0,0,0,1,0,0,1,0,0,0,1,0,0,0,0,0,0,0,1,1,1,1,1,0,0,0,1,1,1,0,0,0,1,0,1,1,1,0,0,0,1,0,1,1,1,0,0,0,1,0,1,0,1,1,1,0,1,0,0,1,0,1,0,0,0,1,1,0,0,1,1,0,0,1,1,1,0,0,1,1,1,1,0,1,0,0,1,1,1,1,1,0,0,0,1,0,0,1,0,1,1,1,1,1,0,1,0,1,0,0,0,0)
_DUMMY_TOL = int(os.environ.get("PONT_DUMMY_TOL", "8"))

def _is_dummy(burst148):
    """Vrai si ce burst est le dummy burst normatif (remplissage de C0)."""
    if len(burst148) < 148:
        return False
    n = 0
    for i in range(148):
        # burst148 : 0x01 = bit 1, tout le reste = bit 0 (domaine DL brut).
        if (1 if burst148[i] == 0x01 else 0) != _DUMMY_BURST[i]:
            n += 1
            if n > _DUMMY_TOL:
                return False
    return True

def _acc_dl(tn, phys, fn, burst148):
    k = _block_key(tn, phys, fn)
    if k is None:
        return                       # FCCH / SCH / idle : rien à décoder en xcch
    plan   = plan_for(phys)
    base51 = k[1] % 51
    # [2026-08-21] NE DECODER QUE NOTRE SOUS-VOIE.
    # Sans ce filtre, un slot SDCCH/8 fait passer ses 12 bases (8 SDCCH + 4
    # SACCH) dans xcch_decode ET dans a5_apply alors qu'UNE SEULE nous concerne :
    # 204 bursts/s sur les 374 traites, dont ~92 % de vide. Deux consequences,
    # l'une couteuse et l'autre grave :
    #   - le compteur crc_fail est noye par des blocs vides par construction,
    #     donc le taux de decodage ne veut plus rien dire ;
    #   - tout bloc d'une AUTRE sous-voie qui passe le CRC est presente au shunt
    #     comme du dedie et remonte au LAPDm du mobile, qui repond « I frame
    #     response not allowed (state LAPD_STATE_IDLE) ».
    # Le shunt, lui, ne presente QUE la fenetre de la sous-voie active
    # (calypso_dsp_shunt_set_dcch) : le pont s'aligne sur la meme discipline.
    _act = _dcch_active_ss(tn, plan)
    if _act is _DCCH_AUCUN:
        # Le dedie est sur un AUTRE slot : ici, les bases dediees ne portent
        # personne. On ne les decode pas - c'est du calcul certain pour un
        # resultat certain (echec CRC). Le reste du slot (BCCH, CCCH, SACCH
        # commun) continue de passer normalement.
        if base51 in plan.ded_bases:
            ST.n_dl_ded_skip += 1
            return
        _act = None
    if _act is not None:
        if base51 in plan.sdcch_dl and base51 != plan.sdcch_dl[_act]:
            return                   # SDCCH d'un autre abonne
        if base51 in plan.sacch_dl and (k[1] % 102) != plan.sacch_dl102[_act]:
            return                   # SACCH d'une autre sous-voie (cf. 102)
    # Un bloc commence mais jamais fini (changement de canal, burst manquant)
    # resterait indefiniment dans _DL_ACC. Borne dure : au-dela, on repart d'un
    # accumulateur propre plutot que de fuir en silence.
    if len(_DL_ACC) > 64:
        _DL_ACC.clear()
    # A5 : seulement le canal DEDIE. Les bases dependent de la combinaison —
    # sur un SDCCH/8, {22,26,32,36,42,46} designe du VIDE et laissait tout le
    # dedie en clair (donc indecodable des que le reseau chiffre).
    # Remplissage de C0 : rien a decoder, et surtout rien a compter comme echec.
    # Test AVANT l'A5 : le dummy n'est jamais chiffre, et le passer au keystream
    # le rendrait meconnaissable.
    if _is_dummy(burst148):
        ST.n_dl_dummy += 1
        return
    if base51 in plan.ded_bases:
        burst148 = a5_apply(burst148, fn, False)
    d = _DL_ACC.setdefault(k, {"fn0": k[1], "b": []})
    d["b"].append(burst116_from_normal(burst148))
    ST.n_dl_bursts += 1
    if len(d["b"]) == 4:
        l2, rc, ne = xcch_decode_4(d["b"])
        del _DL_ACC[k]
        # [2026-08-21] CLE = (tn, base51), PAS base51 seul. Avec deux slots de
        # signalisation, les bases communes aux deux plans (12, 16, 32, 36)
        # etaient additionnees : la ligne DETAIL affichait « 12:20/40 » en
        # melangeant du CCCH du TS0 et du SDCCH/8 du TS1. Un ratio construit
        # sur deux canaux differents ne veut rien dire.
        st = ST.n_by_base.setdefault((tn, base51), [0, 0])
        # TRACE DEDIE : la seule mesure qui tranche « le keystream est-il bon ? ».
        # Si les decodages s'ARRETENT pile quand A5=oui, le keystream est faux —
        # et on a le FN exact pour calculer l'ecart au lieu de balayer FN_ADJ.
        # MESURE DECISIVE : seulement la sous-voie ACTIVE (les autres sont vides
        # par construction et noieraient le signal). Sans plafond : c'est un
        # RATIO, il doit etre exact.
        if _act is not None and base51 == plan.sdcch_dl[_act]:
            tgt = ST.n_act_ciph if _a5_last["applied"] else ST.n_act_clear
            tgt[1] += 1
            if l2 is not None:
                tgt[0] += 1
        if base51 in plan.ded_bases:
            global _ded_n
            _ded_n += 1
            if _ded_n <= 60 or (_ded_n % 20) == 0:
                ST.log("DEDIE-TRACE base=%d fn=%u fn%%51=%u A5=%s%s decode=%s"
                       % (base51, k[1], k[1] % 51,
                          "OUI" if _a5_last["applied"] else "non",
                          ("(a5/%d kc=%s)" % (_a5_last["algo"], _a5_last["kc4"]))
                          if _a5_last["applied"] else "",
                          "OUI" if l2 is not None else "NON"))
        if l2 is None:
            ST.n_dl_crc_fail += 1
            st[1] += 1
            return
        st[0] += 1
        ST.n_dl_decoded += 1
        # ROUTAGE PAR CONTENU (comme si_bridge.py:145-155), pas par FN : le shunt
        # dispatche sur le sub_type GSMTAP. Un SI3 annonce en AGCH n'est jamais
        # traite comme un SI -> "No sysinfo yet" cote mobile.
        # L2 = trame LAPDm : [0]addr [1]ctrl [2]len puis L3 -> [3]=PD(0x06=RR)
        # [4]=type. (Repli sur by[1]/by[2] si le bloc est deja deshabille.)
        if base51 in plan.sdcch_dl:
            # CANAL DEDIE descendant (SDCCH/4 SS0..3 ou SDCCH/8 SS0..7) : LAPDm
            # pur (UA, AUTH REQ,
            # LU ACCEPT, ...). NE PAS filtrer par type RR — ce n'est pas du RR.
            # C'etait LE trou : tout le DL dedie etait jete, donc l'UA n'arrivait
            # jamais au mobile -> il repetait sa SABM -> "SABM not allowed in
            # this state" cote BTS alors que le lchan etait ESTABLISHED.
            # ⚠️ SOUS-TYPE : on garde 0x07 (SDCCH4) meme pour un SDCCH/8. Ce
            # champ n'est PAS une description du canal, c'est le selecteur de
            # dispatch du shunt (calypso_dsp_shunt.c:3212) : sa liste blanche
            # ne connait que 0x07/0x87/TCH, et 0x08 = GSMTAP_CHANNEL_SDCCH8 y
            # serait JETE en silence — le miroir exact du bug FACCH 0x08/0x09
            # corrige le 12/08. La combinaison reelle, elle, est portee par
            # set_dcch(kind, ss) que le firmware publie depuis son chan_nr.
            feed_dl_l2(d["fn0"], GSMTAP_SDCCH4, l2, PORT_GSMTAP)
            check_assignment(l2, d["fn0"])     # arme le TCH si c'est un ASSIGNMENT
            # Le CHANNEL RELEASE d'un appel avorte AVANT la bascule arrive ici,
            # sur le SDCCH : sans ce desarmement, le TCH arme par l'ASSIGNMENT
            # COMMAND resterait arme jusqu'a la prochaine assignation.
            if est_channel_release(l2):
                tch_desarme("CHANNEL RELEASE descendant sur le SDCCH")
                kc_lacher("CHANNEL RELEASE (SDCCH)")
            return
        if base51 in plan.sacch_dl:
            feed_dl_l2(d["fn0"], GSMTAP_SACCH, l2, PORT_GSMTAP)   # SACCH dediee
            return
        # BCCH / CCCH : routage PAR CONTENU (le shunt dispatche sur le sub_type).
        # [audit M2] Format pseudo-longueur BCCH/CCCH (PL@0 PD@1 MT@2) : on teste
        # l2[1] AVANT l2[3], sinon un octet de corps L3 valant 0x06 en l2[3]
        # faisait lire un faux MT et jetait SI/paging en silence (~1/256).
        mt = None
        if len(l2) >= 3 and l2[1] == 0x06:   mt = l2[2]
        elif len(l2) >= 5 and l2[3] == 0x06: mt = l2[4]
        if mt is None:
            return
        # ── LE SEUL OCTROI D'UN CANAL NEUF ──────────────────────────────────
        # IMMEDIATE ASSIGNMENT (0x3f) et sa forme etendue (0x39) donnent un
        # canal dedie NEUF, qui demarre toujours en clair. C'est LA le moment
        # ou une cle retenue cesse d'etre valable -- pas a chaque SABM.
        # 0x3a (REJECT) n'octroie rien : on ne lache pas.
        if mt in (0x3f, 0x39):
            kc_lacher("IMMEDIATE ASSIGNMENT descendant")
        if mt in SI_TYPES:
            chan = GSMTAP_BCCH                # SI1/2/3/4/2bis/2ter -> feed_si
        elif mt in CCCH_TYPES:
            chan = GSMTAP_CCCH                # IMM-ASSIGN / PAGING -> feed_agch
        else:
            return
        feed_dl_l2(d["fn0"], chan, l2, PORT_GSMTAP)

# =========================== UL : sidebands -> TRXD (POINT 3) ==================
# ============================ CAPTURE (A et B) ================================
# A — PONT_BURST_FILE : dump des bursts. Si `pmt` est importable (interpreteur
#     /root/.env/bin/python3), on ecrit le VRAI format gr-gsm (pmt serialise,
#     lisible par `grgsm_decode -b`). Sinon, dump brut auto-decrit :
#     [magic 'PBST'][fn u32 LE][tn u8][len u8][bits...] par burst — honnete, pas
#     compatible gr-gsm, mais rejouable par le pont.
# B — PONT_CFILE : vrai cfile IQ complex float32 en MODULANT les bursts (l'etage
#     GMSK que l'architecture burst-level supprime). L'IQ est donc RECONSTRUITE
#     (fidele aux bits, sans bruit ni ToA reelle) — ce n'est pas une capture d'air.
BURST_FILE = os.environ.get("PONT_BURST_FILE", "")
CFILE      = os.environ.get("PONT_CFILE", "")
CFILE_OSR  = int(os.environ.get("PONT_CFILE_OSR", "4"))

# ------------------------------- AIRREC : cfile DL permanent -----------------
# Enregistrement PERMANENT du DESCENDANT, en temps TDMA reel, dans un cfile fc32
# a 1 083 333 sps — exactement ce que `grgsm_decode -s 1083333` attend et ce que
# rec.js code en dur (SAMP).
#
# POURQUOI PAS capture_iq(), QUI EXISTE DEJA. Deux defauts redhibitoires :
#   1. UN SEUL APPELANT, send_trxd_ul() : capture_iq ne voit que le MONTANT. Le
#      descendant — celui que `-m BCCH_SDCCH4` decode — n'etait ecrit NULLE PART.
#   2. IL COMPRIME LE TEMPS. Il concatene 148 symboles par burst, dos a dos, or
#      un slot GSM dure 156,25 symboles. En supprimant les 8,25 symboles de garde
#      on raccourcit le fichier de 5,3 % : la recuperation d'horloge de gr-gsm ne
#      raccroche jamais. Le fichier s'ouvre, se lit comme un fc32 valide, et ne
#      decode RIEN — sans une seule erreur.
#
# ON ECRIT DONC UNE TRAME ENTIERE (8 slots x 156,25 = 1250 symboles) A CHAQUE
# PERIODE TDMA, Y COMPRIS QUAND LA BTS N'EMET RIEN. Le silence FAIT PARTIE du
# signal : c'est lui qui porte le temps. C'est ce qui rend le fichier decodable,
# et c'est ce qui en fixe le debit :
#     1250 x OSR 4 x 8 o x 216,68 trames/s = 8,67 Mo/s = 31 Go/h.
# CE DEBIT N'EST PAS NEGOCIABLE — c'est ce que « enregistrer l'air a 1083333 sps »
# veut dire. Sans plafond, /dev/shm (8 Go, QUI PORTE LES JOURNAUX) est plein en
# 13 minutes. D'ou la rotation par segments, non optionnelle.
#
# @BEQUILLE — CE N'EST PAS UNE CAPTURE D'AIR. Cette I/Q est RECONSTRUITE a partir
#   des bits que la BTS a emis : pas de bruit, pas de ToA reelle, pas de derive de
#   frequence, pas de fading, pas d'interference. Decoder ce cfile rend donc
#   exactement les bits dont il est issu — c'est un rejeu fidele aux BITS, utile
#   pour rejouer/demontrer, PAS une preuve de ce qui est passe sur l'air.
#   masque : en mode pont il n'existe aucune chaine IQ reelle a capturer.
#   retirer : le jour ou une vraie source RF alimente le chemin.
# [2026-08-27] DEFAUT PASSE A 0. L'enregistrement d'air coute 148 iterations
# Python PAR BURST (~250 000/s) rien que pour fabriquer sa vue en bits, et il se
# coupait de toute facon tout seul faute d'espace disque (« airrec descendant :
# moins de 1024 Mo libres — COUPE ») -- on payait donc le calcul sans rien
# enregistrer.
#
# [2026-08-29] DEFAUT REMIS A 1, ET LA RAISON DE 0 N'EXISTE PLUS.
# Ce basculement a coute deux fonctions d'un coup, sans que rien ne relie la
# cause a l'effet :
#   - /root/record.cfile ne s'ecrivait plus. Le service web sait DECOUPER des
#     tranches dedans (rec.js) mais pas le creer : « Capture IQ : absent,
#     AIRREC est coupe » a chaque essai.
#   - le montant /tmp/iq_fft_ms.fifo n'avait plus de producteur : la pane
#     « MS » du dashboard restait vide, et il ne restait qu'UN spectre sur les
#     deux.
# Or l'argument de 27/08 - « il se coupait tout seul faute d'espace » - visait
# un etat corrige la VEILLE : le 26/08, AIRREC_MAX est passe de 16 Gio a 512 Mo
# et l'ecriture est devenue un BUFFER ROULANT (on tronque et on recommence).
# Le disque ne peut donc plus se remplir, et la coupure qui justifiait le
# defaut a 0 ne peut plus se produire. Reste le cout CPU, reel et assume : il
# achete l'enregistrement et le spectre montant. PONT_AIRREC=0 pour l'eteindre.
AIRREC      = os.environ.get("PONT_AIRREC", "1") not in ("0", "", "no")
# [2026-08-16] SUR DISQUE, PLUS EN RAM. /dev/shm ne fait que 8 Go et porte
# AUSSI les journaux du run : a 17,3 Mo/s (descendant + montant) il etait
# plein en ~6 minutes, ce qui imposait un decoupage en segments. L'overlay
# du conteneur offre 295 Go libres : on peut donc ecrire UN SEUL FICHIER
# CONTINU par run et par sens, ce qui est la seule forme directement
# decodable — un cfile decoupe oblige a concatener avant toute analyse.
AIRREC_DIR  = os.environ.get("PONT_AIRREC_DIR", "/root/osmo-rec")
AIRREC_OSR  = int(os.environ.get("PONT_AIRREC_OSR", "4"))            # 4 -> 1083333 sps
# PLAFOND DUR, par sens. Atteint, on ARRETE d'ecrire — on ne fait PAS
# tourner : le fichier reste entier et decodable.
# [2026-08-26] PLAFOND RAMENE DE 16384 A 512 Mo. 16 Gio par sens, c'etait plus
# que la RAM totale de la machine (10,4 Go) et la racine de la VM est en RAM :
# le plafond ne pouvait donc JAMAIS etre atteint avant que le systeme de
# fichiers soit plein. Il l'a ete — racine a 100 %, 4,6 Go, 2,46 Go par cfile —
# et le banc est tombe avec. 512 Mo = ~1 min a 8,67 Mo/s, ce qui tient dans ce
# que la machine peut reellement offrir.
AIRREC_MAX  = int(os.environ.get("PONT_AIRREC_MAX_MB",   "512")) * 1024 * 1024
# Alerte (sans effacer) quand le repertoire depasse ce total : plusieurs runs
# s'y accumulent, et supprimer les captures de l'operateur sans le lui dire
# serait pire que de le prevenir.
AIRREC_DIRMAX = int(os.environ.get("PONT_AIRREC_DIR_MAX_MB", "65536")) * 1024 * 1024
AIRREC_KEEP = int(os.environ.get("PONT_AIRREC_KEEP",         "6"))
# MONTANT. Meme debit que le descendant (8,67 Mo/s) : on ecrit la trame
# entiere, silence compris, parce que c'est le silence qui porte le temps.
# On en garde MOINS par defaut (3 segments = 768 Mio, ~1,5 min) : le montant
# est epars, on le consulte sur une fenetre courte, et /dev/shm porte aussi
# les journaux. PONT_AIRREC_UL=0 coupe le montant sans toucher au descendant.
# [2026-08-16] DEFAUT PASSE A 0. Le cfile montant n'a PAS de consommateur :
# aucun outil ne sait demoduler un enregistrement montant (grgsm_decode se
# cale sur FCCH/SCH, qui n'existent qu'en descendant, et aucun de ses
# demappeurs n'est montant). Il coutait donc 8,67 Mo/s pour un fichier que
# personne ne peut lire. Le montant est desormais observable par le TAP
# GSMTAP, en L2 deja decodee — ce qui est ce qu'on voulait en voir.
# =1 pour le reactiver (rejeu par un outil maison, analyse de forme d'onde).
AIRREC_UL   = os.environ.get("PONT_AIRREC_UL", "1") not in ("0", "", "no")
# SORTIES, SYMETRIQUES ENTRE LES DEUX SENS. Le service web (server.js FFT_SRC)
# connait deux puits de longue date :
#   ms  -> /dev/shm/dsp_iq.cfile   pane « MS — Calypso DSP »
#   bts -> /tmp/iq_fft.fifo        pane « BTS — DL relay LIVE »
# Leur producteur etait calypso-ipc-device, que le mode pont saute : les deux
# panes etaient donc VIDES. On les realimente, sens pour sens.
#   FIFO  = vue live (best-effort, jamais bloquante)
#   CFILE = enregistrement continu sur DISQUE, decoupable par offsets
#   MIROIR= copie bornee en RAM, uniquement pour la pane qui lit un cfile
# Une chaine VIDE coupe la sortie correspondante.
AIRREC_DL_PATH   = os.environ.get("PONT_AIRREC_DL_PATH",   "/root/record.cfile")
AIRREC_DL_FIFO   = os.environ.get("PONT_AIRREC_DL_FIFO",   "/tmp/iq_fft.fifo")
AIRREC_UL_PATH   = os.environ.get("PONT_AIRREC_UL_PATH",   "/root/record_ul.cfile")
AIRREC_UL_FIFO   = os.environ.get("PONT_AIRREC_UL_FIFO",   "/tmp/iq_fft_ms.fifo")
# ⚠️ SEULE ASYMETRIE, et elle est imposee : la pane « MS » lit un CFILE et non
# une fifo, sur /dev/shm (8 Go, qui porte AUSSI les journaux). A 8,67 Mo/s un
# fichier qui grossit y tient 15 minutes. Ce miroir REBOUCLE donc — la pane n'en
# lit que la queue, elle ne voit qu'un hoquet. Le cfile DISQUE ci-dessus, lui,
# ne reboucle jamais : c'est celui qu'on decoupe (un rebouclage casserait les
# offsets du Record).
# [2026-08-16] MIROIR RAM DESACTIVE PAR DEFAUT. Il servait a nourrir la pane
# « MS » du web, qui lisait un CFILE. Mais un fichier qui REBOUCLE casse le
# lecteur de queue du web (statSync().size s'effondre a chaque tour -> pane
# vide toutes les ~29 s). La pane lit desormais la FIFO /tmp/iq_fft_ms.fifo,
# qui est le bon objet pour un flux continu. Ce miroir n'a donc plus d'usage
# et il consommait 8,67 Mo/s de RAM. Remettre un chemin pour le reactiver.
AIRREC_UL_MIROIR = os.environ.get("PONT_AIRREC_UL_MIROIR", "")
AIRREC_WRAP_MB   = int(os.environ.get("PONT_AIRREC_WRAP_MB", "256"))
AIRREC_UL_KEEP = int(os.environ.get("PONT_AIRREC_UL_KEEP", "3"))
AIRREC_FREE = int(os.environ.get("PONT_AIRREC_MINFREE_MB", "1024")) * 1024 * 1024

_pmt = None
if BURST_FILE:
    try:
        import pmt as _pmt
    except ImportError:
        _pmt = None
_bf = open(BURST_FILE, "ab") if BURST_FILE else None
_cf = None
_np = None
if CFILE:
    try:
        import numpy as _np
        _cf = open(CFILE, "ab")
    except ImportError:
        print("[pont] PONT_CFILE demande mais numpy absent -> pas de cfile", flush=True)

_CAPTURE_MAX = int(os.environ.get("PONT_CAPTURE_MAX_MB", "512")) * 1048576   # 0 = illimite

def capture_burst(fn, tn, bits148, uplink):
    """A : ecrit le burst dans le dump si le gate est pose."""
    if _bf is None:
        return
    b = bytes(1 if x == 0x01 else 0 for x in bits148)
    if _pmt is not None:
        hdr = gsmtap(fn, GSMTAP_SDCCH4, b"")            # en-tete GSMTAP 16 o
        msg = _pmt.cons(_pmt.PMT_NIL,
                        _pmt.init_u8vector(len(hdr) + len(b), list(hdr + b)))
        _bf.write(_pmt.serialize_str(msg))
    else:
        _bf.write(b"PBST" + struct.pack("<IBB", fn, tn, len(b)) + b)
    _bf.flush()
    # [audit m5] Plafond roulant (etait sans borne, pouvait remplir le volume).
    if _CAPTURE_MAX and os.fstat(_bf.fileno()).st_size >= _CAPTURE_MAX:
        _bf.seek(0); _bf.truncate(0)

def capture_iq(bits148):
    """B : module le burst en GMSK et l'ajoute au cfile (complex float32)."""
    if _cf is None or _np is None:
        return
    # ⚠️ CE MODULATEUR EST LE JUMEAU DE _ar_mod. Il portait LES TROIS defauts
    # corriges le 16/08 (polarite, indice x4 trop faible, differentiel absent).
    # Il n'a qu'un appelant (send_trxd_ul) et ne s'arme que si PONT_CFILE est
    # defini, donc il dormait — mais un jumeau casse est le prochain piege. Il
    # est desormais aligne sur _ar_mod : toute correction va aux DEUX.
    b   = (_np.frombuffer(bytes(bits148), dtype=_np.uint8) == 0x01).astype(_np.float64)
    nrz = 2.0 * b - 1.0
    prv = _np.empty_like(nrz)
    prv[0] = nrz[0]
    prv[1:] = nrz[:-1]
    a   = nrz * prv
    up = _np.zeros(len(a) * CFILE_OSR); up[::CFILE_OSR] = a
    n = 4 * CFILE_OSR
    t = (_np.arange(-n, n + 1)) / float(CFILE_OSR)
    g = _np.exp(-2.0 * (_np.pi ** 2) * (0.3 ** 2) * t ** 2 / _np.log(2.0))
    g /= g.sum()
    phase = _np.cumsum(_np.convolve(up, g, mode="same")) * (_np.pi / 2.0)
    _np.exp(1j * phase).astype(_np.complex64).tofile(_cf)
    _cf.flush()
    # [audit m5] Plafond roulant, comme AIRREC (etait sans borne).
    if _CAPTURE_MAX and os.fstat(_cf.fileno()).st_size >= _CAPTURE_MAX:
        _cf.seek(0); _cf.truncate(0)

# ============ AIRREC : enregistrement permanent, descendant ET montant =======
# UNE classe, DEUX instances. Le descendant et le montant partagent exactement la
# meme discipline ; les separer en deux jeux de fonctions, c'est ce qui avait
# produit le bug des anneaux TCH (slot 48 d'un cote, 64 de l'autre, lecture au
# mauvais pas). On ne recommence pas.
#
# UN SEUL THREAD ecrit les deux fichiers, cadence par la meme horloge : a une FN
# donnee correspond donc le MEME offset dans les deux cfile. Les deux captures
# sont alignees a l'echantillon pres et se correlent directement.
_ar_g = None                        # gabarit gaussien, calcule UNE fois

def _ar_mod(bits148, osr):
    """148 bits -> 148*osr echantillons complex64 (GMSK BT=0.3)."""
    # [2026-08-16] DEUX DEFAUTS CORRIGES, l'un et l'autre MESURES.
    #
    # JUGE : le FCCH est un burst de 148 bits a ZERO ; en GMSK il doit produire
    # une tonalite PURE a +1625/24 kHz = +67708 Hz, soit +0,3927 rad/echantillon
    # a 1083333 sps. C'est ce ton que gr-gsm cherche pour se caler. Mesure sur un
    # enregistrement de reference qui se decode : une plage de 592 echantillons
    # (= 148 symboles x OSR 4) a +67708 Hz. Mesure sur la sortie d'AIRREC AVANT
    # ce correctif : ZERO echantillon a +67708 Hz, zero a -67708 Hz. Aucun FCCH,
    # donc aucun calage possible, donc zero ligne decodee quoi qu'on tente.
    #
    # 1. INDICE DE MODULATION x4 TROP FAIBLE. `cumsum` avance deja de 1 par
    #    SYMBOLE (g est normalise a somme 1, un impulsion par symbole), donc
    #    multiplier par pi/2/osr donnait pi/(2*osr) par symbole au lieu de pi/2.
    #    Mesure : -16926 Hz au lieu de -67708. Le `/ osr` saute.
    # 2. POLARITE INVERSEE. GSM 05.04 : alpha = 1 - 2*d, donc bit 0 -> +1 et
    #    bit 1 -> -1. Le code faisait l'inverse, ce qui plarait le FCCH a
    #    -67708 Hz au lieu de +67708.
    # Les deux ensemble : +67703 Hz mesures, la cible.
    #
    # 3. ENCODAGE DIFFERENTIEL ABSENT — TRANCHE PAR LA MESURE le 16/08, c'etait
    #    le DERNIER defaut. Il est SANS EFFET sur le FCCH (tout a zero reste tout
    #    a zero) : c'est precisement pour ca qu'on pouvait avoir une tonalite
    #    FCCH parfaite a +67708 Hz, une cadence de trames exacte, et malgre tout
    #    ZERO rafale en sortie de grgsm_decode, meme avec -p.
    #    L'ORACLE est le source de gr-gsm, lib/receiver/receiver_impl.cc:860,
    #    fonction gmsk_mapper() qui fabrique la reference de correlation :
    #        previous_symbol = 2*input[0] - 1;
    #        current_symbol  = 2*input[i] - 1;
    #        encoded_symbol  = current_symbol * previous_symbol;  /* differentiel */
    #        gmsk_output[i]  = j * encoded_symbol * gmsk_output[i-1];
    #    Le recepteur correle donc contre une sequence d'apprentissage ELLE-MEME
    #    encodee differentiellement. Sans differentiel a l'emission, la TSC ne
    #    correle jamais, aucun burst n'est detecte, et rien ne sort.
    #    MESURE : sur la tranche du 16/08 15h42, TSC du SCH = 1.000 en supposant
    #    "pas de differentiel" et 0.453 en supposant "differentiel" -> le pont
    #    emettait bien alpha = 1-2b. Apres re-encodage hors ligne de cette meme
    #    tranche avec la regle ci-dessous : 211 lignes decodees (SI1/2/3/4 et
    #    Paging Request Type 1). Rien d'autre n'a ete touche.
    #    NOTE polarite : gr-gsm mappe bit 0 -> -1 (2b-1), soit l'INVERSE de la
    #    lettre de 05.04 (1-2d). Sans importance : le produit nrz(i)*nrz(i-1) est
    #    insensible a un changement global de signe. On garde la convention de
    #    gr-gsm parce que c'est lui qui decode.
    b   = (_np.frombuffer(bytes(bits148), dtype=_np.uint8) == 0x01).astype(_np.float64)
    nrz = 2.0 * b - 1.0                 # NRZ facon gr-gsm : bit 0 -> -1
    prv = _np.empty_like(nrz)
    prv[0]  = nrz[0]                    # gr-gsm initialise previous = input[0]
    prv[1:] = nrz[:-1]
    a   = nrz * prv                     # alpha = nrz(i) * nrz(i-1)
    up = _np.zeros(len(a) * osr)
    up[::osr] = a
    ph = _np.cumsum(_np.convolve(up, _ar_g, mode="same")) * (_np.pi / 2.0)
    return _np.exp(1j * ph).astype(_np.complex64)

class _AirRec:
    """Un sens d'enregistrement : sa file de trames, ses segments, son etat."""
    def __init__(s, sens, prefixe, keep, fixe="", fifo="", miroir="", wrap_mb=0):
        s.sens    = sens            # "descendant" / "montant", pour les messages
        s.prefixe = prefixe         # air_pont_ / air_pont_ul_
        s.keep    = keep
        s.lock    = threading.Lock()
        s.frames  = {}              # fn -> {tn: bits148}
        s.fh = None; s.path = None; s.bytes = 0
        s.split = False; s.off = False
        s.n_frames = 0; s.n_bursts = 0; s.n_segs = 0
        s.fixe      = fixe          # chemin impose ; vide -> nom horodate
        s.fifo_path = fifo          # vue live
        s.fifo_fd   = None
        s.fifo_next = 0
        s.mir_path  = miroir        # copie bornee en RAM
        s.mir_fh    = None
        s.mir_bytes = 0
        s.wrap      = wrap_mb * 1024 * 1024
        s.n_fifo = 0; s.n_fifo_drop = 0

    def feed(s, fn, tn, bits148):
        """Depot SEUL, aucun calcul : on est sur le chemin temps reel du pont.
        Toute la modulation se fait dans le thread ecrivain."""
        if s.off:
            return
        with s.lock:
            s.frames.setdefault(fn, {})[tn] = bits148

    def _alerte_volume(s):
        """On N'EFFACE PLUS RIEN. L'ancienne version purgeait les vieux segments
        pour tenir dans le tmpfs ; sur disque il n'y a plus de raison de detruire
        les captures de l'operateur sans le lui demander. On se contente de
        l'avertir quand le repertoire enfle."""
        total = 0
        try:
            for f in os.listdir(AIRREC_DIR):
                if f.endswith(".cfile"):
                    try: total += os.path.getsize(os.path.join(AIRREC_DIR, f))
                    except OSError: pass
        except OSError:
            return
        if total > AIRREC_DIRMAX:
            ST.log("airrec ⚠️ %s contient %.1f Go de captures (seuil %.1f Go) — "
                   "rien n'est efface automatiquement, faites le menage"
                   % (AIRREC_DIR, total / 1e9, AIRREC_DIRMAX / 1e9))

    def _espace_ok(s):
        """Espace libre restant sur le volume qui porte le cfile. Rend True quand
        la mesure echoue : couper une capture sur un statvfs en erreur serait pire
        que la laisser sous la seule surveillance du plafond."""
        try:
            st = os.statvfs(os.path.dirname(s.path or s.fixe or "") or AIRREC_DIR)
        except OSError:
            return True
        return st.f_bavail * st.f_frsize >= AIRREC_FREE

    def rotate(s):
        """Ouvre LE fichier du run (un seul, continu). Conserve son nom d'origine
        parce que SIGUSR1 permet encore d'en forcer un neuf a la main."""
        if s.fh is not None:
            try:    s.fh.close()
            except OSError: pass
            s.fh = None
            ST.log("airrec %s fichier clos : %s (%.1f Mo)"
                   % (s.sens, s.path, s.bytes / 1048576.0))
        try:
            os.makedirs(AIRREC_DIR, exist_ok=True)
        except OSError as e:
            ST.log("airrec %s: %s inaccessible (%s) — COUPE" % (s.sens, AIRREC_DIR, e))
            return False
        # GARDE TMPFS. /dev/shm porte AUSSI les journaux du run : on s'arrete
        # AVANT de le remplir. Un enregistrement qui tue la machine qu'il observe
        # n'a aucune valeur, et la panne se manifesterait dix modules plus loin.
        try:
            st = os.statvfs(os.path.dirname(s.fixe or "") or AIRREC_DIR)
            if st.f_bavail * st.f_frsize < AIRREC_FREE:
                ST.log("airrec %s: moins de %d Mo libres sur %s — COUPE"
                       % (s.sens, AIRREC_FREE // 1048576, AIRREC_DIR))
                return False
        except OSError:
            pass
        s._alerte_volume()
        if s.fixe:
            try:
                os.makedirs(os.path.dirname(s.fixe) or ".", exist_ok=True)
            except OSError:
                pass
        if s.mir_path and s.mir_fh is None:
            try:
                s.mir_fh = open(s.mir_path, "wb", buffering=1024 * 1024)
                ST.log("airrec %s miroir -> %s (reboucle a %d Mo, pane FFT)"
                       % (s.sens, s.mir_path, s.wrap // 1048576))
            except OSError as e:
                ST.log("airrec %s miroir %s indisponible (%s)" % (s.sens, s.mir_path, e))
        s.path = s.fixe or os.path.join(
            AIRREC_DIR, "%s%s.cfile"
            % (s.prefixe, time.strftime("%Y%m%d%H%M%S", time.gmtime())))
        try:
            s.fh = open(s.path, "wb", buffering=1024 * 1024)
        except OSError as e:
            ST.log("airrec %s: ouverture %s impossible (%s)" % (s.sens, s.path, e))
            return False
        s.bytes = 0
        s.n_segs += 1
        ST.log("airrec %s -> %s (fichier UNIQUE et CONTINU pour tout le run ; "
               "plafond %d Mo)" % (s.sens, s.path, AIRREC_MAX // 1048576))
        return True

    def _sorties_annexes(s, octets):
        """FIFO + miroir. BEST-EFFORT ABSOLU : une vue est un agrement, elle ne
        doit jamais pouvoir figer l'enregistrement.
        - O_NONBLOCK a l'ouverture : sans lecteur, open() rend ENXIO au lieu de
          BLOQUER indefiniment. C'est LE piege des fifo, et il aurait gele le
          thread d'ecriture des la premiere trame.
        - EAGAIN a l'ecriture = lecteur trop lent -> on JETTE, on compte.
        - EPIPE (lecteur parti) -> on referme, on rouvrira plus tard."""
        if s.fifo_path:
            if s.fifo_fd is None and s.n_frames >= s.fifo_next:
                s.fifo_next = s.n_frames + 217          # nouvelle tentative ~1 s
                if not os.path.exists(s.fifo_path):
                    # Le noeud doit exister pour qu'un open O_WRONLY reussisse un
                    # jour. On le cree nous-memes : sinon la vue reste morte tant
                    # que personne n'a pense a faire le mkfifo a la main, et rien
                    # ne le signale.
                    try:
                        os.mkfifo(s.fifo_path, 0o644)
                        ST.log("airrec %s : fifo %s creee" % (s.sens, s.fifo_path))
                    except OSError as e:
                        ST.log("airrec %s : mkfifo %s impossible (%s)"
                               % (s.sens, s.fifo_path, e))
                try:
                    s.fifo_fd = os.open(s.fifo_path, os.O_WRONLY | os.O_NONBLOCK)
                    ST.log("airrec %s : fifo %s ouverte — vue live alimentee"
                           % (s.sens, s.fifo_path))
                except OSError:
                    pass
            if s.fifo_fd is not None:
                # [audit m1] os.write sur pipe O_NONBLOCK peut n'ecrire qu'une
                # PARTIE d'une trame (>PIPE_BUF) : l'ancien code ignorait le retour,
                # perdait le reste et decalait DURABLEMENT le flux complex64 du
                # lecteur FFT. On garde le reste (fifo_pending) colle a la trame
                # suivante -> flux jamais rompu ; en cas de retard on lache des
                # TRAMES ENTIERES par l'avant (multiple de len(octets) = de 8 o).
                pend = getattr(s, "fifo_pending", b"")
                data = pend + octets if pend else octets
                maxq = 3 * len(octets)
                if len(data) > maxq:
                    drop = ((len(data) - maxq) // len(octets)) * len(octets)
                    if drop:
                        data = data[drop:]; s.n_fifo_drop += 1
                try:
                    n = os.write(s.fifo_fd, data)
                    s.fifo_pending = data[n:]
                    if n:
                        s.n_fifo += 1
                except BlockingIOError:
                    s.fifo_pending = data
                except OSError:
                    try: os.close(s.fifo_fd)
                    except OSError: pass
                    s.fifo_fd = None; s.fifo_pending = b""
        if s.mir_fh is not None:
            try:
                s.mir_fh.write(octets); s.mir_bytes += len(octets)
                if s.wrap and s.mir_bytes >= s.wrap:
                    s.mir_fh.flush(); s.mir_fh.seek(0); s.mir_fh.truncate(0)
                    s.mir_bytes = 0
            except OSError:
                try: s.mir_fh.close()
                except OSError: pass
                s.mir_fh = None

    def ecrire(s, fn, spf, step, blen, silence):
        """Ecrit UNE trame TDMA. Rend False si l'enregistrement doit s'arreter."""
        if s.off or s.fh is None:
            return True
        with s.lock:
            slots = s.frames.pop(fn, None)
            if len(s.frames) > 512:      # trames jamais reclamees : pas de fuite
                s.frames.clear()
        if slots:
            trame = _np.zeros(spf, dtype=_np.complex64)
            for tn, bits in slots.items():
                o = tn * step
                trame[o:o + blen] = _ar_mod(bits, AIRREC_OSR)
                s.n_bursts += 1
        else:
            trame = silence          # le SILENCE porte le temps : on l'ecrit
        try:
            octets = trame.tobytes()
            s._sorties_annexes(octets)
            s.fh.write(octets)
            s.bytes += trame.nbytes
            s.n_frames += 1
        except OSError as e:
            ST.log("airrec %s ecriture ECHEC (%s) — COUPE" % (s.sens, e))
            s.off = True
            return True
        # GARDE D'ESPACE REJOUEE EN COURS D'ECRITURE. Elle n'existait que dans
        # rotate() : avec un chemin de fichier FIXE, rotate() n'est appelee qu'au
        # demarrage (le seul autre appel, plus bas, est declenche par SIGUSR1),
        # donc plus rien ne la reevaluait ensuite, et les deux cfile ont rempli
        # la racine de la VM a 100 % (4,6 Go) pendant que le pont tournait — le
        # seul plafond en vigueur portait sur la taille du fichier, pas sur ce
        # qui restait sous lui. Toutes les 2000 trames (~9 s, ~80 Mo par sens) :
        # assez souvent pour s'arreter avant le mur, assez rare pour ne rien
        # couter au chemin d'ecriture.
        if s.n_frames % 2000 == 0 and not s._espace_ok():
            ST.log("airrec %s : moins de %d Mo libres sur %s — ARRET de "
                   "l'ecriture, le fichier reste complet et decodable"
                   % (s.sens, AIRREC_FREE // 1048576, s.path))
            try: s.fh.flush()
            except OSError: pass
            s.off = True
            return True
        # PLUS DE ROTATION A LA TAILLE. Au plafond on ARRETE : le fichier reste
        # entier, donc decodable tel quel. Une rotation aurait rendu la capture
        # inexploitable sans concatenation prealable.
        if s.bytes >= AIRREC_MAX:
            # [demande operateur 2026-08-29] Au plafond on NE S'ARRETE PLUS : on RM
            # (tronque a 0) et on RECOMMENCE -> buffer roulant borne a AIRREC_MAX,
            # l'enregistrement ne s'interrompt jamais (symetrique du cfile #2 du
            # shunt). L'ancien ARRET figeait la capture -> REC 0 o au plafond.
            ST.log("airrec %s : plafond %d Mo atteint — ROTATION (rm + redemarrage),"
                   " buffer roulant %s" % (s.sens, AIRREC_MAX // 1048576, s.path))
            try:
                s.fh.flush(); s.fh.seek(0); s.fh.truncate(0)
                s.bytes = 0
            except OSError:
                s.off = True
        elif s.split:                # SIGUSR1 : nouveau fichier, a la demande
            s.split = False
            if not s.rotate():
                s.off = True
        return True

def _ar_est_a_moi(nom, prefixe):
    """`air_pont_` est un prefixe de `air_pont_ul_` : sans ce filtre, la purge du
    DESCENDANT effacerait les segments du MONTANT. Piege de prefixe classique."""
    reste = nom[len(prefixe):-len(".cfile")]
    return reste.isdigit() and len(reste) == 14

_AR_DL = _AirRec("descendant", "air_pont_",    AIRREC_KEEP,
                 AIRREC_DL_PATH, AIRREC_DL_FIFO, "",               0)
_AR_UL = _AirRec("montant",    "air_pont_ul_", AIRREC_UL_KEEP,
                 AIRREC_UL_PATH, AIRREC_UL_FIFO, AIRREC_UL_MIROIR, AIRREC_WRAP_MB)
if not AIRREC_UL:
    _AR_UL.off = True

def airrec_feed(fn, tn, bits148):
    """DESCENDANT — appele depuis th_data_rx."""
    if AIRREC:
        _AR_DL.feed(fn, tn, bits148)

def airrec_feed_ul(fn, tn, bits148):
    """MONTANT — appele depuis send_trxd_ul, APRES le chiffrement A5 : on
    enregistre ce qui part REELLEMENT sur l'air. C'est ce qui rend le couple
    `-p` / `-e -k` significatif du cote montant comme du cote descendant."""
    if AIRREC and AIRREC_UL:
        _AR_UL.feed(fn, tn, bits148)

def _ar_on_usr1(_sig, _frm):
    """SIGUSR1 = « Split » : clot les segments courants pour les figer et en
    rouvre aussitot. Les DEUX sens sont coupes au meme instant, sinon les
    tranches descendante et montante ne couvriraient pas la meme fenetre."""
    _AR_DL.split = True
    _AR_UL.split = True

def th_airrec():
    """Ecrit UNE trame TDMA par periode et par sens, cadence par l'horloge du
    pont (now_fn(), derivee du temps absolu) : c'est ce qui garantit que les
    fichiers ont la bonne DUREE, donc qu'ils sont decodables. On ecrit avec 2
    trames de retard, le temps que les 8 slots d'une meme trame soient arrives —
    ils viennent en 8 datagrammes distincts et rien ne garantit leur ordre."""
    global _ar_g
    if not AIRREC:
        return          # main() ne demarre meme plus ce thread ; annonce faite la-bas
    if _np is None:
        try:
            import numpy as _n2
            globals()["_np"] = _n2
        except ImportError:
            ST.log("airrec demande mais numpy absent -> pas d'enregistrement")
            _AR_DL.off = _AR_UL.off = True
            return
    if AIRREC_OSR % 4 != 0:
        ST.log("airrec: OSR=%d refuse (156,25 x OSR doit etre entier) -> multiple de 4"
               % AIRREC_OSR)
        _AR_DL.off = _AR_UL.off = True
        return
    n = 4 * AIRREC_OSR
    t = (_np.arange(-n, n + 1)) / float(AIRREC_OSR)
    g = _np.exp(-2.0 * (_np.pi ** 2) * (0.3 ** 2) * t ** 2 / _np.log(2.0))
    _ar_g = g / g.sum()
    if not _AR_DL.rotate():
        _AR_DL.off = True
    if AIRREC_UL and not _AR_UL.rotate():
        _AR_UL.off = True
    if _AR_DL.off and _AR_UL.off:
        return
    ST.log("airrec ACTIF -> %s | descendant=%s montant=%s | UN fichier continu "
           "par sens, plafond %d Mo, coupure sous %d Mo libres. "
           "⚠️ I/Q RECONSTRUITE a partir des bits : ni bruit, ni ToA reelle, ni "
           "fading — rejeu fidele aux BITS, PAS une capture d'air."
           % (AIRREC_DIR, "oui" if not _AR_DL.off else "non",
              "oui" if not _AR_UL.off else "non",
              AIRREC_MAX // 1048576, AIRREC_FREE // 1048576))
    spf     = 1250 * AIRREC_OSR                 # 8 slots x 156,25 symboles
    step    = (625 * AIRREC_OSR) // 4           # 156,25 x OSR, entier si OSR%4==0
    blen    = 148 * AIRREC_OSR
    silence = _np.zeros(spf, dtype=_np.complex64)
    nxt = (now_fn() + 2) % GSM_HYPERFRAME
    while True:
        # ⚠️ COMPARAISON SIGNEE OBLIGATOIRE. `nxt` demarre 2 trames dans le
        # FUTUR : `(now_fn() - nxt) % GSM_HYPERFRAME` vaut alors ~2 715 646 et
        # non -2. Une premiere version prenait ce retard imaginaire pour un
        # decrochage, recalait, et repartait par `continue` SANS DORMIR : boucle
        # folle qui brulait un coeur et n'ecrivait jamais un octet.
        d = (now_fn() - nxt) % GSM_HYPERFRAME
        if d > GSM_HYPERFRAME // 2:      # nxt est dans le futur : on l'attend
            time.sleep(FRAME_DUR / 2.0)
            continue
        if d > 650:                      # >3 s de retard : irrattrapable, recale
            with _AR_DL.lock: _AR_DL.frames.clear()
            with _AR_UL.lock: _AR_UL.frames.clear()
            nxt = (now_fn() + 2) % GSM_HYPERFRAME
            time.sleep(FRAME_DUR)        # jamais de continue sans dormir ici
            continue
        if d < 2:
            time.sleep(FRAME_DUR / 2.0)
            continue
        _AR_DL.ecrire(nxt, spf, step, blen, silence)
        _AR_UL.ecrire(nxt, spf, step, blen, silence)
        nxt = (nxt + 1) % GSM_HYPERFRAME

def send_trxd_ul(tn, fn, burst148, cipher=False):
    """Émet un burst UL vers la BTS (rôle RX de la BTS) : hdr TRXDv0 + RSSI + ToA."""
    if _bts_addr["data"] is None:
        return
    buf = bytearray()
    buf.append((0 << 4) | (tn & 0x07))            # ver=0 | TN
    buf += struct.pack(">L", fn)                  # FN (BE)
    # RSSI : uint8 = -dBm. 0 signifie "0 dBm" et peut etre lu comme une valeur
    # aberrante/absente par le recepteur. On annonce un niveau realiste.
    buf.append(PONT_RSSI & 0xFF)                  # ex. 60 -> -60 dBm
    buf += struct.pack(">h", 0)                   # ToA256 = 0 (aligné)
    # osmo-bts convertit : sbit = 127 - octet (255 -> -127). Donc un bit 1 doit
    # partir en octet 255 et un bit 0 en octet 0. Envoyer 127 = sbit 0 = bit
    # TOTALEMENT AMBIGU -> le decodeur ne peut jamais conclure (trx_if.c:958).
    if cipher:                                   # RACH : JAMAIS chiffre
        burst148 = a5_apply(burst148, fn, True)
    buf += bytes(255 if b == 0x01 else 0 for b in burst148)
    sk_data.sendto(bytes(buf), _bts_addr["data"])
    capture_burst(fn, tn, burst148, True)
    # AIRREC MONTANT : ICI et pas avant — `burst148` vient de passer a5_apply,
    # c'est donc le burst tel qu'il part REELLEMENT sur l'air. Enregistrer avant
    # le chiffrement donnerait un fichier que `-e/-k` ne saurait pas relire et
    # qui ne montrerait pas ce que le reseau voit.
    airrec_feed_ul(fn, tn, burst148)
    capture_iq(burst148)
    ST.n_ul_sent += 1

def emit_with_timing(tn, target_fn, bursts, cipher=False, tch=False):
    """POINT 3 — poste chaque burst quand l'horloge atteint (target_fn - AVANCE).
    Compte les hors-fenêtre. bursts = liste de bursts, étalés sur des FN consécutifs
    du canal (POINT 1 : étalement UL des 4 bursts xcch)."""
    # ⚠️ Sur un TCH/F, les 8 bursts d'un bloc occupent des trames PORTEUSES
    # consecutives : il faut SAUTER fn%26 == 12 (SACCH) et 25 (idle). Emettre
    # sur target_fn+j les fait atterrir sur les mauvaises trames des que le bloc
    # traverse un de ces trous -> la BTS ne reassemble jamais le bloc, d'ou
    # "WAIT_RR_ASS_COMPLETE ... EQUIPMENT FAILURE" cote BSC.
    if tch:
        fns = []
        f = target_fn
        while f % 26 in (12, 25):
            f = (f + 1) % GSM_HYPERFRAME
        for _ in bursts:
            fns.append(f)
            f = _tch_next_fn(f)
    else:
        fns = [(target_fn + j) % GSM_HYPERFRAME for j in range(len(bursts))]
    for j, b148 in enumerate(bursts):
        fn_air = fns[j]                                 # FN cible de CE burst
        fn_post = (fn_air - UL_FN_ADVANCE) % GSM_HYPERFRAME
        # attente active bornée jusqu'à l'instant de post
        while True:
            cur = now_fn()
            delta = (fn_post - cur) % GSM_HYPERFRAME
            if delta == 0 or delta > GSM_HYPERFRAME // 2:
                break
            time.sleep(FRAME_DUR / 4)
        cur = now_fn()
        # fenêtre : le FN air visé doit être ~ cur + AVANCE
        if abs(((fn_air - (cur + UL_FN_ADVANCE)) + GSM_HYPERFRAME//2) % GSM_HYPERFRAME - GSM_HYPERFRAME//2) > WINDOW_TOL:
            ST.n_ul_out_of_window += 1
            ST.log("UL HORS-FENETRE : FN air=%u, FN courant=%u (attendu ~%u)"
                   % (fn_air, cur, (cur + UL_FN_ADVANCE) % GSM_HYPERFRAME))
            continue
        send_trxd_ul(tn, fn_air, b148, cipher)

# Canal dedie actif, publie par le FIRMWARE dans /dev/shm/calypso_dcch_cfg
# (format qemu_wrap.c:1013-1026 : seq u32@0, kind@4, ss@5, tn@6, chan_nr@7).
# kind : 0 = SDCCH/4 combine, 1 = SDCCH/8 — meme convention que set_dcch().
#
# [2026-08-21] Le pont ne lisait QUE `ss`, masque `& 3`, et jetait `kind` et
# `tn`. D'ou les trois defauts qui, ensemble, tuaient la LU sur un SDCCH/8 :
# sous-voie plafonnee a 4 (SS4..7 repliees sur SS0..3), fenetre UL toujours
# celle du /4, et slot d'emission fige a 0.
_dcch_fd = None

# Vrai des que calypso_dcch_cfg a ete LU (seq non nul) ; faux tant qu'on en est
# reduit au repli. Voir _dcch_cfg() et _dcch_active_ss().
_dcch_ok = False
def _dcch_cfg():
    """(kind, ss, tn) du canal dedie actif — lu, jamais suppose.

    ⚠️ UN SEUL fd persistant (cf. l'audit ci-dessous), et `& 7` sur la sous-voie :
    sur SDCCH/8 il y en a HUIT, et le `& 3` d'avant repliait SS4..7 sur SS0..3 —
    donc postait la SABM dans la fenetre d'un AUTRE abonne.

    ⚠️ CORRIGE (audit) : une version anterieure faisait
    `os.pread(os.open(DCCH_CFG, ...), 16, 0)` sans jamais fermer le fd. Appelee
    ~42 fois/s par TROIS threads, elle saturait la table de descripteurs (1024)
    en ~24 s — mesure live : 1015 fd sur calypso_dcch_cfg. Ensuite TOUT os.open
    echouait EN SILENCE : kc_read() rendait « pas de Kc » (A5 mort), tch_cfg_read()
    restait fige (TCH jamais arme), _tch_dl_open() levait. On garde donc UN fd
    persistant et on ne fait que des pread, comme tch_ul_loop pour l'anneau."""
    global _dcch_fd, _dcch_ok
    try:
        if _dcch_fd is None:
            _dcch_fd = os.open(DCCH_CFG, os.O_RDONLY)
        b = os.pread(_dcch_fd, 16, 0)
        if len(b) >= 8 and struct.unpack_from("<I", b, 0)[0]:
            _dcch_ok = True
            return (b[4] & 1, b[5] & 7, b[6] & 7)
    except OSError as e:
        # Une sonde muette rend son silence indecidable (regle du projet) :
        # on compte et on annonce la premiere erreur.
        try:
            if _dcch_fd is not None:
                os.close(_dcch_fd)
        except OSError:
            pass
        _dcch_fd = None
        ST.n_dcch_err += 1
        if ST.n_dcch_err == 1:
            ST.log("dcch_cfg illisible (%s) — dedie suppose SDCCH/4 SS0 TS0 "
                   "jusqu'a nouvel ordre" % e)
    # ⚠️ (0,0,0) est un REPLI, pas une lecture — et il est indiscernable d'un
    # vrai « SDCCH/4 SS0 TS0 ». Tant que personne ne faisait la difference, la
    # seule conduite sure etait de tout traiter. _dcch_ok permet desormais de
    # distinguer les deux, donc de fermer une porte sur une CONNAISSANCE et non
    # sur une ignorance.
    _dcch_ok = False
    return (0, 0, 0)

def _dcch_plan():
    """(plan, ss, tn) du canal dedie actif.

    Le plan vient de `kind`, c'est-a-dire de l'avis du FIRMWARE sur son propre
    chan_nr — exactement la source dont le shunt tire sa fenetre de presentation
    (calypso_dsp_shunt_set_dcch). Le deduire de TS_CONFIG[tn] en ferait une
    SECONDE verite, qui divergerait au premier desaccord et en silence."""
    kind, ss, tn = _dcch_cfg()
    return (PLAN_SD8 if kind else PLAN_SD4), ss, tn

def _dcch_ss():
    """Sous-voie dediee active (0..7).

    ⚠️ CORRIGE (audit) : la version precedente faisait
    `os.pread(os.open(DCCH_CFG, ...), 16, 0)` sans jamais fermer le fd. Appelee
    ~42 fois/s par TROIS threads, elle saturait la table de descripteurs (1024)
    en ~24 s — mesure live : 1015 fd sur calypso_dcch_cfg. Ensuite TOUT os.open
    echouait EN SILENCE : kc_read() rendait « pas de Kc » (A5 mort), tch_cfg_read()
    Ne duplique pas la lecture : _dcch_cfg() est la seule porte."""
    return _dcch_cfg()[1]

def next_sdcch_ul_fn(min_advance=4):
    """Prochaine FN de NOTRE horloge ouvrant un bloc SDCCH montant."""
    plan, ss, _tn = _dcch_plan()
    base51 = plan.ul_base(ss)
    start = now_fn() + min_advance
    for k in range(51):
        fn = (start + k) % GSM_HYPERFRAME
        if fn % 51 == base51:
            return fn
    return start % GSM_HYPERFRAME

_ul_sd_n = [0]     # compteur d'emissions SDCCH montantes (pour la trace ci-dessous)

def ul_sdcch_from_sideband():
    """Lit la L2 SDCCH déposée par l'ARM, l'encode et l'émet (4 bursts étalés)."""
    global _tch_mobile_ok      # cette fonction POSE la preuve (voir plus bas)
    fd = None; last_seq = -1
    while True:
        try:
            if fd is None:
                fd = os.open(SB_SDCCH_UL, os.O_RDONLY)
            b = os.pread(fd, 48, 0)               # pread : jamais bufferisé (piège connu)
            if len(b) >= 39:
                # Layout figé (qemu_wrap.c:944-946) : seq@0 l1s_fn@4 fn@8
                # task_u@12 l1s%51@14 l2[23]@16 (48 o).
                seq = struct.unpack_from("<I", b, 0)[0]
                if seq and seq != last_seq:
                    last_seq = seq
                    l1s_fn = struct.unpack_from("<I", b, 4)[0]
                    l2 = b[16:39]
                    # [2026-08-27, soir] PLUS DE LACHER SUR LA SABM. Mesure du
                    # run : 11 « Kc LACHE (SABM montante) » en fonctionnement
                    # normal, chacun en pleine session chiffree -- un
                    # re-etablissement LAPDm et le SAPI 3 du SMS sont des SABM,
                    # et ils vivent sur un canal DEJA chiffre. Le lacher est
                    # remonte la ou un canal est vraiment NEUF : l'IMMEDIATE
                    # ASSIGNMENT descendant (et le CHANNEL RELEASE). _est_sabm
                    # reste, il sert encore a lire les traces.
                    # MONTANT : on tape la L2 TELLE QUE LE MOBILE L'A POSEE,
                    # avant encodage et avant chiffrement. C'est la seule vue
                    # lisible du montant : aucun outil ne sait demoduler un
                    # enregistrement montant (pas de FCCH/SCH pour se caler).
                    # ── APRES L'ASSIGNATION, LE MONTANT EST DE LA FACCH ────
                    # Le firmware ne poste QUE la tache DUL (12) en montant --
                    # jamais TCHT (13) ni TCHA (14). Mesure du 27/08 sur les
                    # sondes LATCH : task_u=0 (11865 fois) et task_u=12 (1639),
                    # rien d'autre. shunt_capture_tch_ul() ne matche donc jamais,
                    # /dev/shm/calypso_tch_facch_ul n'est JAMAIS cree, et
                    # ul_facch_from_sideband boucle sur un open qui echoue :
                    # FACCH ul = 0.
                    #
                    # Consequence : meme apres avoir bascule sur le TCH, le
                    # mobile depose sa L2 montante ici, dans calypso_sdcch_ul --
                    # ASSIGNMENT COMPLETE compris. On la re-emettait alors dans
                    # la fenetre SDCCH du TS1, alors que la BTS ecoute la FACCH
                    # du TCH sur son propre slot. Le BSC restait en
                    # WAIT_RR_ASS_COMPLETE et sortait en « EQUIPMENT FAILURE:
                    # Timeout » -- exactement la panne que decrit la docstring
                    # de ul_facch_from_sideband.
                    #
                    # Des que tch_cfg est arme, ce montant appartient donc au
                    # TCH. On le FILE (on n'emet pas) : l'ordonnanceur unique
                    # tch_ul_scheduler l'enverra en volant la voix, comme le
                    # fait une vraie FACCH. Emettre ici entrelacerait deux
                    # sequences de 8 bursts sans verrou -- le defaut corrige le
                    # 16/08 dans ul_facch_from_sideband, qu'on ne refait pas.
                    _tn_tch = tch_cfg_read() if TCH_ENABLED else None
                    # L'ASSIGNMENT COMPLETE est LUI-MEME le premier message du
                    # nouveau canal : il part en FACCH, et il fait basculer.
                    if _tn_tch is not None and not _tch_mobile_ok:
                        if est_assignment_complete(l2):
                            tch_preuve_bascule("ASSIGNMENT COMPLETE montant sur "
                                               "la bande laterale SDCCH", _tn_tch)
                        else:
                            # Pas encore passe : ce montant appartient toujours au
                            # SDCCH. Le detourner ici, c'est le perdre.
                            _tn_tch = None
                    if _tn_tch is not None:
                        tap(now_fn(), GSMTAP_FACCH, l2[:GSM_MACBLOCK_LEN],
                            _tn_tch, True)
                        with _tch_q_lock:
                            _tch_q_facch.append(bytes(l2[:GSM_MACBLOCK_LEN]))
                        ST.n_facch_ul += 1
                        if ST.n_facch_ul <= 10 or (ST.n_facch_ul % 50) == 0:
                            ST.log("DUL->FACCH #%d : TCH arme TN=%d -- le montant "
                                   "part en FACCH et non dans la fenetre SDCCH"
                                   % (ST.n_facch_ul, _tn_tch))
                    else:
                        plan, ss, tn = _dcch_plan()
                        tap(now_fn(), GSMTAP_SDCCH4, l2, tn, True)
                        bursts = xcch_encode_4(l2)
                        # ⚠️ MEME BUG QUE LE RACH : `l1s_fn` est l'horloge du FIRMWARE,
                        # pas celle du pont (que la BTS suit via IND CLOCK). Emettre
                        # dedans donnait 35 bursts "hors fenetre". On vise le prochain
                        # bloc SDCCH montant de NOTRE horloge.
                        #
                        # ⚠️ LE SLOT ETAIT LA CONSTANTE 0. Toute SABM partait donc sur
                        # le TS0, quel que soit le chan_nr de l'IMMEDIATE ASSIGNMENT.
                        # Des que le BSC allouait le SDCCH/8 du TS1, la BTS ecoutait
                        # sur le TS1 et n'entendait rien : T200 x6 -> RR_REL_IND ->
                        # « Location update failed », avec un lchan cote BSC bloque
                        # en WAIT_RLL_RTP_ESTABLISH (rll_ready=no). Le slot vient
                        # maintenant du firmware, comme la sous-voie et la fenetre.
                        if _ul_sd_n[0] < 10 or (_ul_sd_n[0] % 50) == 0:
                            ST.log("SDCCH-UL -> %s SS=%d TS=%d fenetre fn%%51=%d (#%d)"
                                   % (plan.name, ss, tn, plan.ul_base(ss), _ul_sd_n[0]))
                        _ul_sd_n[0] += 1
                        emit_with_timing(tn, next_sdcch_ul_fn(), bursts, cipher=True)
        except OSError:
            fd = None
        time.sleep(FRAME_DUR / 8)

# Access burst RACH — mirror EXACT de qemu_wrap.c `ul_build_rach_ra` :
#   [8 tail][41 sync TS0][36 bits codes rach_ext_encode][3 tail] = 88 actifs,
#   le reste (88..147) en garde. En TRXDv0 osmo-bts n'accepte QUE 148 bits
#   (trx_if.c:816 GSM_BURST_LEN) : l'access burst est donc un burst de 148
#   dont seuls les 88 premiers portent le signal.
# Slots RACH valides, combination V (CCCH+SDCCH/4 combine) : osmo-trx ne fait
# tourner le correlateur RACH que sur ces positions (Transceiver::expectedCorrType
# case V) — reference qemu_wrap.c:2005-2011. Ailleurs, c'est le correlateur
# NORMAL-BURST qui tourne : l'access burst n'est JAMAIS detecte.
RACH_SLOTS_51 = frozenset([4, 5] + list(range(14, 37)) + [45, 46])

def next_rach_fn(min_advance=4):
    """Prochaine FN de NOTRE horloge tombant sur un slot RACH eligible."""
    base = now_fn() + min_advance
    for k in range(51):
        fn = (base + k) % GSM_HYPERFRAME
        if fn % 51 in RACH_SLOTS_51:
            return fn
    return base % GSM_HYPERFRAME

RACH_SYNC = "01001011011111111001100110101010001111000"   # 41, GSM::gRACHSynchSequenceTS0

def build_rach_burst(ra, bsic):
    coded = (ubit * 40)()
    _cod.gsm0503_rach_ext_encode(coded, ctypes.c_uint16(ra), ctypes.c_uint8(bsic), False)
    b = bytearray([0xFF]) * 148          # tout a -1 (tail/garde)
    p = 0
    for _ in range(8):  b[p] = 0xFF; p += 1                          # extended tail
    for i in range(41): b[p] = 0x01 if RACH_SYNC[i] == "1" else 0xFF; p += 1
    for i in range(36): b[p] = 0x01 if coded[i] else 0xFF; p += 1    # RA codee (BSIC color)
    for _ in range(3):  b[p] = 0xFF; p += 1                          # tail  -> p == 88
    return bytes(b)

def ul_rach_from_sideband():
    """POINT 3 — RACH : UL-only, 1 SEUL burst (access), pas de réassemblage xcch."""
    fd = None; last = None
    while True:
        try:
            if fd is None:
                fd = os.open(SB_RACH, os.O_RDONLY)
            b = os.pread(fd, 16, 0)
            if len(b) >= 8:
                # Layout figé (calypso_trx.c:687 / qemu_wrap.c:899) :
                # [0..3]seq u32 LE | [4]ra | [5]bsic | [8..11]fn u32 LE (16 o).
                seq, ra, bsic, fn = struct.unpack_from("<IBBxxI", b, 0) if len(b) >= 12 else (0, 0, BSIC, 0)
                if seq and seq != last:
                    last = seq
                    b148 = build_rach_burst(ra, bsic)
                    # ⚠️ NE PAS emettre au l1s_fn du FIRMWARE : c'est une AUTRE
                    # base de temps que l'horloge du pont (que la BTS suit via
                    # IND CLOCK). Emettre dedans faisait attendre une FN qui
                    # n'arrive jamais -> 2 RACH envoyes sur 16 publies.
                    # On emet au PROCHAIN slot RACH eligible de NOTRE horloge.
                    emit_with_timing(0, next_rach_fn(), [b148])   # 1 seul burst
                    ST.n_rach += 1
        except OSError:
            fd = None
        time.sleep(FRAME_DUR / 8)

# =========================== threads réseau TRX ===============================
def th_ctrl():
    while True:
        data, addr = sk_ctrl.recvfrom(1500)
        req = data.decode("latin1").strip("\0").strip()
        if not req.startswith("CMD"):
            continue
        parts = req.split()
        cmd = parts[1] if len(parts) > 1 else ""
        # On répond RSP <cmd> 0 [écho des args] — suffit à POWERON->actif.
        rsp = "RSP %s 0%s" % (cmd, ("" if len(parts) <= 2 else " " + " ".join(parts[2:])))
        sk_ctrl.sendto(rsp.encode() + b"\0", addr)
        # L'horloge DOIT partir des le POWERON : osmo-bts-trx coupe la BTS avec
        # "No clock since TRX was started" s'il ne recoit pas d'IND CLOCK. On
        # apprend donc l'adresse CLCK ICI (meme IP que le CTRL, port base+100),
        # et surtout PAS en attendant un burst DATA (deadlock : pas de DATA tant
        # que la BTS n'est pas active).
        if _bts_addr["clck"] is None:
            _bts_addr["clck"] = (addr[0], TRX_BASE + 100)
            ST.log("horloge armee vers %s:%d (apprise du CTRL)" % (addr[0], TRX_BASE + 100))
        ST.log("CTRL %s -> %s" % (cmd, rsp))

def th_data_rx():
    while True:
        data, addr = sk_data.recvfrom(2000)
        _bts_addr["data"] = addr
        if len(data) < 5:
            continue
        tn = data[0] & 0x07
        fn = struct.unpack_from(">L", data, 1)[0]
        # DL TX de la BTS (L12TRX) : en-tete TxMsg = 6 octets et non 5 —
        # [0]=ver|tn, [1:5]=fn (BE), [5]=pwr (attenuation Tx, data_msg.py:320
        # `self.pwr = hdr[5]`). Le burst commence donc a l'offset 6. Lire a 5
        # decalait TOUS les bits d'un octet -> 100 % de CRC fail.
        burst = data[6:6+148]
        if len(burst) == 148:
            # Relais vers le BSP AVANT tout traitement : sendto est non bloquant
            # et on ne veut pas que le cout du decodage decale l'I/Q publiee.
            # En-tete 6 o de la BTS + 2 o de ToA (le BSP lit buf[5] puis saute 8).
            if BSP_FEED:
                try:
                    sk_bsp.sendto(bytes(data[0:6]) + b"\x00\x00" + bytes(burst),
                                  (BSP_HOST, BSP_PORT))
                    ST.n_bsp_fed += 1
                except OSError as e:
                    ST.n_bsp_err += 1
                    if ST.n_bsp_err <= 3:
                        ST.log("BSP relais ECHEC #%d (%s)" % (ST.n_bsp_err, e))
            # 148 iterations Python PAR BURST, soit ~250 000 par seconde --
            # pour deux consommateurs qui sortent aussitot quand ils sont
            # coupes (capture_burst : `if _bf is None: return` ; airrec_feed :
            # `if AIRREC and ...`). On ne fabrique donc `_b` que si quelqu'un
            # le lit vraiment.
            if _bf is not None or AIRREC:
                _b = bytes(0x01 if b else 0xFF for b in burst)
                capture_burst(fn, tn, _b, False)
            # AIRREC : depot seul, aucun calcul ici (cf. airrec_feed). C'est le
            # SEUL point du programme ou le descendant est visible sous forme de
            # bits — capture_iq, lui, n'est appele que depuis send_trxd_ul et ne
            # voyait donc que le montant.
                airrec_feed(fn, tn, _b)
            dl_dispatch(tn, fn, burst)

# [2026-08-27] UNE INDICATION PAR MULTITRAME, PAS UNE PAR TRAME.
#
# On en envoyait une toutes les FRAME_DUR, ~217/s. osmo-bts-trx appelle
# trx_sched_clock() a CHAQUE indication et corrige a chaque fois : rattrapage par
# bts_sched_fn() (« N FN slower ») ou reprogrammation du timerfd (« N FN
# faster »). 217 indications/s, c'est 217 occasions de corriger par seconde, et
# la gigue de time.sleep() en CPython suffit a en declencher une sur sept.
# scheduler_trx.c pose MAX_FN_SKEW = 50 : la tolerance est dimensionnee pour une
# indication PAR MULTITRAME DE 51. L'horloge fine est le timerfd du BTS ;
# l'indication ne sert qu'a corriger la derive lente.
#
# MESURE qui motive ce changement (27/08, run de 17:01) :
#   BTS#0 (derriere ce pont) 5502 compensations   BTS#1 (fake_trx) 190   -> 29x
#   decodeur TCH : gap=1451 pour 407 blocs tentes -- l'accumulateur de 8 bursts
#   vide 3,5 fois plus souvent qu'il n'aboutit, d'ou FACCH dl=0
#   canal dedie : TS1/0 111/469 (24%) contre TS0/2 654/654 (100%) sur le commun
#
# CIBLE VERIFIABLE : gap doit s'effondrer et FACCH dl devenir non nul. Sinon la
# cause est ailleurs, et on aura elimine cette variable proprement.
# Le FN reste f(t) sur time.monotonic() : seule la CADENCE change, la valeur
# annoncee reste exacte. PONT_CLCK_PERIOD_FN=1 retablit l'ancien comportement.
CLCK_PERIOD_FN = int(os.environ.get("PONT_CLCK_PERIOD_FN", "51"))

def th_clck():
    # POINT 4 — IND CLOCK périodique, FN dérivé du temps absolu.
    while True:
        fn = now_fn()
        if _bts_addr["clck"]:
            sk_clck.sendto(("IND CLOCK %u" % fn).encode() + b"\0", _bts_addr["clck"])
        time.sleep(FRAME_DUR * CLCK_PERIOD_FN)   # le FN reste f(t), jamais accumule

def th_stats():
    while True:
        time.sleep(5)
        ST.log("STATS dl_bursts=%d dl_dec=%d crc_fail=%d | ul_sent=%d hors_fenetre=%d rach=%d | FN=%u"
               % (ST.n_dl_bursts, ST.n_dl_decoded, ST.n_dl_crc_fail,
                  ST.n_ul_sent, ST.n_ul_out_of_window, ST.n_rach, now_fn())
               + " | dummy=%d dedie_hors=%d" % (ST.n_dl_dummy, ST.n_dl_ded_skip)
               + " | TCH dl=%d ul=%d crc=%d" % (ST.n_tch_dl, ST.n_tch_ul, ST.n_tch_crc)
               + " | A5 dl=%d ul=%d" % (ST.n_a5_dl, ST.n_a5_ul)
               + " | FACCH dl=%d ul=%d gap=%d" % (ST.n_facch_dl, ST.n_facch_ul, ST.n_tch_gap)
               + " | BSP fed=%d err=%d" % (ST.n_bsp_fed, ST.n_bsp_err)
               + " | ul_court=%d" % ST.n_tch_ul_court
               + " | TAP dl=%d ul=%d" % (ST.n_tap_dl, ST.n_tap_ul)
               + " | FIFO dl=%d/%d ul=%d/%d"
                 % (_AR_DL.n_fifo, _AR_DL.n_fifo_drop,
                    _AR_UL.n_fifo, _AR_UL.n_fifo_drop)
               + " | AIRREC dl=%dtr/%dbu ul=%dtr/%dbu"
                 % (_AR_DL.n_frames, _AR_DL.n_bursts,
                    _AR_UL.n_frames, _AR_UL.n_bursts)
               + " | TCHUL bursts=%d file_v=%d file_f=%d drop=%d vol=%d perdu=%d"
                 % (ST.n_tch_burst, len(_tch_q_voice), len(_tch_q_facch),
                    ST.n_tch_ul_drop, ST.n_tch_ul_vole, ST.n_tch_ul_perdu))
        # Detail par base de bloc (GSM 05.02) : montre d'ou vient le crc_fail.
        # 2=BCCH  6/12/16=CCCH  22/26/32/36=SDCCH  42/46=SACCH.
        if ST.n_by_base:
            det = " ".join("TS%d/%d:%d/%d" % (b[0], b[1], v[0], v[0] + v[1])
                           for b, v in sorted(ST.n_by_base.items()))
            ST.log("DETAIL blocs (TS/base51 : decodes/tentes) " + det)
        _p, _ss, _tn = _dcch_plan()
        _gate = "sous-voie seule" if TS_CONFIG.get(_tn, "") and \
                plan_for(TS_CONFIG.get(_tn, "")) is _p else "TOUT (dedie non designe)"
        ST.log("SOUS-VOIE ACTIVE (%s SS=%d TS=%d base DL=%d, UL=%d, filtre=%s) : "
               "clair %d/%d  chiffre %d/%d"
               % (_p.name, _ss, _tn, _p.sdcch_dl[_ss % _p.n_sub], _p.ul_base(_ss),
                  _gate,
                  ST.n_act_clear[0], ST.n_act_clear[1],
                  ST.n_act_ciph[0],  ST.n_act_ciph[1]))

def _garde(fn):
    """Enveloppe un thread : toute exception est LOGUEE (et le thread repart).
    Sans ca, une exception non-OSError tue le thread en silence -> l'UL cesse
    d'emettre sans qu'aucun compteur ni journal ne le dise."""
    import traceback
    def run():
        while True:
            try:
                fn()
            except Exception:
                ST.log("THREAD %s EXCEPTION:\n%s" % (fn.__name__, traceback.format_exc()))
                time.sleep(1)
                continue
            # --- _garde : retour normal = thread TERMINE, PAS a relancer -------
            # [2026-08-27] Le `while True` relancait aussi les retours NORMAUX,
            # sans le moindre sleep. Une fonction de thread qui choisit de rendre
            # la main -- th_airrec le fait quand PONT_AIRREC=0 -- repartait donc
            # aussitot, a pleine vitesse.
            # CE QUE CA A COUTE : 18 146 889 lignes et 1,27 Go dans
            # /dev/shm/pont.log, soit 1,2 Go de RAM (tmpfs), plus un coeur entier
            # brule a tourner a vide, sur une VM de 8 Go. Le defaut PONT_AIRREC=1
            # masquait le piege : la branche de retour n'etait jamais prise.
            # Les autres threads sont tous des `while True` : ils ne retournent
            # jamais normalement, donc parquer ici ne change rien pour eux.
            ST.log("THREAD %s termine normalement — parque (pas de relance)"
                   % fn.__name__)
            return
    run.__name__ = fn.__name__
    return run

def main():
    global _T0
    _T0 = time.monotonic()
    # PURGE DU Kc AU DEMARRAGE. /dev/shm survit aux runs : un Kc laisse par un run
    # a5/1 anterieur fait chiffrer le pont avec une cle etrangere — y compris sur un
    # reseau en a5 0. Mesure : A5 dl=680 alors qu'osmocon n'avait ecrit AUCUN Kc.
    # (Prescrit par SHUNT_LEGIT_ADDRESS_MAP.md:271 ; 09-teardown.sh:175 le fait pour
    # le pipeline qemu-src, mais pas pour le pont.)
    try:
        os.unlink(KC_PATH)
        ST.log("Kc purge au demarrage (%s) — pas de cle heritee d'un run precedent" % KC_PATH)
    except OSError:
        pass
    ST.log("pont TRX démarré : base=%d (CLCK/CTRL/DATA %d/%d/%d) BSIC=%d ARFCN=%d UL_FN_ADVANCE=%d"
           % (TRX_BASE, TRX_BASE, TRX_BASE+1, TRX_BASE+2, BSIC, ARFCN, UL_FN_ADVANCE))
    # Une sonde muette rend son silence indecidable : on annonce le PLAN retenu
    # pour chaque slot, pas seulement le texte lu. C'est precisement ce qui
    # manquait — le pont affichait « 1: SDCCH8 » depuis toujours alors qu'aucun
    # plan /8 n'existait, et cette ligne suffisait a faire croire au contraire.
    ST.log("slot-map (osmo-bsc.cfg) : %s" % TS_CONFIG)
    for _tn in sorted(TS_CONFIG):
        _p = plan_for(TS_CONFIG[_tn])
        if _p is None:
            continue
        ST.log("  TS%d %-12s plan=%s  %d sous-voies  DL fn%%51=%s  UL fn%%51=%s  SACCH=%s"
               % (_tn, TS_CONFIG[_tn], _p.name, _p.n_sub, list(_p.sdcch_dl),
                  [_p.ul_base(i) for i in range(_p.n_sub)], list(_p.sacch_dl)))
    if TAP:
        ST.log("tap GSMTAP ACTIF -> %s:%d (descendant ET montant, drapeau uplink "
               "pose). Wireshark : udp port %d. PONT_TAP=0 pour couper."
               % (GSMTAP_HOST, TAP_PORT, TAP_PORT))
    else:
        ST.log("tap GSMTAP desactive (PONT_TAP=0)")
    # SIGUSR1 = « Split » d'AIRREC (le dashboard s'en sert pour decouper une
    # tranche). ⚠️ signal.signal() ne fonctionne QUE dans le thread principal :
    # l'installer depuis th_airrec levait ValueError, que le try/except avalait
    # -> le gestionnaire n'etait JAMAIS pose et le bouton Record du web ne
    # provoquait aucune rotation (mesure : segment inchange apres kill -USR1).
    # Une degradation silencieuse : le pont continuait a enregistrer, seul le
    # decoupage etait mort.
    if AIRREC:
        try:
            signal.signal(signal.SIGUSR1, _ar_on_usr1)
            ST.log("SIGUSR1 arme : split AIRREC disponible (kill -USR1 %d)" % os.getpid())
        except ValueError as e:
            ST.log("SIGUSR1 NON arme (%s) — le split du dashboard sera inoperant" % e)
    # Toute sonde s'annonce au demarrage : une sonde muette est indiscernable
    # d'une sonde absente (regle de mesure du projet).
    if BSP_FEED:
        ST.log("relais BSP ACTIF -> %s:%d (bursts DL, TRXDv0 156 o). Sous DSP_SHUNT "
               "le BSP draine + publie l'I/Q + apprend son peer, il ne fait PAS "
               "demoduler le DSP. PONT_BSP_FEED=0 pour couper." % (BSP_HOST, BSP_PORT))
    else:
        ST.log("relais BSP desactive (PONT_BSP_FEED=0) — le BSP reste a sec")
    # apprend l'adresse CLCK/CTRL du BTS via un premier RSP/echo : simplifié, on
    # réutilise l'adresse DATA pour CLCK (même IP) dès qu'un burst arrive.
    _threads = [th_ctrl, th_data_rx, th_clck, th_stats,
                ul_sdcch_from_sideband, ul_rach_from_sideband, tch_ul_loop,
                ul_facch_from_sideband, tch_ul_scheduler]
    # On ne demarre pas un thread qui n'a rien a faire : plus lisible dans
    # `ps -L` qu'un thread parque, et une sonde de moins a expliquer.
    if AIRREC:
        _threads.append(th_airrec)
    else:
        ST.log("airrec DESACTIVE (PONT_AIRREC=0) — thread non demarre, "
               "aucun cfile ne sera ecrit")
    for fn in _threads:
        threading.Thread(target=_garde(fn), daemon=True, name=fn.__name__).start()
    while True:
        time.sleep(3600)

if __name__ == "__main__":
    main()
