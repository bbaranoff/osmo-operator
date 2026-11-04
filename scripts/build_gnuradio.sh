#!/usr/bin/env bash
set -euo pipefail

# scripts/build_gnuradio.sh - GNU Radio 3.10 + gr-osmosdr + gr-gsm dans /root/.env
#
# [2026-10-09] Vendorise depuis l ancien gist
# (gist.githubusercontent.com/bbaranoff/3683811057933af0954b661821e950d1).
# Raisons : ne plus dependre d un `curl | bash` externe au build (le gist peut
# bouger ou disparaitre, et rien ne le versionnait avec le reste), et surtout
# BORNER le parallelisme des trois `cmake --build` par la RAM : GNU Radio est le
# gros consommateur, et `-j$(nproc)` sur un runner arm64 faisait tuer le build
# pour OOM (SIGTERM / exit 143).
# [2026-11-04] Revendorise (le commit du 2026-10-10 l avait retire et remis le
# gist). jobs-for-ram n existe plus dans l image : calcul sur place, ~2 Go de
# memoire disponible par job, borne par nproc. JOBS=N force la valeur.
if [ -z "${JOBS:-}" ]; then
    MEM_GB=$(awk '/^MemAvailable:/{print int($2/1048576)}' /proc/meminfo)
    JOBS=$(( MEM_GB / 2 ))
    if [ "$JOBS" -lt 1 ]; then JOBS=1; fi
    if [ "$JOBS" -gt "$(nproc)" ]; then JOBS=$(nproc); fi
fi

# ── 0. Nettoyage des résidus système ──
echo "=== Nettoyage ==="
rm -rf /usr/local/lib/libgnuradio-*
rm -rf /usr/local/lib/libgnuradio_*
rm -rf /usr/local/lib/libgrgsm*
rm -rf /usr/local/lib/python3*/dist-packages/gnuradio
rm -rf /usr/local/lib/python3*/dist-packages/osmosdr
rm -rf /usr/local/lib/python3*/dist-packages/grgsm
rm -rf /usr/local/include/gnuradio
rm -rf /usr/local/include/osmosdr
rm -rf /usr/local/include/gsm
rm -rf /usr/local/lib/cmake/gnuradio
rm -rf /usr/local/lib/cmake/osmosdr
rm -rf /usr/local/lib/cmake/gsm
rm -rf /usr/lib/python3*/dist-packages/gnuradio
rm -rf /usr/lib/python3*/dist-packages/osmosdr
rm -rf /usr/lib/python3*/dist-packages/grgsm
rm -rf /opt/GSM/gnuradio
rm -rf /opt/GSM/gr-osmosdr
rm -rf /opt/GSM/gr-gsm
rm -rf /root/.env
ldconfig

# ── 1. Créer le venv et installer les dépendances Python ──
echo "=== Venv ==="
python3 -m venv /root/.env
source /root/.env/bin/activate
pip install --upgrade pip wheel
# PyQt5 : wheel PyPI sur x86_64 seulement. Sur aarch64 pip compile le sdist
# PyQt5-5.15.11.tar.gz (~30 min) et epuise la memoire du runner : OOM kill de
# pip, docker-arm du 2026-10-24 (run 40075061083). On y prend le python3-pyqt5
# d Ubuntu, tire par `apt build-dep gnuradio` du Dockerfile (meme Python 3.12).
if [ "$(uname -m)" = x86_64 ]; then PYQT=pyqt5; else PYQT=; fi
pip install mako "numpy<2" pyyaml click click-plugins zmq scipy pybind11 jinja2 six $PYQT

