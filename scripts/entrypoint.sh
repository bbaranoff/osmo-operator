#!/bin/bash
set -e

# --- TUN device ---
echo "[*] Initialisation du peripherique TUN pour osmo-ggsn..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    # Create the device node (c = character, 10 = major, 200 = minor)
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# --- Environment ---
container=docker
export container

# A command is required
if [ $# -eq 0 ]; then
  echo >&2 'ERROR: No command specified. You probably want to run bash or a script.'
  exit 1
fi

# Export the variables for the systemd sessions
env > /etc/docker-entrypoint-env

# Create the startup service
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

# Mask the conflicting systemd services
systemctl mask systemd-firstboot.service systemd-udevd.service systemd-modules-load.service \
               systemd-udevd-kernel systemd-udevd-control 2>/dev/null || true
systemctl enable docker-entrypoint.service

# Locate and exec systemd
if [ -x /lib/systemd/systemd ]; then
  exec /lib/systemd/systemd --show-status=false --unit=multi-user.target
elif [ -x /usr/lib/systemd/systemd ]; then
  exec /usr/lib/systemd/systemd --show-status=false --unit=multi-user.target
else
  echo >&2 'ERROR: systemd is not installed'
  exit 1
fi

# NOTE: RUN/COPY/EXPOSE directives belong in the Dockerfile, not in this script.
# exec systemd replaces the process - nothing after that line is executed.
