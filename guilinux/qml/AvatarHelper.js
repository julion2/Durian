// Shared avatar logic: initials + deterministic color + Gravatar/Brandfetch URLs
// Matches macOS GUI behavior (AvatarManager.swift)

var colors = [
    "#E53935", "#FB8C00", "#F9A825", "#43A047",
    "#26A69A", "#00897B", "#00ACC1", "#1E88E5",
    "#5C6BC0", "#8E24AA", "#D81B60", "#6D4C41"
]

var personalDomains = [
    "gmail.com", "googlemail.com",
    "outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.de",
    "yahoo.com", "yahoo.de", "ymail.com",
    "gmx.de", "gmx.net", "gmx.at", "gmx.ch",
    "web.de", "t-online.de", "freenet.de", "mail.de", "email.de",
    "icloud.com", "me.com", "mac.com",
    "aol.com",
    "protonmail.com", "proton.me", "pm.me",
    "posteo.de", "mailbox.org",
    "tutanota.com", "tutanota.de", "tuta.io",
    "stanford.edu"
]

var brandfetchToken = "1idWonATCJFIseiVHIH"

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
    var match = from.match(/<([^>]+)>/)
    if (match) return match[1].split('@')[0]
    return from.trim()
}

function extractEmail(from) {
    if (!from) return ""
    var match = from.match(/<([^>]+)>/)
    if (match) return match[1].toLowerCase().trim()
    if (from.indexOf('@') >= 0) return from.toLowerCase().trim()
    return ""
}

function extractDomain(email) {
    var at = email.indexOf('@')
    if (at < 0) return ""
    return email.substring(at + 1).toLowerCase()
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

// Returns Gravatar URL for personal domains, "" otherwise (falls back to initials)
// md5Func should be Qt.md5
// TODO: Brandfetch for company logos needs custom User-Agent header,
//       requires C++ QQuickImageProvider — skipped for MVP
function avatarUrl(from, size, md5Func) {
    var email = extractEmail(from)
    if (!email) return ""

    var domain = extractDomain(email)
    if (!domain) return ""

    // Gravatar works for all emails, d=404 returns 404 if no account
    var hash = md5Func(email)
    return "https://gravatar.com/avatar/" + hash + "?d=404&s=" + size
}
