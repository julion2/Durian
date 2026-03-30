import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: row
    height: 84

    // Auto-injected by ListView from model role names
    required property int index
    required property string subject
    required property string sender
    required property string preview
    required property string initial
    property bool selected: false
    signal clicked()

    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: 8
        color: row.selected ? "#ede7f6" : (mouseArea.containsMouse ? "#f8f5fc" : "#ffffff")
        border.color: row.selected ? "#d8ccef" : "#e6e6e6"
        border.width: 1

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: row.clicked()
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10

            Rectangle {
                width: 32
                height: 32
                radius: 16
                color: "#f0f0f0"

                Label {
                    anchors.centerIn: parent
                    text: row.initial
                    font.weight: Font.DemiBold
                    color: "#333333"
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4

                Label {
                    text: row.sender
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    color: "#111111"
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Label {
                    text: row.subject || "(No Subject)"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: "#222222"
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Label {
                    text: row.preview
                    font.pixelSize: 11
                    color: "#666666"
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }
    }
}
