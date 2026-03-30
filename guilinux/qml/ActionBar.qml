import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: toolbar
    color: "#ffffff"
    height: 40

    signal composeClicked()
    signal replyClicked()
    signal replyAllClicked()
    signal forwardClicked()
    signal deleteClicked()
    signal pinClicked()
    signal searchClicked()
    signal syncClicked()

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 2

        // Left: app name
        Label {
            text: "Durian"
            font.pixelSize: 13
            font.weight: Font.DemiBold
            color: "#666666"
        }

        Item { Layout.fillWidth: true }

        // Center: email actions
        IconButton {
            icon_code: "\uE150"
            tooltip: "Compose"
            onClicked: toolbar.composeClicked()
        }

        Separator {}

        IconButton {
            icon_code: "\uE15E"
            tooltip: "Reply"
            onClicked: toolbar.replyClicked()
        }
        IconButton {
            icon_code: "\uE15F"
            tooltip: "Reply All"
            onClicked: toolbar.replyAllClicked()
        }
        IconButton {
            icon_code: "\uE5C8"
            tooltip: "Forward"
            onClicked: toolbar.forwardClicked()
        }

        Separator {}

        IconButton {
            icon_code: "\uE872"
            tooltip: "Delete"
            onClicked: toolbar.deleteClicked()
        }
        IconButton {
            icon_code: "\uF10D"
            tooltip: "Pin"
            onClicked: toolbar.pinClicked()
        }

        Item { Layout.fillWidth: true }

        // Right: search + sync
        IconButton {
            icon_code: "\uE8B6"
            tooltip: "Search"
            onClicked: toolbar.searchClicked()
        }
        IconButton {
            icon_code: "\uE627"
            tooltip: "Sync"
            onClicked: toolbar.syncClicked()
        }
    }

    // Bottom border
    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: "#e0e0e0"
    }

    // Reusable icon button
    component IconButton: AbstractButton {
        id: btn
        property string icon_code
        property string tooltip
        implicitWidth: 32
        implicitHeight: 32

        ToolTip.visible: hovered && tooltip.length > 0
        ToolTip.text: tooltip
        ToolTip.delay: 500

        contentItem: Label {
            text: btn.icon_code
            font.family: "Material Symbols Outlined"
            font.pixelSize: 20
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: btn.hovered ? "#333333" : "#666666"
        }

        background: Rectangle {
            radius: 6
            color: btn.pressed ? "#e8e8e8" : (btn.hovered ? "#f2f2f2" : "transparent")
        }
    }

    // Thin vertical separator
    component Separator: Rectangle {
        Layout.preferredWidth: 1
        Layout.preferredHeight: 20
        Layout.leftMargin: 6
        Layout.rightMargin: 6
        color: "#e0e0e0"
    }
}
