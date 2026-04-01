import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: searchPopup

    property var networkClient: null
    property var profileModel: null
    property var results: []
    property string lastQuery: ""

    signal resultSelected(string threadId, string subject)

    width: 680
    height: Math.min(searchCol.implicitHeight + 32, 560)
    x: (parent.width - width) / 2
    y: 80
    modal: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 16

    onOpened: {
        searchInput.text = ""
        results = []
        searchInput.forceActiveFocus()
    }
    onClosed: {
        // Return focus to main KeyHandler
        if (parent) parent.forceActiveFocus()
    }

    background: Rectangle {
        color: "#ffffff"
        radius: 16
        border.color: "#d0d0d0"
        border.width: 1

        layer.enabled: true
    }

    contentItem: ColumnLayout {
        id: searchCol
        spacing: 12

        // Search input
        RowLayout {
            spacing: 8
            Label {
                text: "\uE8B6"
                font.family: "Material Symbols Outlined"
                font.pixelSize: 20
                color: "#888888"
            }
            TextField {
                id: searchInput
                Layout.fillWidth: true
                placeholderText: "Search emails..."
                font.pixelSize: 15
                background: Rectangle { color: "transparent" }
                onTextChanged: debounceTimer.restart()

                Keys.onPressed: function(event) {
                    // Ctrl on macOS = MetaModifier, on Linux = ControlModifier
                    var ctrl = (event.modifiers & Qt.ControlModifier) || (event.modifiers & Qt.MetaModifier)
                    if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && ctrl)) {
                        if (resultList.currentIndex > 0) resultList.currentIndex--
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && ctrl)) {
                        if (resultList.currentIndex < resultList.count - 1) resultList.currentIndex++
                        event.accepted = true
                    } else if (event.key === Qt.Key_U && ctrl) {
                        resultList.currentIndex = Math.max(resultList.currentIndex - 5, 0)
                        event.accepted = true
                    } else if (event.key === Qt.Key_D && ctrl) {
                        resultList.currentIndex = Math.min(resultList.currentIndex + 5, resultList.count - 1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        selectCurrent()
                        event.accepted = true
                    }
                }
            }
        }

        // Separator
        Rectangle { Layout.fillWidth: true; height: 1; color: "#e8e8e8" }

        // Status / results
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: Math.min(resultList.contentHeight, 420)
            Layout.maximumHeight: 420

            // Loading / empty states
            Label {
                anchors.centerIn: parent
                text: debounceTimer.running ? "Searching..." :
                      (searchInput.text.length > 0 && searchPopup.results.length === 0) ? "No results" : ""
                color: "#999999"
                font.pixelSize: 13
                visible: searchPopup.results.length === 0
            }

            ListView {
                id: resultList
                anchors.fill: parent
                clip: true
                spacing: 2
                model: searchPopup.results
                currentIndex: 0

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: resultList.width
                    height: resultCol.implicitHeight + 16
                    radius: 8
                    color: resultList.currentIndex === index ? "#ede7f6" : (resultMouse.containsMouse ? "#f8f5fc" : "transparent")

                    MouseArea {
                        id: resultMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            resultList.currentIndex = index
                            selectCurrent()
                        }
                    }

                    ColumnLayout {
                        id: resultCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 10
                        spacing: 3

                        RowLayout {
                            Layout.fillWidth: true
                            Label {
                                text: parseName(modelData.from || "")
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                color: "#111111"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            Label {
                                text: modelData.date || ""
                                font.pixelSize: 11
                                color: "#999999"
                            }
                        }
                        Label {
                            text: modelData.subject || "(No Subject)"
                            font.pixelSize: 12
                            color: "#333333"
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                        Label {
                            text: (modelData.preview || "").substring(0, 120)
                            font.pixelSize: 11
                            color: "#888888"
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            visible: (modelData.preview || "").length > 0
                        }
                    }
                }
            }
        }

        // Footer
        Label {
            text: searchPopup.results.length > 0
                ? searchPopup.results.length + " results" : ""
            font.pixelSize: 11
            color: "#999999"
            Layout.alignment: Qt.AlignRight
        }
    }

    Timer {
        id: debounceTimer
        interval: 300
        onTriggered: {
            if (searchInput.text.length > 0 && networkClient) {
                var query = searchInput.text
                // Apply profile filter
                if (profileModel)
                    query = profileModel.applyProfileFilter(query)
                networkClient.quickSearch(query, 25)
            } else {
                searchPopup.results = []
            }
        }
    }

    // Handle search results from NetworkClient
    Connections {
        target: networkClient
        function onQuickSearchResults(results) {
            if (!searchPopup.visible) return
            var arr = []
            for (var i = 0; i < results.length; i++)
                arr.push(results[i])
            searchPopup.results = arr
            resultList.currentIndex = 0
        }
    }

    function parseName(from) {
        var lt = from.indexOf('<')
        if (lt > 0) {
            var n = from.substring(0, lt).trim()
            if (n.startsWith('"') && n.endsWith('"')) n = n.substring(1, n.length - 1)
            if (n) return n
        }
        var m = from.match(/<([^>]+)>/)
        if (m) return m[1].split('@')[0]
        return from.trim()
    }

    function selectCurrent() {
        if (resultList.currentIndex >= 0 && resultList.currentIndex < results.length) {
            var item = results[resultList.currentIndex]
            searchPopup.lastQuery = searchInput.text
            resultSelected(item.thread_id, item.subject)
            searchPopup.close()
        }
    }
}
