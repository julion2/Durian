import QtQuick
import QtQuick.Controls

Rectangle {
    id: avatar

    property string from: ""
    property int size: 32

    readonly property var _palette: [
        "#E53935", "#FB8C00", "#F9A825", "#43A047",
        "#26A69A", "#00897B", "#00ACC1", "#1E88E5",
        "#5C6BC0", "#8E24AA", "#D81B60", "#6D4C41"
    ]

    function _parseName(f) {
        if (!f) return ""
        var lt = f.indexOf('<')
        if (lt > 0) {
            var n = f.substring(0, lt).trim()
            if (n.charAt(0) === '"' && n.charAt(n.length-1) === '"') n = n.substring(1, n.length - 1)
            if (n.charAt(0) === "'" && n.charAt(n.length-1) === "'") n = n.substring(1, n.length - 1)
            if (n) return n
        }
        var m = f.match(/<([^>]+)>/)
        if (m) return m[1].split('@')[0]
        return f.trim()
    }

    function _initials(f) {
        var name = _parseName(f)
        if (!name) return "?"
        var parts = name.split(/\s+/).filter(function(p) { return p.length > 0 })
        if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase()
        if (name.length >= 2) return name.substring(0, 2).toUpperCase()
        return name[0].toUpperCase()
    }

    function _color(f) {
        var name = _parseName(f).toLowerCase()
        var hash = 0
        for (var i = 0; i < name.length; i++)
            hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0
        return _palette[Math.abs(hash) % _palette.length]
    }

    function _email(f) {
        if (!f) return ""
        var m = f.match(/<([^>]+)>/)
        if (m) return m[1].toLowerCase().trim()
        if (f.indexOf('@') >= 0) return f.toLowerCase().trim()
        return ""
    }

    readonly property string _avatarEmail: _email(from)
    readonly property string _imageSource: _avatarEmail
        ? "image://avatar/" + encodeURIComponent(_avatarEmail)
        : ""

    width: size
    height: size
    radius: size / 2
    color: from ? _color(from) : "#cccccc"

    // Initials
    Label {
        anchors.centerIn: parent
        text: avatar.from ? avatar._initials(avatar.from) : "?"
        font.pixelSize: Math.round(avatar.size * 0.36)
        font.weight: Font.DemiBold
        color: "#ffffff"
    }

    // Gravatar/Brandfetch image
    Image {
        id: img
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(avatar.size * 2, avatar.size * 2)
        source: avatar._imageSource
        asynchronous: true
        cache: true
        opacity: status === Image.Ready ? 1.0 : 0.0
    }
}
