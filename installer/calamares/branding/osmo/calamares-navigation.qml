/* calamares-navigation.qml - the osmo-operator installer buttons, Ubuntu style.
 *
 * Loaded because branding.desc says « navigation: qml »: a light band at the
 * bottom, « Quitter » on the left, « Retour » and « Suivant / Installer » on
 * the right; the forward button is the filled one (Yaru-blue accent).
 * Labels and states come from ViewManager (translated by Calamares).
 */
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.3
import QtQuick.Layouts 1.3

Rectangle {
    id: pied
    // Calamares sizes a top/bottom QML panel from the root's implicit height
    implicitHeight: 64
    height: 64
    width: parent ? parent.width : 1024
    color: "#fafafa"

    readonly property color accent: "#208fe9"
    readonly property color accentFonce: "#1a74bd"

    // a flat Ubuntu-like button, without QtQuick.Controls (style-free)
    component Bouton: Rectangle {
        id: b
        property string texte: ""
        property bool plein: false
        signal clique()
        implicitWidth: Math.max(110, label.implicitWidth + 36)
        implicitHeight: 36
        radius: 6
        opacity: enabled ? 1.0 : 0.45
        color: plein ? (zone.pressed ? pied.accentFonce : pied.accent)
                     : (zone.pressed ? "#dcdcdc" : (zone.containsMouse ? "#ececec" : "#f2f2f2"))
        border.width: plein ? 0 : 1
        border.color: "#cfcfcf"
        Text {
            id: label
            anchors.centerIn: parent
            text: b.texte.replace("&", "")
            color: b.plein ? "#ffffff" : "#2c2c2c"
            font.pixelSize: 14
            font.bold: b.plein
        }
        MouseArea {
            id: zone
            anchors.fill: parent
            hoverEnabled: true
            enabled: b.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: b.clique()
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: "#e3e3e3"
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        spacing: 10

        Bouton {
            texte: ViewManager.quitLabel
            visible: ViewManager.quitVisible
            enabled: ViewManager.quitEnabled
            onClique: ViewManager.quit()
        }
        Item { Layout.fillWidth: true }
        Bouton {
            texte: ViewManager.backLabel
            visible: ViewManager.backAndNextVisible
            enabled: ViewManager.backEnabled
            onClique: ViewManager.back()
        }
        Bouton {
            texte: ViewManager.nextLabel
            plein: true
            visible: ViewManager.backAndNextVisible
            enabled: ViewManager.nextEnabled
            onClique: ViewManager.next()
        }
    }
}
