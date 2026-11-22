import QtQuick 2.0;
import calamares.slideshow 1.0;

// show.qml - Calamares slideshow shown while the system is being copied.
// Screenshots of the running bench (slide-banc.png: desktop, dashboard and
// tmux; slide-calypso-gdb.png: gdb attached to the emulated Calypso firmware)
// and the pictures of the talk (slide-c1xx.jpg, slide-magnetite-boot.png,
// slide-qemu-boot.png, slide-appel.png, slide-iq-appel.png, slide-grgsm.png,
// slide-dsp-rom.png: the demos, on a dark background with a caption) between
// text slides that summarise the image release notes
// (osmo-operator-desktop.iso v0.1-9, .github/release-notes.md): what the
// machine is receiving, component by component. Update at every tag.
// The "accounts" slide describes what the installation really does
// (see modules/shellprocess-osmo.conf): no osmocom account on the disk.
Presentation {
    id: presentation
    Timer {
        interval: 9000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }
    // Live desktop wallpaper, copied to welcome.jpg by iso_modules/85-installeur-bureau.sh.
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
        Rectangle { anchors.fill: parent; color: "#0d1b2a" }
        Image {
            anchors.fill: parent
            anchors.margins: 12
            anchors.bottomMargin: 44
            source: "slide-c1xx.jpg"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#e0f2ff"
            text: "Un Motorola C1xx et osmocom-bb : le telephone que le banc emule, de l'ARM jusqu'au DSP"
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
        Rectangle { anchors.fill: parent; color: "#0d1b2a" }
        Image {
            anchors.fill: parent
            anchors.margins: 12
            anchors.bottomMargin: 44
            source: "slide-magnetite-boot.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#e0f2ff"
            text: "Le C123 emule demarre le firmware TI (FreeCalypso Magnetite) sous QEMU"
        }
    }
    Slide {
        Rectangle { anchors.fill: parent; color: "#0d1b2a" }
        Image {
            anchors.fill: parent
            anchors.margins: 12
            anchors.bottomMargin: 44
            source: "slide-qemu-boot.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#e0f2ff"
            text: "QEMU Calypso : loader, pont TRX, puis OsmocomBB Hello World"
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
        Rectangle { anchors.fill: parent; color: "#0d1b2a" }
        Image {
            anchors.fill: parent
            anchors.margins: 12
            anchors.bottomMargin: 44
            source: "slide-appel.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#e0f2ff"
            text: "SMS recu par le mobile, puis appel au 600 (echo Asterisk)"
        }
    }
    Slide {
        Rectangle { anchors.fill: parent; color: "#0d1b2a" }
        Image {
            anchors.fill: parent
            anchors.margins: 12
            anchors.bottomMargin: 44
            source: "slide-iq-appel.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#e0f2ff"
            text: "I/Q en direct pendant l'appel : spectre, waterfalls montant et descendant, puissance par timeslot"
        }
    }
    Slide {
        Rectangle { anchors.fill: parent; color: "#0d1b2a" }
        Image {
            anchors.fill: parent
            anchors.margins: 12
            anchors.bottomMargin: 44
            source: "slide-grgsm.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#e0f2ff"
            text: "gr-gsm decode la voie descendante enregistree par le pont"
        }
    }
    Slide {
        Rectangle { anchors.fill: parent; color: "#0d1b2a" }
        Image {
            anchors.fill: parent
            anchors.margins: 12
            anchors.bottomMargin: 44
            source: "slide-dsp-rom.png"
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#e0f2ff"
            text: "Le DSP C54x arrete dans la ROM TI : registres, vecteurs armes, desassemblage"
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
