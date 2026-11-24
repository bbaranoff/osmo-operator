## osmo_egprs — images SD arm64 (Armbian)

La meme pile que les ISO x86, construite pour aarch64 par le framework
[armbian/build](https://github.com/armbian/build) (Ubuntu 24.04 noble).
Une image **persistante** par carte, @BUREAU@.

| Image | Carte |
|---|---|
| `osmo-operator-rpi4b*.img.zst` | Raspberry Pi 4 |
| `osmo-operator-orangepi5*.img.zst` | Orange Pi 5 |
| `osmo-operator-orangepi5b*.img.zst` | Orange Pi 5B (noyau edge) |
| `osmo-operator-orangepi5-plus*.img.zst` | Orange Pi 5 Plus |
| `osmo-operator-orangepi5pro*.img.zst` | Orange Pi 5 Pro |
| `osmo-operator-orangepi5-max*.img.zst` | Orange Pi 5 Max |
| `osmo-operator-orangepi5-ultra*.img.zst` | Orange Pi 5 Ultra |

### Graver

```bash
zstd -dc osmo-operator-<carte>.img.zst \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Au premier demarrage Armbian etend la racine a la taille de la carte.
Comptes : `root:osmo`, `osmocom:osmo`.

### Verifier

`SHA256SUMS-arm64` porte sur l'image **brute** : `zstd -d <image>.zst && sha256sum -c SHA256SUMS-arm64 --ignore-missing`.
Ce qui depasse 2 Gio est decoupe (`PARTS-arm64.sha256`) : `cat <image>.zst.part-* > <image>.zst`.

### Ce que ces images n'ont pas

Pas de 4G (srsRAN et Open5GS ne sont pas compiles pour aarch64).
La 2G/EDGE est entiere.