# ── 2. Variables d'environnement ──
export PREFIX=/root/.env
export PYBIN=$PREFIX/bin/python3
PYVER=$($PYBIN -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
export PY_SITE=$PREFIX/lib/python${PYVER}/site-packages
if [ -z "$PYQT" ]; then
    if [ -d /usr/lib/python3/dist-packages/PyQt5 ]; then
        ln -sfn /usr/lib/python3/dist-packages/PyQt5 "$PY_SITE/PyQt5"
        echo "PyQt5 : python3-pyqt5 du systeme, lie dans le venv"
    else
        echo "ATTENTION : ni wheel PyQt5 ni python3-pyqt5 : gr-qtgui sans Python" >&2
    fi
fi

# Triplet multiarch de l hote (x86_64-linux-gnu, aarch64-linux-gnu...) : ne pas
# figer x86_64, sinon les chemins -dev sont faux sur le build arm64 du Pi.
MULTIARCH=$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)

export PATH=$PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib/$MULTIARCH:${LD_LIBRARY_PATH:-}
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/lib/$MULTIARCH/pkgconfig:${PKG_CONFIG_PATH:-}
export PYTHONPATH=$PY_SITE:${PYTHONPATH:-}
export CMAKE_PREFIX_PATH=$PREFIX
export LDFLAGS="-L$PREFIX/lib"

mkdir -p /opt/GSM
cd /opt/GSM

# ── 3. Build GNU Radio ──
echo "=== GNU Radio (-j$JOBS) ==="
git clone --recursive --branch maint-3.10 https://github.com/gnuradio/gnuradio.git
cd gnuradio
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DENABLE_PYTHON=ON \
    -DPYTHON_EXECUTABLE=$PYBIN \
    -DGR_PYTHON_DIR=$PY_SITE \
    -DENABLE_GRC=OFF \
    -DENABLE_DEFAULT=ON \
    -DENABLE_TESTING=OFF \
    -DENABLE_DOXYGEN=OFF \
    -DCMAKE_INSTALL_RPATH=$PREFIX/lib
cmake --build build -j"$JOBS"
cmake --install build

echo "$PREFIX/lib" > /etc/ld.so.conf.d/gnuradio.conf
ldconfig

$PYBIN -c "from gnuradio import gr, blocks, digital, filter; print('GR', gr.version())"
cd /opt/GSM

# ── 4. Build gr-osmosdr ──
echo "=== gr-osmosdr (-j$JOBS) ==="
git clone https://gitea.osmocom.org/sdr/gr-osmosdr
cd gr-osmosdr
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DENABLE_PYTHON=ON \
    -DPYTHON_EXECUTABLE=$PYBIN \
    -DGR_PYTHON_DIR=$PY_SITE \
    -DCMAKE_INSTALL_RPATH=$PREFIX/lib
cmake --build build -j"$JOBS"
cmake --install build
ldconfig
cd /opt/GSM

# ── 5. Build gr-gsm ──
echo "=== gr-gsm (-j$JOBS) ==="
git clone https://github.com/bkerler/gr-gsm
cd gr-gsm
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DENABLE_PYTHON=ON \
    -DPYTHON_EXECUTABLE=$PYBIN \
    -DGR_PYTHON_DIR=$PY_SITE \
    -DCMAKE_INSTALL_RPATH=$PREFIX/lib \
    -DBUILD_APPS=OFF
cmake --build build -j"$JOBS"
cmake --install build
ldconfig

# Fix pybind11 : gr::block doit être chargé avant gr-gsm
sed -i '1i from gnuradio import gr' $PY_SITE/gnuradio/gsm/__init__.py

cd /opt/GSM

# ── 6. Vérifications finales ──
echo "=== Vérifications ==="
$PYBIN -c "from gnuradio import gr; print('GNU Radio', gr.version())"
$PYBIN -c "import osmosdr; print('osmosdr OK')"
$PYBIN -c "from gnuradio import gsm; print('gr-gsm OK')"

# Vérif que tout linke dans le venv
echo "=== Vérif linking ==="
ldd $PY_SITE/gnuradio/gsm/gsm_python*.so 2>/dev/null | grep gnuradio || true
ldd $PY_SITE/osmosdr/osmosdr_python*.so 2>/dev/null | grep gnuradio || true

echo "=== Terminé ==="
