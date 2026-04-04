import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: threadList

    property alias model: listView.model
    property alias currentIndex: listView.currentIndex
    property bool searchMode: false
    property string searchTerm: ""
    signal threadSelected(int index)

    onCurrentIndexChanged: {
        if (listView.currentIndex >= 0)
            listView.positionViewAtIndex(listView.currentIndex, ListView.Contain)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        // Search banner or folder title
        Rectangle {
            Layout.fillWidth: true
            height: searchBannerCol.implicitHeight + 12
            radius: 8
            color: searchMode ? "#f3f0ff" : "transparent"
            visible: searchMode

            RowLayout {
                id: searchBannerCol
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                Label {
                    text: "\uE8B6"
                    font.family: "Material Symbols Outlined"
                    font.pixelSize: 16
                    color: "#7c5cbf"
                }
                Label {
                    text: "\"" + threadList.searchTerm + "\""
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    color: "#5e35b1"
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Label {
                    text: "Esc to close"
                    font.pixelSize: 10
                    color: "#999999"
                }
            }
        }

        Label {
            text: "Inbox"
            font.pixelSize: 15
            font.bold: true
            visible: !searchMode
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
