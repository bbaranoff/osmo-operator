import QtQuick 2.0;
import calamares.slideshow 1.0;

// Le diaporama pendant la copie. Deux captures du banc en marche
// (slide-banc.png : le bureau, le tableau de bord et tmux ; slide-calypso-gdb.png :
// gdb attache au firmware Calypso emule) entre des diapos de texte qui
// reprennent la fiche de l image (osmo-operator-desktop.iso v0.1-9) : ce que
// la machine est en train de recevoir, poste par poste.
// [2026-09-03] Plus de compte osmocom sur le disque : la diapo "comptes" dit
// ce que l installation fait vraiment (voir modules/shellprocess-osmo.conf).
// [2026-10-01] Fiche v0.1-6 : base, taille, 2G, baseband, 4G, telephone,
// bureau, audio, installation. A refaire a chaque tag.
// [2026-10-24] Fiche v0.1-9 (.github/release-notes.md) : BTS classique par
// defaut, Magnetite, Calypso en radio de BTS, banc-rssi, vocodeur, rien de
// telecom au boot, start.sh. Taille et fichiers non remesures : retires.
Presentation {
    id: presentation
    Timer {
        interval: 9000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }
    // Le fond du bureau live, copie en welcome.jpg par iso_modules/85-installeur-bureau.sh.
    Slide {
        Image {
            anchors.fill: parent
            anchors.margins: 12
            source: "welcome.jpg"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 20
            color: "#13293d"
            text: "osmo-operator-desktop.iso  v0.1-9\n\n" +
                  "Un operateur GSM + LTE complet, sans SDR ni telephone :\n" +
                  "la radio est emulee de bout en bout, jusqu'a la bande de base.\n" +
                  "L'ARM du Calypso tourne sous QEMU (qosmo),\n" +
                  "son DSP C54x execute la vraie ROM masque (c54x_exe).\n\n" +
                  "Base Ubuntu 24.04, noyau 6.8 generic\n" +
                  "ISO hybride (dd sur cle), Secure Boot shim > grub > noyau, option toram\n" +
                  "8 Go de RAM et 4 coeurs minimum"
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
                  "osmo-stp, bsc, msc, hlr, sgsn, ggsn, pcu, mgw ; 2 cellules en LAC 1,\n" +
                  "GPRS/EDGE, voix par osmo-sip-connector + Asterisk, SMS GSUP/SMPP.\n\n" +
                  "Nouveau en 0.1-9\n\n" +
                  "BTS classique par defaut : osmo-bts-trx + pont_dsp.py, layer1 + mobile sur la ROM DSP.\n" +
                  "--ms-magnetite : Motorola C139 sous FreeCalypso Magnetite (firmware TI).\n" +
                  "--bts : le Calypso devient la radio de la BTS ; --ts 1 | 2 | 2/1.\n" +
                  "banc-rssi : l'appli rssi d'osmocom-bb sur un quatrieme Calypso.\n" +
                  "Voix : --vocoder-rom (FR de la ROM, defaut) ou --gapk (hote)."
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
                  "Open5GS + srsRAN sur ZMQ, PLMN 001/01, chiffrement NAS nul pour l'analyse,\n" +
                  "CSFB par SGs entre la MME et osmo-msc.\n\n" +
                  "Telephone\n\n" +
                  "VM postmarketOS : data en 4G, voix et SMS en 2G sous une seule identite,\n" +
                  "oFono sur un modem AT virtuel - code de deverrouillage 147147."
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 19
            color: "#13293d"
            text: "Bureau\n\n" +
                  "GNOME, Firefox (deb Mozilla), Wireshark, Linphone (poste 100), Conky.\n" +
                  "Le ? du dock ouvre l'aide : modes, modules, notebooks, depots.\n" +
                  "Reglages de toute la pile : http://127.0.0.1:8090\n" +
                  "Nouvel ecran de demarrage Plymouth : une antenne et ses cercles.\n\n" +
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
                  "Rien de telecom ne demarre au boot (preset 80-osmo-operator) :\n" +
                  "banc, coeur Osmocom, BTS, Asterisk, oFono, Open5GS et srsRAN vous attendent."
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 20
            color: "#13293d"
            text: "Pour demarrer le banc\n\n" +
                  "    cd /opt/GSM/osmo-operator\n" +
                  "    sudo ./start.sh --bts-classique --ms\n\n" +
                  "(ou le telephone rouge du dock ; sudo ./start.sh --help pour les autres modes)\n" +
                  "Le tableau de bord web ecoute deja sur cette machine."
        }
    }
}
