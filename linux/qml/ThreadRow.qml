import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: row
    implicitHeight: innerCol.implicitHeight + 24

    // Auto-injected by ListView from model role names
    required property int index
    required property string subject
    required property string sender
    required property string preview
    required property string initial
    required property string fromRaw
    required property string date
    required property string tags
    required property bool hasAttachment
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

            Avatar {
                from: row.fromRaw
                size: 32
            }

            ColumnLayout {
                id: innerCol
                Layout.fillWidth: true
                spacing: 3

                // Sender + date
                RowLayout {
                    Layout.fillWidth: true
                    Label {
                        text: "\uF10D"
                        font.family: "Material Symbols Outlined"
                        font.pixelSize: 14
                        color: "#f0a030"
                        visible: row.tags.indexOf("flagged") >= 0
                    }
                    Label {
                        text: row.sender
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: "#111111"
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Label {
                        text: row.date
                        font.pixelSize: 11
                        color: "#999999"
                    }
                }

                // Subject
                Label {
                    text: row.subject || "(No Subject)"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: "#222222"
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                // Preview
                Label {
                    text: row.preview
                    font.pixelSize: 11
                    color: "#666666"
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    Layout.fillWidth: true
                    visible: row.preview.length > 0
                }

                // Tags
                Flow {
                    Layout.fillWidth: true
                    spacing: 4
                    visible: tagRepeater.count > 0
                    Repeater {
                        id: tagRepeater
                        model: row.tags ? row.tags.split(",").filter(t => !["inbox","sent","draft","unread","archive","trash","spam"].includes(t.trim())).slice(0, 3) : []
                        delegate: Rectangle {
                            required property string modelData
                            height: 16
                            width: tagLabel.width + 10
                            radius: 8
                            color: "#f0ecf9"
                            Label {
                                id: tagLabel
                                anchors.centerIn: parent
                                text: modelData.trim()
                                font.pixelSize: 9
                                color: "#7c5cbf"
                            }
                        }
                    }
                }
            }
        }
    }
}
