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

            model: [
                { name: "Inbox",   icon: "\uE156" },
                { name: "Pinned",  icon: "\uF10D" },
                { name: "Archive", icon: "\uE149" },
                { name: "Sent",    icon: "\uE163" },
                { name: "Drafts",  icon: "\uE66D" },
                { name: "Trash",   icon: "\uE872" },
            ]

            delegate: ItemDelegate {
                required property int index
                required property var modelData
                width: tagList.width
                padding: 4
                topPadding: 4
                bottomPadding: 4
                highlighted: tagList.currentIndex === index

                onClicked: tagList.currentIndex = index

                contentItem: RowLayout {
                    spacing: 8
                    Label {
                        text: modelData.icon
                        font.family: "Material Symbols Outlined"
                        font.pixelSize: 20
                        Layout.preferredWidth: 24
                        horizontalAlignment: Text.AlignHCenter
                        color: highlighted ? "#5e35b1" : "#888888"
                    }
                    Label {
                        text: modelData.name
                        font.pixelSize: 13
                        color: "#111111"
                        Layout.fillWidth: true
                    }
                }

                background: Rectangle {
                    color: highlighted ? "#ede7f6" : (hovered ? "#f5f5f5" : "transparent")
                    radius: 6
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
