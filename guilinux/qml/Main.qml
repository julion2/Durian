import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Durian 1.0

ApplicationWindow {
    id: root
    visible: true
    width: 1100
    height: 720
    title: "Durian"
    color: "#fafafa"

    property int selectedThread: -1

    ThreadModel {
        id: threadModel
        Component.onCompleted: loadSeedData()
    }

    // Main content: thread list + detail, side by side
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: sidebarContainer.width
        spacing: 0

        ThreadList {
            Layout.preferredWidth: 360
            Layout.minimumWidth: 200
            Layout.fillHeight: true
            model: threadModel
            currentIndex: root.selectedThread
            onThreadSelected: function(index) {
                root.selectedThread = index
            }
        }

        // Thin separator
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            color: "#e0e0e0"
        }

        DetailView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: 300
            threadModel: threadModel
            currentIndex: root.selectedThread
        }
    }

    // Sidebar floats on top with shadow
    Item {
        id: sidebarContainer
        width: sidebar.collapsed ? 36 : 180
        height: parent.height
        z: 10

        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        Rectangle {
            id: sidebarBg
            anchors.fill: parent
            color: "#ffffff"

            Sidebar {
                id: sidebar
                anchors.fill: parent
            }
        }

        // Shadow on the right edge
        Rectangle {
            anchors.left: sidebarBg.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 6
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#18000000" }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
    }
}
