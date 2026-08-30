# ── INTER-STP ────────────────────────────────────────────────────────────────
sudo docker exec -it osmo-inter-stp telnet 127.0.0.1 4239
# show cs7 instance 0 asp
# show cs7 instance 0 as
# show cs7 instance 0 route

# ── OPERATEUR 1 - STP intra ──────────────────────────────────────────────────
sudo docker exec -it osmo-operator-1 telnet 127.0.0.1 4239
# show cs7 instance 0 asp
# show cs7 instance 0 as
# show cs7 instance 0 sccp users
# show cs7 instance 0 sccp connections

# ── OPERATEUR 1 - MSC ────────────────────────────────────────────────────────
sudo docker exec -it osmo-operator-1 telnet 127.0.0.1 4254
# en
# show cs7 instance 0 asp
# show cs7 instance 0 sccp users
# show cs7 instance 0 sccp connections
# show subscriber all
# show connection all

# ── OPERATEUR 1 - BSC ────────────────────────────────────────────────────────
sudo docker exec -it osmo-operator-1 telnet 127.0.0.1 4242
# en
# show cs7 instance 0 asp
# show cs7 instance 0 sccp users
# show cs7 instance 0 sccp connections
# show bts 0
# show trx 0 0

# ── OPERATEUR 2 - meme chose ──────────────────────────────────────────────────
sudo docker exec -it osmo-operator-2 telnet 127.0.0.1 4239
sudo docker exec -it osmo-operator-2 telnet 127.0.0.1 4254
sudo docker exec -it osmo-operator-2 telnet 127.0.0.1 4242

# ── ONE-LINER : dump tout sans interaction ────────────────────────────────────
for container in osmo-operator-1 osmo-operator-2; do
    echo "=== $container STP ==="
    sudo docker exec $container sh -c \
        'echo -e "show cs7 instance 0 asp\nshow cs7 instance 0 sccp users\nshow cs7 instance 0 sccp connections\n" | telnet 127.0.0.1 4239 2>/dev/null' \
        | grep -v "^Trying\|^Connected\|^Escape"

    echo "=== $container MSC ==="
    sudo docker exec $container sh -c \
        'echo -e "enable\nshow cs7 instance 0 sccp users\nshow cs7 instance 0 sccp connections\nshow subscriber all\n" | telnet 127.0.0.1 4254 2>/dev/null' \
        | grep -v "^Trying\|^Connected\|^Escape"
done

echo "=== inter-STP ASP ==="
sudo docker exec osmo-inter-stp sh -c \
    'echo -e "show cs7 instance 0 asp\nshow cs7 instance 0 as\n" | telnet 127.0.0.1 4239 2>/dev/null' \
    | grep -v "^Trying\|^Connected\|^Escape"
