import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: sidebar

    property bool collapsed: false

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: collapsed ? 6 : 10
        spacing: 8

        RowLayout {
            spacing: 8

            ToolButton {
                text: "\u2261"
                font.pixelSize: 18
                font.bold: true
                onClicked: sidebar.collapsed = !sidebar.collapsed
                background: Rectangle {
                    color: parent.hovered ? "#f2f2f2" : "transparent"
                    radius: 6
                }
                implicitWidth: 28
                implicitHeight: 28
            }

            Label {
                text: "Tags"
                font.pixelSize: 13
                font.bold: true
                visible: !sidebar.collapsed
            }

            Item { Layout.fillWidth: true }
        }

        ListView {
            id: tagList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !sidebar.collapsed
            spacing: 4
            clip: true
            currentIndex: 0

            model: ["Inbox", "Pinned", "Archive", "Sent", "Drafts", "Trash"]

            delegate: ItemDelegate {
                required property int index
                required property string modelData
                width: tagList.width
                text: modelData
                highlighted: tagList.currentIndex === index

                onClicked: tagList.currentIndex = index

                background: Rectangle {
                    color: highlighted ? "#ede7f6" : (hovered ? "#f5f5f5" : "transparent")
                    radius: 6
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
