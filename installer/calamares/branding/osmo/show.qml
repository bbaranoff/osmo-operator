import QtQuick 2.0;
import calamares.slideshow 1.0;

// Le diaporama pendant la copie. Deux captures du banc en marche
// (slide-banc.png : le bureau, le tableau de bord et tmux ; slide-calypso-gdb.png :
// gdb attache au firmware Calypso emule) entre des diapos de texte qui
// reprennent la fiche de l image (osmo-operator-desktop.iso v0.1-6) : ce que
// la machine est en train de recevoir, poste par poste.
// [2026-09-03] Plus de compte osmocom sur le disque : la diapo "comptes" dit
// ce que l installation fait vraiment (voir modules/shellprocess-osmo.conf).
// [2026-10-01] Fiche v0.1-6 : base, taille, 2G, baseband, 4G, telephone,
// bureau, audio, installation. A refaire a chaque tag.
Presentation {
    id: presentation
    Timer {
        interval: 9000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 20
            color: "#13293d"
            text: "osmo-operator-desktop.iso  v0.1-6\n\n" +
                  "Banc GSM / EGPRS complet, sans materiel :\n" +
                  "BTS, BSC, MSC, HLR, SGSN, GGSN, STP et Asterisk,\n" +
                  "avec l'emulation Calypso du telephone.\n\n" +
                  "Base Ubuntu 24.04, noyau 6.8.0-146-generic\n" +
                  "ISO 6,5 Go - squashfs 6,3 Go (zstd -19) - 314 178 fichiers\n" +
                  "ISO hybride (dd sur cle), Secure Boot shim > grub > noyau, option toram (9 Go de RAM)"
        }
    }
    Slide {
        Image {
            anchors.fill: parent
            anchors.margins: 12
            source: "slide-banc.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: 14
            color: "#13293d"
            text: "Le banc en marche : tableau de bord, mobile emule, chiffrement A5/1 au VTY"
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 19
            color: "#13293d"
            text: "2G\n\n" +
                  "Banc complet (launch.sh, osmo-banc), 2 MS, A5/1,\n" +
                  "SMS inter-operateurs, MSC avec SGs (CSFB).\n\n" +
                  "Baseband emule\n\n" +
                  "QEMU qosmo (ARM7 + DSP C54x), 7 ROMs DSP,\n" +
                  "firmware layer1 pour 10 cartes, gdb-telnet, c54x_exe, grgsm_exe."
        }
    }
    Slide {
        Image {
            anchors.fill: parent
            anchors.margins: 12
            source: "slide-calypso-gdb.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: 14
            color: "#13293d"
            text: "gdb attache au firmware Calypso (layer1) qui tourne dans QEMU"
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 19
            color: "#13293d"
            text: "4G\n\n" +
                  "srsENB / srsUE portables + srsGUI, Open5GS, freeDiameter TLS,\n" +
                  "MME SGsAP, console HSS :9999, abonnes dans Mongo.\n\n" +
                  "Telephone\n\n" +
                  "VM postmarketOS 1,7 Go (noyau PPP), pmbootstrap patche,\n" +
                  "pmaports 9479a409e3 - code de deverrouillage 147147."
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 19
            color: "#13293d"
            text: "Bureau\n\n" +
                  "GNOME minimal, Firefox 157 (deb Mozilla, fr, uBlock), Wireshark,\n" +
                  "Linphone (poste 100), Kodi, dino, ofono, Conky,\n" +
                  "Plymouth osmo-bts, tableau de bord web + tutoriel.\n\n" +
                  "Audio\n\n" +
                  "PulseAudio systeme, PipeWire pour le screencast seul,\n" +
                  "PCM gsm_out / gsm_in.\n\n" +
                  "Retire : avahi, Chromium ; sssd masque."
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 19
            color: "#13293d"
            text: "Vos comptes\n\n" +
                  "L'utilisateur que vous venez de creer ouvre la session\n" +
                  "(sudoer : il pilote le banc avec sudo).\n" +
                  "root - le compte de travail, deverrouille,\n" +
                  "avec le mot de passe demande a l'installation.\n" +
                  "Le compte osmocom de la cle live n'est pas installe.\n\n" +
                  "/home chiffre (LUKS) si vous l'avez coche : au demarrage,\n" +
                  "« decrypt /home -passphrase- or Enter » - Entree a vide demarre sans.\n" +
                  "osmo-update au boot ; osmo-banc, osmo-multi, osmo-lte poses mais non actives."
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 20
            color: "#13293d"
            text: "Pour demarrer le banc\n\n" +
                  "    sudo -i\n    ./start-direct.sh\n\n" +
                  "Le tableau de bord web ecoute deja sur cette machine."
        }
    }
}
