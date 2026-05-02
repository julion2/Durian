import QtQuick

// TODO: load keybindings from ~/.config/durian/keymaps.pkl instead of hardcoding
// The macOS GUI uses a full KeySequenceEngine (gui/durian/Keymaps/) that parses
// keymaps.pkl with support for sequences, counts, modifiers, and contexts.

Item {
    id: handler
    focus: true

    // External state
    property var threadList: null
    property var sidebar: null
    property var detailView: null
    property int threadCount: 0

    signal navigateToThread(int index)
    signal requestSearch()
    signal exitSearch()

    // Focus state: list vs thread detail
    property bool threadFocused: false

    // Count prefix for vim-style 5j, 3k
    property int countPrefix: 0

    // Sequence buffer for multi-key combos (gg, gi, gs, gd, ga, gt, dd)
    property string seqBuffer: ""
    property bool seqPending: false

    Timer {
        id: seqTimer
        interval: 800
        onTriggered: {
            handler.seqBuffer = ""
            handler.seqPending = false
        }
    }

    function handleSequence(key) {
        seqBuffer += key
        seqTimer.restart()
        seqPending = true

        if (seqBuffer === "gg") {
            navigateToThread(0)
        } else if (seqBuffer === "gi") {
            selectFolderByName("Inbox")
        } else if (seqBuffer === "gs") {
            selectFolderByName("Sent")
        } else if (seqBuffer === "gd") {
            selectFolderByName("Drafts")
        } else if (seqBuffer === "ga") {
            selectFolderByName("Archive")
        } else if (seqBuffer === "gt") {
            selectFolderByName("Trash")
        } else if (seqBuffer === "dd") {
            // TODO: delete action — need POST /api/v1/threads/{id}/tags
        } else if (seqBuffer.length === 1) {
            return
        }

        seqBuffer = ""
        seqPending = false
        seqTimer.stop()
    }

    function selectFolderByName(name) {
        if (!sidebar || !sidebar.profileModel) return
        var folders = sidebar.profileModel.folders
        for (var i = 0; i < folders.length; i++) {
            if (folders[i].name === name) {
                sidebar.selectFolder(i)
                return
            }
        }
    }

    function consumeCount() {
        var n = countPrefix > 0 ? countPrefix : 1
        countPrefix = 0
        return n
    }

    Keys.onPressed: function(event) {
        var key = event.key
        var mod = event.modifiers
        var text = event.text

        // Digit accumulation for count prefix (1-9 start, 0-9 continue)
        if (countPrefix > 0 && text >= "0" && text <= "9") {
            countPrefix = countPrefix * 10 + parseInt(text)
            event.accepted = true
            return
        }
        if (text >= "1" && text <= "9" && !seqPending) {
            countPrefix = parseInt(text)
            event.accepted = true
            return
        }

        // Sequence starters
        if (text === "g" || text === "d" || (seqPending && seqBuffer.length > 0)) {
            handleSequence(text)
            event.accepted = true
            return
        }

        if (threadFocused) {
            // === Thread view mode ===
            if (text === "j" || text === "n" || key === Qt.Key_Down) {
                var tn = consumeCount()
                for (var ti = 0; ti < tn; ti++) detailView.scrollToNextMessage()
                event.accepted = true
            } else if (text === "k" || text === "N" || key === Qt.Key_Up) {
                var tn2 = consumeCount()
                for (var ti2 = 0; ti2 < tn2; ti2++) detailView.scrollToPrevMessage()
                event.accepted = true
            } else if (text === "G") {
                if (detailView.messages) {
                    detailView.focusedMessage = detailView.messages.length - 1
                    detailView.scrollToNextMessage() // position it
                }
                countPrefix = 0
                event.accepted = true
            } else if (text === "h" || key === Qt.Key_Escape) {
                threadFocused = false
                countPrefix = 0
                event.accepted = true
            } else if (text === "/") {
                requestSearch()
                event.accepted = true
            }
        } else {
            // === List view mode ===
            if (text === "j" || key === Qt.Key_Down) {
                var n = consumeCount()
                var next = Math.min(threadList.currentIndex + n, threadCount - 1)
                navigateToThread(next)
                event.accepted = true
            } else if (text === "k" || key === Qt.Key_Up) {
                var n2 = consumeCount()
                var prev = Math.max(threadList.currentIndex - n2, 0)
                navigateToThread(prev)
                event.accepted = true
            } else if (text === "G") {
                navigateToThread(threadCount - 1)
                countPrefix = 0
                event.accepted = true
            } else if (text === "l" || key === Qt.Key_Return) {
                threadFocused = true
                if (detailView) detailView.focusedMessage = 0
                countPrefix = 0
                event.accepted = true
            } else if (key === Qt.Key_Escape) {
                exitSearch()
                event.accepted = true
            } else if (text === "/") {
                requestSearch()
                event.accepted = true
            }
        }

        // TODO: a (archive), s (star), u (read/unread), dd (delete)
        //       need POST /api/v1/threads/{id}/tags backend integration
    }
}
