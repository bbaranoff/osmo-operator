# 07-plan-mobile.sh - partie de start.sh (lignes 1512-1516 de start-native.sh d'origine)
# Sourcee par start.sh dans le shell principal : meme ordre, memes variables.
printf '  %sPLMN MS%s    MCC %s  MNC %s  operateur %s  ->  IMSI %s / %s\n' \
    "${C_DIM:-}" "${C_Z:-}" "$MS_MCC" "$MS_MNC" "$MS_OP_ID" "$(ms_imsi 1)" "$(ms_imsi 2)"
printf '  %sradio%s      MS#1 sur ARFCN %s (BTS principale)   MS#2 sur ARFCN %s (side-car, unit-id %s)\n' \
    "${C_DIM:-}" "${C_Z:-}" "$MS_ARFCN1" "$MS_ARFCN2" "$SC_UNIT_ID"

