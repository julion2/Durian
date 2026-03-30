// Shared avatar logic: initials + deterministic color from 12-color palette
// Matches macOS GUI behavior (AvatarManager.swift)

var colors = [
    "#E53935", "#FB8C00", "#F9A825", "#43A047",
    "#26A69A", "#00897B", "#00ACC1", "#1E88E5",
    "#5C6BC0", "#8E24AA", "#D81B60", "#6D4C41"
]

function parseName(from) {
    if (!from) return ""
    var lt = from.indexOf('<')
    if (lt > 0) {
        var name = from.substring(0, lt).trim()
        if (name.startsWith('"') && name.endsWith('"'))
            name = name.substring(1, name.length - 1)
        if (name.startsWith("'") && name.endsWith("'"))
            name = name.substring(1, name.length - 1)
        if (name) return name
    }
    // Extract email local part if only <email>
    var match = from.match(/<([^>]+)>/)
    if (match) return match[1].split('@')[0]
    return from.trim()
}

function initials(from) {
    var name = parseName(from)
    if (!name) return "?"
    var parts = name.split(/\s+/).filter(function(p) { return p.length > 0 })
    if (parts.length >= 2)
        return (parts[0].charAt(0) + parts[1].charAt(0)).toUpperCase()
    if (name.length >= 2)
        return name.substring(0, 2).toUpperCase()
    return name.charAt(0).toUpperCase()
}

function colorFor(from) {
    var name = parseName(from).toLowerCase()
    var hash = 0
    for (var i = 0; i < name.length; i++)
        hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0
    return colors[Math.abs(hash) % colors.length]
}
