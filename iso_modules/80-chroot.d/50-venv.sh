# iso_modules/80-chroot.d/50-venv.sh - venv /root/.env (tomli, numpy 1.x).
# Execute DANS le chroot par iso_modules/80-chroot.sh : tous les fragments
# sont sources dans l ordre par UN SEUL bash (variables partagees : APT_OPTS,
# _S, NODE_VIA_APT, MONGO_VIA_APT...). Pas executable seul.
# Fin de fragment : `true`, sinon un dernier test faux arreterait tout (set -e).

# ── venv /root/.env: must exist and provide tomli ──────────────────────
# /root/.env is the venv activated by the bridge (grgsm_exe) and the root
# profile (.bashrc: [ -f /root/.env/bin/activate ] && source ...). It is copied
# from the image with "|| true", so it may be missing or point to an absent
# interpreter, and everything would silently fall back to the system python3.
#
# python3 -m venv WITHOUT --clear repairs: it recreates bin/ and pyvenv.cfg,
# installs pip via ensurepip and keeps site-packages. It works on the copied
# venv and on a missing directory. ensurepip needs python3-venv in PKGS.
#
# tomli: the code imports tomli (not tomllib), so it is installed explicitly.
python3 -m venv /root/.env
/root/.env/bin/python3 -m pip install -q --no-cache-dir --disable-pip-version-check tomli \
    || echo "WARN: pip a echoue pour tomli dans /root/.env"
if /root/.env/bin/python3 -c "import tomli" 2>/dev/null; then
    echo "  /root/.env : venv pret, tomli importable"
else
    echo "WARN: /root/.env sans tomli utilisable"
fi
# numpy STAYS at 1.x in the venv: GNU Radio 3.10 and gr-gsm are built against
# it (scripts/build_gnuradio.sh pins "numpy<2"). Any later unpinned pip install
# (pyopencl, matplotlib...) pulls numpy 2 and gnuradio fails at import with
# « initialization failed ». Put back to 1.x if the copied venv drifted.
if /root/.env/bin/python3 -c "import numpy,sys; sys.exit(int(numpy.__version__[0]) < 2)" 2>/dev/null; then
    /root/.env/bin/python3 -m pip install -q --no-cache-dir --disable-pip-version-check "numpy<2" "contourpy<1.4" \
        && echo "  /root/.env : numpy ramene en 1.x (GNU Radio / gr-gsm)" \
        || echo "WARN: /root/.env garde numpy 2 - gnuradio/gr-gsm ne s importeront pas"
fi

true
