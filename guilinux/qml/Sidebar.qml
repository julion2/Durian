import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: sidebar

    property bool collapsed: false
    property var profileModel: null
    signal folderSelected(string query)

    function resetFolder() {
        tagList.currentIndex = 0
    }

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

        // Profile switcher
        AbstractButton {
            id: profileButton
            Layout.fillWidth: true
            visible: !sidebar.collapsed
            implicitHeight: 30

            property string currentName: {
                var profiles = profileModel ? profileModel.profiles : []
                var idx = profileModel ? profileModel.currentProfile : 0
                return profiles[idx] ? profiles[idx].name : ""
            }

            onClicked: profilePopup.visible ? profilePopup.close() : profilePopup.open()

            leftPadding: 8
            rightPadding: 8

            contentItem: RowLayout {
                spacing: 4
                Label {
                    text: profileButton.currentName
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    color: "#333333"
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Label {
                    text: "\u25BE"
                    font.pixelSize: 10
                    color: "#999999"
                }
            }

            background: Rectangle {
                color: profileButton.hovered ? "#f0f0f0" : "#f7f7f7"
                radius: 6
                border.color: profileButton.hovered ? "#d0d0d0" : "#e8e8e8"
                border.width: 1
            }

            Popup {
                id: profilePopup
                y: profileButton.height + 4
                width: profileButton.width
                implicitHeight: Math.min(col.height + 8, 300)
                padding: 4

                background: Rectangle {
                    color: "#ffffff"
                    radius: 8
                    border.color: "#e0e0e0"
                    border.width: 1
                }

                contentItem: Flickable {
                    contentWidth: width
                    contentHeight: col.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: col
                        width: parent.width
                        spacing: 2

                        Repeater {
                            model: profileModel ? profileModel.profiles : []
                            delegate: AbstractButton {
                                required property int index
                                required property var modelData
                                width: col.width
                                height: 28
                                onClicked: {
                                    if (profileModel) profileModel.currentProfile = index
                                    profilePopup.close()
                                }

                                contentItem: Label {
                                    text: modelData.name
                                    font.pixelSize: 12
                                    font.weight: index === (profileModel ? profileModel.currentProfile : -1)
                                        ? Font.DemiBold : Font.Normal
                                    color: index === (profileModel ? profileModel.currentProfile : -1)
                                        ? "#5e35b1" : "#333333"
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: 8
                                }

                                background: Rectangle {
                                    color: index === (profileModel ? profileModel.currentProfile : -1)
                                        ? "#ede7f6"
                                        : (parent.hovered ? "#f5f5f5" : "transparent")
                                    radius: 6
                                }
                            }
                        }
                    }
                }
            }
        }

        // Folder list from profile
        ListView {
            id: tagList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !sidebar.collapsed
            spacing: 4
            clip: true
            currentIndex: 0

            model: profileModel ? profileModel.folders : []

            delegate: ItemDelegate {
                required property int index
                required property var modelData
                width: tagList.width
                padding: 4
                topPadding: 4
                bottomPadding: 4
                highlighted: tagList.currentIndex === index

                onClicked: {
                    tagList.currentIndex = index
                    sidebar.folderSelected(modelData.query)
                }

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
    }
}
