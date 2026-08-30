import QtQuick 2.0;
import calamares.slideshow 1.0;

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
            text: "osmo_egprs — banc GSM / EGPRS complet\n\n" +
                  "BTS, BSC, MSC, HLR, SGSN, GGSN, STP et Asterisk,\n" +
                  "avec l'emulation Calypso du telephone."
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 20
            color: "#13293d"
            text: "Deux comptes\n\n" +
                  "root — le compte de travail, la session s'y ouvre seule.\n" +
                  "osmocom — second compte, non privilegie, sudoer.\n\n" +
                  "Mot de passe des deux : osmo"
        }
    }
    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 20
            color: "#13293d"
            text: "Pour demarrer le banc\n\n" +
                  "    cd /opt/GSM/osmo_egprs && ./start-direct.sh\n\n" +
                  "Le tableau de bord web ecoute deja sur cette machine."
        }
    }
}
