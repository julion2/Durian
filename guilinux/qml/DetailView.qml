import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine

Item {
    id: detailView

    property var threadModel: null
    property var networkClient: null
    property var profileModel: null
    property int currentIndex: -1
    property bool active: false
    property var messages: []
    property string threadSubject: ""
    property int focusedMessage: 0

    function scrollToNextMessage() {
        if (focusedMessage < messages.length - 1) {
            focusedMessage++
            msgListView.positionViewAtIndex(focusedMessage, ListView.Beginning)
        }
    }

    function scrollToPrevMessage() {
        if (focusedMessage > 0) {
            focusedMessage--
            msgListView.positionViewAtIndex(focusedMessage, ListView.Beginning)
        }
    }

    onCurrentIndexChanged: {
        focusedMessage = 0
        if (currentIndex >= 0 && threadModel && networkClient) {
            var tid = threadModel.threadId(currentIndex)
            if (tid) networkClient.fetchThread(tid)
            threadSubject = threadModel.subject(currentIndex)
        } else {
            messages = []
            threadSubject = ""
        }
    }

    Connections {
        target: networkClient
        function onThreadLoaded(thread) {
            threadSubject = thread.subject || ""
            var msgs = thread.messages
            if (msgs) {
                var arr = []
                for (var i = 0; i < msgs.length; i++) {
                    arr.push(msgs[i])
                }
                detailView.messages = arr
            }
        }
    }

    // Strip HTML tags → plain text, collapse whitespace
    function htmlToPlain(html) {
        if (!html) return ""
        // Remove style/script blocks
        var text = html.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
        text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
        // Block elements → newlines
        text = text.replace(/<\/(p|div|tr|li|h[1-6])>/gi, "\n")
        text = text.replace(/<br\s*\/?>/gi, "\n")
        // Strip remaining tags
        text = text.replace(/<[^>]+>/g, "")
        // Decode common entities
        text = text.replace(/&nbsp;/gi, " ")
        text = text.replace(/&amp;/gi, "&")
        text = text.replace(/&lt;/gi, "<")
        text = text.replace(/&gt;/gi, ">")
        text = text.replace(/&quot;/gi, '"')
        text = text.replace(/&#39;/gi, "'")
        text = text.replace(/&\u00a0;/gi, " ")
        // Collapse blank lines
        text = text.replace(/\n{3,}/g, "\n\n")
        return text.trim()
    }

    // Parse display name from "Name <email>" format
    function parseName(from) {
        if (!from) return ""
        var lt = from.indexOf('<')
        if (lt > 0) {
            var name = from.substring(0, lt).trim()
            if (name.startsWith('"') && name.endsWith('"'))
                name = name.substring(1, name.length - 1)
            if (name) return name
        }
        return from
    }

    // Get first letter for avatar
    function initialFor(from) {
        var name = parseName(from)
        for (var i = 0; i < name.length; i++) {
            var ch = name.charAt(i)
            if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z'))
                return ch.toUpperCase()
        }
        return "?"
    }

    // Format recipients: strip emails, show names only
    function formatRecipients(field) {
        if (!field) return ""
        return field.replace(/<[^>]+>/g, "").replace(/"/g, "").replace(/\s+/g, " ").trim()
    }

    // Parse RFC date "Mon, 30 Mar 2026 18:19:11 +0200" → "Mar 30, 18:19"
    function formatDate(raw) {
        if (!raw) return ""
        var d = new Date(raw)
        if (isNaN(d.getTime())) return raw
        var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        var h = d.getHours()
        var m = d.getMinutes()
        return months[d.getMonth()] + " " + d.getDate() + ", " +
               (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
    }

    // Pick best body: prefer stripped HTML, fall back to plain text
    function messageBody(msg) {
        if (msg.html && msg.html.trim().length > 0)
            return htmlToPlain(msg.html)
        return msg.body || ""
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        // Thread subject
        Label {
            text: currentIndex >= 0 ? threadSubject : "Select a thread"
            font.pixelSize: 18
            font.bold: true
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        // Message cards
        ListView {
            id: msgListView
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8
            clip: true
            model: detailView.messages

            delegate: Item {
                required property var modelData
                required property int index
                width: ListView.view.width
                implicitHeight: card.implicitHeight

                property bool isOwn: profileModel ? profileModel.isOwnEmail(modelData.from || "") : false

                Rectangle {
                    id: card
                    anchors.left: isOwn ? undefined : parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: isOwn ? 0 : 0
                    width: parent.width - (isOwn ? 40 : 0)
                    x: isOwn ? 40 : 0
                    implicitHeight: msgCol.implicitHeight + 24
                    radius: 8
                    color: isOwn ? "#f3f0ff" : "#ffffff"
                    border.color: (detailView.active && index === detailView.focusedMessage)
                        ? "#b39ddb" : (isOwn ? "#ddd6f3" : "#e6e6e6")
                    border.width: (detailView.active && index === detailView.focusedMessage) ? 2 : 1

                    ColumnLayout {
                        id: msgCol
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 4

                        // Header: avatar left, name/to/cc right
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Rectangle {
                                width: 36; height: 36; radius: 18
                                color: isOwn ? "#e0d6f9" : "#f0f0f0"
                                Layout.alignment: Qt.AlignTop
                                Label {
                                    anchors.centerIn: parent
                                    text: detailView.initialFor(modelData.from)
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                    color: "#333333"
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                // Sender + date
                                RowLayout {
                                    Layout.fillWidth: true
                                    Label {
                                        text: detailView.parseName(modelData.from)
                                        font.pixelSize: 13
                                        font.weight: Font.DemiBold
                                        color: "#111111"
                                        Layout.fillWidth: true
                                    }
                                    Label {
                                        text: detailView.formatDate(modelData.date)
                                        font.pixelSize: 11
                                        color: "#999999"
                                    }
                                }

                                // TODO: force single-line elide on To/Cc
                                // To
                                Label {
                                    text: "To: " + detailView.formatRecipients(modelData.to)
                                    font.pixelSize: 11
                                    color: "#888888"
                                    Layout.fillWidth: true
                                    visible: (modelData.to || "").length > 0
                                }

                                // Cc
                                Label {
                                    text: "Cc: " + detailView.formatRecipients(modelData.cc)
                                    font.pixelSize: 11
                                    color: "#888888"
                                    Layout.fillWidth: true
                                    visible: (modelData.cc || "").length > 0
                                }
                            }
                        }

                        // Separator
                        Rectangle {
                            Layout.fillWidth: true
                            height: 1
                            color: isOwn ? "#e0d6f3" : "#f0f0f0"
                            Layout.topMargin: 6
                            Layout.bottomMargin: 4
                        }

                        // Body: HTML via WebEngine, plaintext fallback
                        Loader {
                            Layout.fillWidth: true
                            Layout.preferredHeight: item ? item.implicitHeight : 0
                            sourceComponent: (modelData.html && modelData.html.trim().length > 0)
                                ? webBodyComponent : textBodyComponent
                        }

                        Component {
                            id: webBodyComponent
                            WebEngineView {
                                property real finalHeight: 100
                                property bool heightLocked: false
                                implicitHeight: finalHeight
                                onContentsSizeChanged: {
                                    if (!heightLocked && contentsSize.height > 10) {
                                        heightLocked = true
                                        finalHeight = contentsSize.height
                                    }
                                }
                                // Disable scroll/input so ListView handles scrolling
                                enabled: false
                                Component.onCompleted: {
                                    var base = (networkClient ? networkClient.baseUrl : "http://localhost:9723")
                                    var imgSrc = "img-src data: " + base
                                    if (profileModel && profileModel.loadRemoteImages)
                                        imgSrc = "img-src data: https: http: " + base
                                    var csp = "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'; " + imgSrc + ";\">"
                                    var style = "<style>body { font-family: -apple-system, sans-serif; font-size: 13px; color: #333; margin: 0; padding: 0; } img { max-width: 100%; height: auto; }</style>"

                                    // Resolve cid: references to API URLs
                                    var html = modelData.html || ""
                                    var msgId = modelData.message_id || modelData.id || ""
                                    var atts = modelData.attachments || []
                                    for (var i = 0; i < atts.length; i++) {
                                        var att = atts[i]
                                        if (att.content_id && att.content_id.length > 0) {
                                            var cid = att.content_id.replace(/^</, "").replace(/>$/, "")
                                            var apiUrl = (networkClient ? networkClient.baseUrl : "http://localhost:9723") +
                                                "/api/v1/messages/" + encodeURIComponent(msgId) +
                                                "/attachments/" + att.part_id
                                            html = html.split("cid:" + cid).join(apiUrl)
                                        }
                                    }

                                    loadHtml(csp + style + html)
                                }
                                backgroundColor: "transparent"
                                settings.javascriptEnabled: false
                            }
                        }

                        Component {
                            id: textBodyComponent
                            Label {
                                text: modelData.body || ""
                                font.pixelSize: 13
                                color: "#333333"
                                wrapMode: Text.Wrap
                                lineHeight: 1.3
                            }
                        }
                    }
                }
            }
        }
    }
}
