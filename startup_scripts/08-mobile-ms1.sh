# 08-mobile-ms1.sh - partie de start.sh (lignes 1517-1541 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
say_begin "Generation mobile MS#1"
MS1_CFG="${MOBILE_CFG_MS1_PATH:-$BB_DIR/mobile.cfg}"
generate_mobile_cfg "$MS1_CFG" \
    4247 \
    /tmp/osmocom_l2 \
    "${SAP_SOCK:-/tmp/osmocom_sap}" \
    "$MS_ARFCN1" \
    "$(ms_imsi 1)" \
    "$(ms_ki 1)"
# La copie que le lanceur ouvre reellement. On la REGENERE plutot que de la
# copier : generate_mobile_cfg fixe aussi le port VTY, les sockets et l'ARFCN,
# et un simple cp propagerait le fichier statique de qosmo.
# ── ET ON EMPECHE QU'IL SOIT ECRASE ─────────────────────────────────────
# Ecrire ce fichier ne suffit pas : run.sh le REECRIT juste apres. Son module
# 20-mobile-cfg.sh copie MOBILE_CFG_SRC par-dessus, et ce chemin vaut par
# defaut $QEMU_TREE/cfgs/mobile_group1.cfg - le fichier statique de qosmo,
# fige sur l'operateur 1. Mesure sur le banc :
#     mobile.cfg          18:22:22  imsi=002010002000001 arfcn=516
#     mobile_group1.cfg   18:22:27  imsi=001010001000001 arfcn=514
# Cinq secondes d'ecart, et c'est le second que le mobile ouvre.
# On designe donc NOTRE fichier comme source : le module recopie alors le bon
# contenu, et son controle d'idempotence (cmp -s src dest) passe puisque les
# deux sont identiques. Aucune modification de qosmo.
export MOBILE_CFG_SRC="$MS1_CFG"

