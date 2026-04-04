import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Durian 1.0

ApplicationWindow {
    id: root
    visible: true
    width: 1100
    height: 720
    title: ""
    color: "#fafafa"

    property int selectedThread: -1

    FontLoader {
        id: materialIcons
        source: "qrc:/fonts/MaterialSymbolsOutlined.ttf"
    }

    ThreadModel {
        id: threadModel
    }

    ProfileModel {
        id: profileModel
        Component.onCompleted: load()
    }

    NetworkClient {
        id: network
        onSearchResults: function(results) {
            threadModel.loadFromJson(results)
            root.selectedThread = threadModel.rowCount() > 0 ? 0 : -1
        }
    }

    // Download feedback toast
    Connections {
        target: network
        function onDownloadComplete(filename, path) {
            toastLabel.text = "\u2713 " + filename
            toastRect.visible = true
            toastTimer.restart()
        }
        function onDownloadError(filename, error) {
            toastLabel.text = "\u2717 " + filename + ": " + error
            toastRect.visible = true
            toastTimer.restart()
        }
    }

    Rectangle {
        id: toastRect
        visible: false
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 16
        width: toastLabel.implicitWidth + 24
        height: 32
        radius: 8
        color: "#333333"
        z: 100
        Label {
            id: toastLabel
            anchors.centerIn: parent
            color: "#ffffff"
            font.pixelSize: 12
        }
        Timer {
            id: toastTimer
            interval: 3000
            onTriggered: toastRect.visible = false
        }
    }

    // Load first folder when profile changes
    Connections {
        target: profileModel
        function onCurrentProfileChanged() {
            sidebar.resetFolder()
            var folders = profileModel.folders
            if (folders.length > 0) {
                root.selectedThread = -1
                var filtered = profileModel.applyProfileFilter(folders[0].query)
                root.lastFolderQuery = filtered
                root.inSearchMode = false
                network.search(filtered)
                root.reclaim()
            }
        }
    }

    Component.onCompleted: keyHandler.forceActiveFocus()
    function reclaim() { keyHandler.forceActiveFocus() }

    // Vim keybindings
    KeyHandler {
        id: keyHandler
        anchors.fill: parent
        threadList: threadListView
        sidebar: sidebar
        detailView: detailViewRef
        threadCount: threadModel.count
        onNavigateToThread: function(index) {
            root.selectedThread = index
        }
        onRequestSearch: searchPopup.open()
        onExitSearch: {
            if (root.inSearchMode) {
                root.inSearchMode = false
                // Reload current folder
                if (root.lastFolderQuery)
                    network.search(root.lastFolderQuery)
            }
        }
    }

    // Full vertical layout: toolbar on top, content below
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ActionBar {
            Layout.fillWidth: true
        }

        // Content area: sidebar + list + detail
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Main content: thread list + detail
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: sidebarContainer.width
                spacing: 0

                ThreadList {
                    id: threadListView
                    Layout.preferredWidth: 360
                    Layout.minimumWidth: 200
                    Layout.fillHeight: true
                    model: threadModel
                    currentIndex: root.selectedThread
                    searchMode: root.inSearchMode
                    searchTerm: searchPopup.lastQuery
                    onThreadSelected: function(index) {
                        root.selectedThread = index
                        root.reclaim()
                    }
                }

                Rectangle {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 1
                    color: "#e0e0e0"
                }

                DetailView {
                    id: detailViewRef
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 300
                    threadModel: threadModel
                    networkClient: network
                    profileModel: profileModel
                    currentIndex: root.selectedThread
                    active: keyHandler.threadFocused
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
                        profileModel: profileModel
                        onFolderSelected: function(query) {
                            var filtered = profileModel.applyProfileFilter(query)
                            root.lastFolderQuery = filtered
                            root.inSearchMode = false
                            network.search(filtered)
                            root.reclaim()
                        }
                    }
                }

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
    }

    property string lastFolderQuery: ""

    SearchPopup {
        id: searchPopup
        networkClient: network
        profileModel: profileModel
        onResultSelected: function(threadId, subject) {
            // Load search results into thread list
            var searchResults = searchPopup.results
            var arr = []
            for (var i = 0; i < searchResults.length; i++) {
                arr.push(searchResults[i])
            }
            threadModel.loadFromJson(arr)
            // Select the clicked result
            for (var j = 0; j < threadModel.count; j++) {
                if (threadModel.threadId(j) === threadId) {
                    root.selectedThread = j
                    break
                }
            }
            root.inSearchMode = true
        }
    }

    // Track search mode for Esc-to-return
    property bool inSearchMode: false
}
