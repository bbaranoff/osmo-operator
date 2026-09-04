# `services/` — unités systemd

Les unités du projet, rassemblées ici plutôt que dispersées entre la racine et
`scripts/`. Elles sont installées par le `Dockerfile` (image) et par `build-iso.sh`
(support bootable) ; l'installation native ne les active pas.

| Unité | Rôle |
|---|---|
| `osmo-bts-trx.service` | station de base, transceiver TRX |
| `osmo-egprs-web.service` | console web d'exploitation |
| `osmo-banc.service` | le banc GSM autonome (`start-direct.sh`), **activé au boot** de l'ISO ; pile dans tmux `calypso` |
| `osmo-multi.service` | le banc multi-opérateur (`start-multi.sh`), posé mais non activé ; `Requires=osmo-banc` |

Reprendre la main sur le banc lancé en service :

```bash
tmux attach -t calypso            # Ctrl-b d pour détacher, le banc continue
journalctl -u osmo-banc -f        # sortie de start-direct.sh / run.sh
systemctl restart osmo-banc       # un banc neuf ; launch.sh (icône) fait pareil puis s'attache
systemctl start osmo-multi        # ajoute les conteneurs + inter-STP (docker requis)
```

Options durables : `OSMO_BANC_ARGS="--dsp"` dans `/etc/default/osmo-banc`
(`OSMO_MULTI_ARGS` dans `/etc/default/osmo-multi`). `launch.sh --dsp` les pose
pour la session via `systemctl set-environment`.

Les unités sous `contrib/systemd/` appartiennent à QEMU en amont et ne relèvent
pas de ce dossier.

Installer à la main :

```bash
sudo cp services/osmo-bts-trx.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now osmo-bts-trx
```
