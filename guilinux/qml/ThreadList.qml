import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: threadList

    property alias model: listView.model
    property alias currentIndex: listView.currentIndex
    signal threadSelected(int index)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        Label {
            text: "Inbox"
            font.pixelSize: 15
            font.bold: true
        }

        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6
            clip: true

            delegate: ThreadRow {
                width: listView.width
                selected: listView.currentIndex === index
                onClicked: {
                    listView.currentIndex = index
                    threadList.threadSelected(index)
                }
            }
        }
    }
}
