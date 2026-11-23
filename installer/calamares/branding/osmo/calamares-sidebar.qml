/* calamares-sidebar.qml - the osmo-operator installer header, Ubuntu style.
 *
 * Loaded because branding.desc says « sidebar: qml,top »: instead of the dark
 * column of steps on the left, a light band ON TOP with the product name, the
 * name of the current step, and one dot per step (filled up to the current
 * one) - the look of the Ubuntu desktop installer. Colours: Yaru-blue, the
 * accent of the installed desktop (light mode).
 *
 * API (Calamares 3.3): ViewManager is the model of the steps (role
 * « display » = step name) and gives currentStepIndex; Branding gives the
 * strings. Debug: a click on the title opens the debug window when
 * Calamares runs with -d.
 */
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.3
import QtQuick.Layouts 1.3

Rectangle {
    id: entete
    // Calamares sizes a top/bottom QML panel from the root's implicit height
    implicitHeight: 60
    height: 60
    width: parent ? parent.width : 1024
    color: "#fafafa"

    readonly property color accent: "#208fe9"      // Yaru-blue
    readonly property color texte: "#2c2c2c"
    readonly property color gris: "#c9c9c9"
    property string etape: ""

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 28
        anchors.rightMargin: 28
        spacing: 18

        Text {
            text: Branding.string(Branding.ProductName)
            color: entete.texte
            font.pixelSize: 17
            font.bold: true
            Layout.alignment: Qt.AlignVCenter
            MouseArea {
                anchors.fill: parent
                enabled: debug.enabled
                onClicked: debug.toggle()
            }
        }
        Text {
            text: entete.etape
            color: "#6a6a6a"
            font.pixelSize: 15
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
        }
        Row {
            spacing: 8
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
            Repeater {
                model: ViewManager
                Rectangle {
                    readonly property bool courant: index == ViewManager.currentStepIndex
                    width: courant ? 22 : 9
                    height: 9
                    radius: 4.5
                    color: index <= ViewManager.currentStepIndex ? entete.accent : entete.gris
                    Behavior on width { NumberAnimation { duration: 150 } }
                    // the delegate knows the step name: hand it to the header
                    onCourantChanged: if (courant) entete.etape = display
                    Component.onCompleted: if (courant) entete.etape = display
                }
            }
        }
    }
    // the thin line under the header, as in the Ubuntu installer
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: "#e3e3e3"
    }
}
