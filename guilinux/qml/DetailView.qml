import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: detailView

    property var threadModel: null
    property int currentIndex: -1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Label {
            text: currentIndex >= 0 ? threadModel.subject(currentIndex) : "Select a thread"
            font.pixelSize: 18
            font.bold: true
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        Label {
            text: currentIndex >= 0
                ? threadModel.sender(currentIndex) + "  \u00b7  " + Qt.formatDateTime(new Date(), "MMM d, h:mm AP")
                : "\u2014"
            color: "#666666"
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            TextArea {
                readOnly: true
                wrapMode: TextEdit.Wrap
                text: currentIndex >= 0
                    ? threadModel.preview(currentIndex) + "\n\nLorem ipsum placeholder body content."
                    : "\u2014"
                padding: 10

                background: Rectangle {
                    color: "#ffffff"
                    border.color: "#e6e6e6"
                    border.width: 1
                    radius: 10
                }
            }
        }
    }
}
