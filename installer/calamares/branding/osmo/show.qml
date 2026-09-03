import QtQuick 2.0;
import calamares.slideshow 1.0;

// Le diaporama pendant la copie. Deux captures du banc en marche
// (slide-banc.png : le bureau, le tableau de bord et tmux ; slide-calypso-gdb.png :
// gdb attache au firmware Calypso emule) entre trois diapos de texte.
// [2026-09-03] Plus de compte osmocom sur le disque : la diapo "comptes" dit
// ce que l installation fait vraiment (voir modules/shellprocess-osmo.conf).
Presentation {
    id: presentation
    Timer {
        interval: 8000
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
            text: "osmo-operator — banc GSM / EGPRS complet\n\n" +
                  "BTS, BSC, MSC, HLR, SGSN, GGSN, STP et Asterisk,\n" +
                  "avec l'emulation Calypso du telephone."
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
            font.pixelSize: 20
            color: "#13293d"
            text: "Vos comptes\n\n" +
                  "L'utilisateur que vous venez de creer ouvre la session\n" +
                  "(sudoer : il pilote le banc avec sudo).\n" +
                  "root — le compte de travail, deverrouille,\n" +
                  "avec le mot de passe demande a l'installation.\n\n" +
                  "Le compte osmocom de la cle live n'est pas installe."
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
            font.pixelSize: 20
            color: "#13293d"
            text: "Pour demarrer le banc\n\n" +
                  "    sudo -i\n    ./start-direct.sh\n\n" +
                  "Le tableau de bord web ecoute deja sur cette machine."
        }
    }
}
