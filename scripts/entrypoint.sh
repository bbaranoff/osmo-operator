#!/bin/bash
set -e

# --- AJOUT DE LA PARTIE TUN ---
echo "[*] Initialisation du peripherique TUN pour osmo-ggsn..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    # Creation du noeud de peripherique (c = caractere, 10 = majeur, 200 = mineur)
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# --- CONFIGURATION ENVIRONNEMENT ---
container=docker
export container

# Verification de la presence d'une commande
if [ $# -eq 0 ]; then
  echo >&2 'ERROR: No command specified. You probably want to run bash or a script.'
  exit 1
fi

# Export des variables pour les sessions systemd
env > /etc/docker-entrypoint-env

# Creation du service de demarrage
quoted_args="$(printf " %q" "${@}")"
echo "${quoted_args}" > /etc/docker-entrypoint-cmd

cat >/etc/systemd/system/docker-entrypoint.service <<EOT
[Unit]
Description=Lancement de la stack Osmocom Simulee
After=network.target

[Service]
ExecStart=/bin/bash -exc "source /etc/docker-entrypoint-cmd"
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit
WorkingDirectory=/etc/osmocom
EnvironmentFile=/etc/docker-entrypoint-env

[Install]
WantedBy=multi-user.target
EOT

# Desactivation des services systemd conflictuels
systemctl mask systemd-firstboot.service systemd-udevd.service systemd-modules-load.service \
               systemd-udevd-kernel systemd-udevd-control 2>/dev/null || true
systemctl enable docker-entrypoint.service

# Localisation et execution de systemd
if [ -x /lib/systemd/systemd ]; then
  exec /lib/systemd/systemd --show-status=false --unit=multi-user.target
elif [ -x /usr/lib/systemd/systemd ]; then
  exec /usr/lib/systemd/systemd --show-status=false --unit=multi-user.target
else
  echo >&2 'ERROR: systemd is not installed'
  exit 1
fi

# NOTE : Les directives RUN/COPY/EXPOSE qui etaient ici sont des instructions
# Dockerfile et doivent etre dans le Dockerfile, pas dans ce script.
# exec systemd remplace le process - rien apres cette ligne n'est execute.
