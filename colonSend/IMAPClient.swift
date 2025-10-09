import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import Security
import Combine
import AppKit

@MainActor
class IMAPClient: ObservableObject {
    private var eventLoopGroup: EventLoopGroup?
    private var channel: Channel?
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var folders: [IMAPFolder] = []
    private var accountId: String = ""
    @Published var emails: [IMAPEmail] = []
    @Published var selectedFolderName: String?
    @Published var isLoadingEmails = false
    @Published var loadingProgress: String = ""
    @Published var hasMoreMessages = false
    
    private var selectedFolder: String?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var commandCounter = 1000
    private var pendingCommands: [String: CommandCompletion] = [:]
    private var paginationState = PaginationState()
    private var attemptedSections: [UInt32: Set<String>] = [:]
    private var lastCommandTime: Date = Date.distantPast
    private let minimumCommandInterval: TimeInterval = 0.05  // 50ms between commands (faster for bulk)
    private var emailFetchStartTimes: [UInt32: Date] = [:]
    private let emailFetchTimeout: TimeInterval = 15.0  // 15 seconds timeout (faster fail)
    private var failedFetches: Set<UInt32> = []  // Track permanently failed emails
    private var bulkProcessingMode: Bool = false
    
    init() {
        setupSettingsObserver()
    }
    
    func connect(account: MailAccount) async {
        print("🔵 Starting IMAP connection to \(account.imap.host):\(account.imap.port)")
        self.accountId = account.email
        connectionStatus = "Connecting..."
        
        do {
            print("🔵 Creating event loop group...")
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoopGroup = group
            
            print("🔵 Setting up bootstrap for \(account.imap.host):\(account.imap.port) (SSL: \(account.imap.ssl))")
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.connectTimeout, value: TimeAmount.seconds(30))
                .channelInitializer { channel in
                    print("🔵 Initializing channel pipeline...")
                    let imapHandler = IMAPClientHandler(imapClient: self)
                    
                    if account.imap.ssl {
                        print("🔵 Adding SSL handler for TLS connection")
                        do {
                            let sslContext = try NIOSSLContext(configuration: .clientDefault)
                            let hostname = account.imap.host
                            
                            // Create SSL handler in a way that bypasses Sendable requirements
                            let sslHandlerResult = Result<any ChannelHandler, Error> {
                                try NIOSSLClientHandler(context: sslContext, serverHostname: hostname)
                            }
                            
                            switch sslHandlerResult {
                            case .success(let sslHandler):
                                return channel.pipeline.addHandler(sslHandler).flatMap { _ in
                                    channel.pipeline.addHandler(imapHandler)
                                }
                            case .failure(let error):
                                print("❌ Failed to create SSL handler: \(error)")
                                return channel.pipeline.addHandler(imapHandler)
                            }
                        } catch {
                            print("❌ Failed to create SSL context: \(error)")
                            return channel.pipeline.addHandler(imapHandler)
                        }
                    } else {
                        print("🔵 Using plain connection (no SSL)")
                        return channel.pipeline.addHandler(imapHandler)
                    }
                }
            
            print("🔵 Attempting connection to \(account.imap.host):\(account.imap.port)...")
            let channel = try await bootstrap.connect(host: account.imap.host, port: account.imap.port).get()
            self.channel = channel
            print("✅ TCP connection established!")
            
            // Attempt login
            try await login(account: account)
            
            isConnected = true
            connectionStatus = "Connected"
            
            // Start auto-refresh timer
            setupAutoRefresh()
            
        } catch {
            connectionStatus = "Error: \(error.localizedDescription)"
            print("❌ IMAP connection error: \(error)")
            print("❌ Error details: \(String(describing: error))")
        }
    }
    
    private func login(account: MailAccount) async throws {
        guard self.channel != nil else {
            throw IMAPError.noConnection
        }
        
        connectionStatus = "Authenticating..."
        
        print("🔵 Retrieving password from keychain...")
        guard let password = getPasswordFromKeychain(service: account.auth.passwordKeychain ?? "", account: account.auth.username) else {
            throw IMAPError.authenticationFailed
        }
        
        print("🔵 Sending IMAP LOGIN command...")
        let loginCommand = "LOGIN \"\(account.auth.username)\" \"\(password)\""
        
        let _ = try await executeCommand(loginCommand)
        print("✅ Login completed for: \(account.auth.username)")
        
        // Fetch folder list
        try await fetchFolders()
    }
    
    private func fetchFolders() async throws {
        print("🔵 Fetching folder list...")
        let listCommand = "LIST \"\" \"*\""
        
        let _ = try await executeCommand(listCommand)
        print("✅ Folder list retrieved")
    }
    
    func parseFolderResponse(_ response: String) {
        // Parse: * LIST (\HasNoChildren \Drafts) "/" "Drafts"
        let lines = response.components(separatedBy: .newlines)
        
        for line in lines {
            if line.hasPrefix("* LIST") {
                if let folder = parseListLine(line) {
                    if !folders.contains(where: { $0.name == folder.name }) {
                        Task { @MainActor in
                            folders.append(folder)
                            print("📁 Added folder: \(folder.name) (\(folder.icon)) - Total folders: \(folders.count)")
                        }
                    }
                }
            }
        }
    }
    
    private func parseListLine(_ line: String) -> IMAPFolder? {
        // Parse both quoted and unquoted formats:
        // * LIST (\HasNoChildren \Drafts) "/" "Drafts" 
        // * LIST (\HasNoChildren) "/" INBOX
        
        // First try quoted pattern: * LIST (attrs) "separator" "name"
        let quotedPattern = #"\* LIST \(([^)]*)\) "([^"]*)" "([^"]*)""#
        if let regex = try? NSRegularExpression(pattern: quotedPattern),
           let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..<line.endIndex, in: line)),
           match.numberOfRanges >= 4 {
            
            let attributesString = String(line[Range(match.range(at: 1), in: line)!])
            let separator = String(line[Range(match.range(at: 2), in: line)!])
            let name = String(line[Range(match.range(at: 3), in: line)!])
            
            let attributes = attributesString.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            let decodedName = decodeModifiedUTF7(name)
            let fixedName = fixEncodingIssues(decodedName)
            return IMAPFolder(name: fixedName, attributes: attributes, separator: separator, accountId: accountId)
        }
        
        // Try unquoted pattern: * LIST (attrs) separator name
        let unquotedPattern = #"\* LIST \(([^)]*)\) ([^\s]+) (.+)"#
        if let regex = try? NSRegularExpression(pattern: unquotedPattern),
           let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..<line.endIndex, in: line)),
           match.numberOfRanges >= 4 {
            
            let attributesString = String(line[Range(match.range(at: 1), in: line)!])
            let separator = String(line[Range(match.range(at: 2), in: line)!])
            let name = String(line[Range(match.range(at: 3), in: line)!])
            
            let attributes = attributesString.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            let decodedName = decodeModifiedUTF7(name)
            let fixedName = fixEncodingIssues(decodedName)
            return IMAPFolder(name: fixedName, attributes: attributes, separator: separator, accountId: accountId)
        }
        
        return nil
    }
    
    func selectFolder(_ folderName: String) async {
        guard self.channel != nil, isConnected else {
            print("❌ Cannot select folder: not connected")
            return
        }
        
        print("🔵 Selecting folder: \(folderName)")
        self.selectedFolder = folderName
        
        // Clear previous emails and update selected folder
        emails.removeAll()
        selectedFolderName = folderName
        
        let selectCommand = "SELECT \"\(folderName)\""
        
        do {
            let _ = try await executeCommand(selectCommand)
            print("✅ SELECT completed for \(folderName)")
            
            // fetchEmails() will be called automatically when parseExistsResponse() is triggered
        } catch {
            print("❌ Failed to select folder: \(error)")
        }
    }
    
    private func fetchEmails() async {
        guard selectedFolder != nil else {
            print("❌ Cannot fetch emails: no folder selected")
            return
        }
        
        await loadEmails(loadMore: false)
    }
    
    func loadMoreEmails() async {
        guard selectedFolder != nil else {
            print("❌ Cannot load more emails: no folder selected")
            return
        }
        
        await loadEmails(loadMore: true)
    }
    
    private func loadEmails(loadMore: Bool) async {
        guard let folder = selectedFolder, isConnected else { return }
        
        if loadMore && !paginationState.hasMoreMessages {
            print("📭 No more emails to load")
            return
        }
        
        isLoadingEmails = true
        
        // Enable bulk processing mode for large email lists
        if paginationState.totalMessages > 50 {
            bulkProcessingMode = true
            print("📧 BULK MODE: Enabled for \(paginationState.totalMessages) emails")
        } else {
            bulkProcessingMode = false
        }
        
        if loadMore {
            paginationState.isLoadingMore = true
            loadingProgress = "Loading more emails..."
        } else {
            // Don't reset totalMessages if we already have it from EXISTS response
            let existingTotal = paginationState.totalMessages
            paginationState.reset()
            paginationState.totalMessages = existingTotal
            emails.removeAll()
            // Clear failed fetches on new folder load
            failedFetches.removeAll()
            loadingProgress = "Loading emails..."
        }
        
        print("🔵 \(loadMore ? "Loading more" : "Fetching") emails from \(folder)...")
        
        do {
            // Calculate message range for pagination
            let startIndex: Int
            let endIndex: Int
            
            if loadMore {
                startIndex = paginationState.currentPage * paginationState.pageSize + 1
                endIndex = min(startIndex + paginationState.pageSize - 1, paginationState.totalMessages)
            } else {
                // For initial load, get the most recent messages
                startIndex = max(1, paginationState.totalMessages - paginationState.pageSize + 1)
                endIndex = paginationState.totalMessages
            }
            
            if startIndex <= endIndex && endIndex > 0 {
                let fetchCommand = "FETCH \(startIndex):\(endIndex) (UID FLAGS ENVELOPE BODYSTRUCTURE)"
                _ = try await executeCommand(fetchCommand)

                let loadedCount = emails.count
                loadingProgress = "Loaded \(loadedCount) of \(paginationState.totalMessages) messages"

                if loadMore {
                    paginationState.nextPage()
                }

                print("✅ FETCH command completed for range \(startIndex):\(endIndex)")
            } else {
            }

        } catch {
            print("❌ Failed to fetch emails: \(error)")
            loadingProgress = "Failed to load emails: \(error.localizedDescription)"
        }

        isLoadingEmails = false
        paginationState.isLoadingMore = false
        hasMoreMessages = paginationState.hasMoreMessages
    }
    
    func parseEmailResponse(_ response: String) {
        // Parse: * 1 FETCH (UID 1 ... ENVELOPE ("date" "subject" (("from"...
        
        if response.contains("BODYSTRUCTURE") {
            // First parse the email data from ENVELOPE
            if let email = parseEmailFetch(response) {
                if !emails.contains(where: { $0.uid == email.uid }) {
                    Task { @MainActor in
                        emails.append(email)
                        print("📧 Added email: \(email.subject)")
                    }
                }
            }
            // Then parse BODYSTRUCTURE and fetch body
            parseBodyStructureAndFetchBody(response: response)
        } else if let email = parseEmailFetch(response) {
            if !emails.contains(where: { $0.uid == email.uid }) {
                Task { @MainActor in
                    emails.append(email)
                    print("📧 Added email: \(email.subject)")
                }
            }
        }
    }
    
    private func parseEmailFetch(_ response: String) -> IMAPEmail? {
        // Enhanced IMAP FETCH response parsing
        
        // Must contain FETCH to be a valid email response
        guard response.contains("FETCH") else {
            return nil
        }
        
        var subject = "No Subject"
        var from = "Unknown Sender"
        var date = "Unknown Date"
        var uid: UInt32 = 0
        var isRead = false
        
        // Parse UID from FETCH line
        if let uidMatch = response.range(of: "UID (\\d+)", options: .regularExpression) {
            let uidText = String(response[uidMatch])
            if let uidString = uidText.components(separatedBy: " ").last,
               let parsedUID = UInt32(uidString) {
                uid = parsedUID
            }
        }
        
        // Parse FLAGS to determine read status
        if let flagsMatch = response.range(of: "FLAGS \\(([^)]+)\\)", options: .regularExpression) {
            let flagsText = String(response[flagsMatch])
            isRead = flagsText.contains("\\Seen")
        }
        
        // Parse ENVELOPE data - format: ENVELOPE ("date" "subject" (("name" NIL "user" "domain")) ...)
        if let envelopeStart = response.range(of: "ENVELOPE \\(", options: .regularExpression) {
            let envelopeContent = String(response[envelopeStart.upperBound...])
            
            // Parse ENVELOPE fields in order: date, subject, from, sender, reply-to, to, cc, bcc, in-reply-to, message-id
            let envelopeFields = parseEnvelopeFields(envelopeContent)
            
            if envelopeFields.count >= 3 {
                date = cleanQuotedString(envelopeFields[0])
                subject = cleanQuotedString(envelopeFields[1])
                from = parseEmailAddress(envelopeFields[2])
            }
        }

        guard uid > 0 else { 
            return nil 
        }
        
        return IMAPEmail(
            uid: uid,
            subject: subject,
            from: from,
            date: date,
            body: nil,
            isRead: isRead
        )
    }
    
    private func parseEnvelopeFields(_ envelope: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        var escape = false
        
        for char in envelope {
            if escape {
                current.append(char)
                escape = false
                continue
            }
            
            if char == "\\" {
                escape = true
                current.append(char)
                continue
            }
            
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
                continue
            }
            
            if !inQuotes {
                if char == "(" {
                    depth += 1
                    current.append(char)
                } else if char == ")" {
                    depth -= 1
                    current.append(char)
                    if depth == 0 && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                        current = ""
                    }
                } else if char == " " && depth == 0 {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                        current = ""
                    }
                } else {
                    current.append(char)
                }
            } else {
                current.append(char)
            }
        }
        
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return fields
    }
    
    private func cleanQuotedString(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = trimmed
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        if cleaned == "NIL" {
            return ""
        }
        
        // Apply RFC 2047 decoding for encoded subjects
        let rfc2047Decoded = decodeRFC2047(cleaned)
        
        // Apply encoding correction for common UTF-8/Latin-1 mix-ups
        return fixEncodingIssues(rfc2047Decoded)
    }
    
    private func parseEmailAddress(_ addressField: String) -> String {
        // Parse format: (("name" NIL "user" "domain"))
        if addressField.contains("((") {
            // Extract from nested parentheses
            let pattern = "\\(\\(\"([^\"]*)\".+?\"([^\"]+)\".+?\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: addressField, range: NSRange(addressField.startIndex..<addressField.endIndex, in: addressField)) {
                let name = String(addressField[Range(match.range(at: 1), in: addressField)!])
                let user = String(addressField[Range(match.range(at: 2), in: addressField)!])
                let domain = String(addressField[Range(match.range(at: 3), in: addressField)!])
                
                if !name.isEmpty {
                    return "\(name) <\(user)@\(domain)>"
                } else {
                    return "\(user)@\(domain)"
                }
            }
        }
        return addressField
    }

    private func parseBodyStructureAndFetchBody(response: String) {
        guard let uidMatch = response.range(of: "UID (\\d+)", options: .regularExpression) else {
            return
        }

        let uidString = String(response[uidMatch]).components(separatedBy: " ").last!
        let uid = UInt32(uidString)!
        
        print("📧 BODYSTRUCTURE: Parsing for UID \(uid)")
        
        // Look for BODYSTRUCTURE content
        if let bodyStructStart = response.range(of: "BODYSTRUCTURE \\(", options: .regularExpression) {
            let bodyStructContent = String(response[bodyStructStart.upperBound...])
            print("📧 BODYSTRUCTURE: Content preview: \(String(bodyStructContent.prefix(200)))")
            
            // Determine the correct section to fetch based on structure
            let section = determineTextSection(from: bodyStructContent)
            print("📧 BODYSTRUCTURE: Fetching section '\(section)' for UID \(uid)")
            
            Task {
                await fetchBody(uid: uid, section: section)
            }
        }
    }
    
    private func determineTextSection(from bodyStructure: String) -> String {
        // For nested multipart structures, we need to find the text/plain or text/html parts
        
        // Check if this is a complex multipart structure
        if bodyStructure.hasPrefix("((") {
            // This is a multipart within multipart (like multipart/related containing multipart/alternative)
            // Look for text/plain in the first alternative group: section 1.1.1
            if bodyStructure.contains("\"TEXT\" \"plain\"") {
                return "1.1.1"  // multipart/related -> multipart/alternative -> text/plain
            } else if bodyStructure.contains("\"TEXT\" \"html\"") {
                return "1.1.2"  // multipart/related -> multipart/alternative -> text/html
            } else {
                return "1.1"    // fallback to first alternative group
            }
        } else if bodyStructure.hasPrefix("(") && bodyStructure.contains("\"alternative\"") {
            // Simple multipart/alternative
            if bodyStructure.contains("\"TEXT\" \"plain\"") {
                return "1.1"    // multipart/alternative -> text/plain
            } else if bodyStructure.contains("\"TEXT\" \"html\"") {
                return "1.2"    // multipart/alternative -> text/html
            } else {
                return "1.1"    // fallback to first part
            }
        } else if bodyStructure.contains("\"TEXT\" \"PLAIN\"") || bodyStructure.contains("\"TEXT\" \"plain\"") {
            // Simple single-part text message
            return "1"
        } else {
            // Unknown structure, try section 1
            return "1"
        }
    }
    
    private func tryFallbackSection(uid: UInt32, failedSection: String) async {
        print("📧 Section \(failedSection) returned NIL for UID \(uid), trying fallbacks")
        
        // Check if this email has already permanently failed
        if failedFetches.contains(uid) {
            print("📧 UID \(uid) is in failed fetches list, skipping")
            return
        }
        
        // Initialize tracking for this UID if not exists
        if attemptedSections[uid] == nil {
            attemptedSections[uid] = Set<String>()
        }
        
        // Mark this section as attempted
        attemptedSections[uid]?.insert(failedSection)
        
        // Define fallback sections to try (ordered by preference)
        let allFallbackSections: [String] = ["1.1.1", "1.1.2", "1.1", "1.2", "1"]
        
        // Find next section that hasn't been attempted yet
        var nextSection: String?
        for section in allFallbackSections {
            if !(attemptedSections[uid]?.contains(section) ?? false) {
                nextSection = section
                break
            }
        }
        
        guard let sectionToTry = nextSection else {
            print("📧 All sections attempted for UID \(uid), permanently failing")
            // Add to failed fetches to avoid retrying
            failedFetches.insert(uid)
            
            // Set email to show error state instead of "Loading..."
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].body = "Unable to load email content (all sections failed)"
                emails[emailIndex].attributedBody = nil
            }
            // Clean up tracking for this UID
            attemptedSections.removeValue(forKey: uid)
            emailFetchStartTimes.removeValue(forKey: uid)
            return
        }
        
        print("📧 Trying fallback section \(sectionToTry) for UID \(uid)")
        await fetchBody(uid: uid, section: sectionToTry)
    }

    private func fetchBody(uid: UInt32, section: String) async {
        let command = "UID FETCH \(uid) (BODY[\(section)])"
        print("📧 FETCHBODY: Starting fetch for UID \(uid), section \(section)")
        
        // Track when this fetch started
        emailFetchStartTimes[uid] = Date()
        
        // Check if this UID has been trying too long
        if let startTime = emailFetchStartTimes[uid],
           Date().timeIntervalSince(startTime) > emailFetchTimeout {
            print("📧 FETCHBODY: Timeout reached for UID \(uid), giving up")
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].body = "Email loading timed out"
                emails[emailIndex].attributedBody = nil
                attemptedSections.removeValue(forKey: uid)
                emailFetchStartTimes.removeValue(forKey: uid)
            }
            return
        }
        
        do {
            let response = try await executeCommand(command)
            print("📧 FETCHBODY: Got response, length: \(response.count)")
            print("📧 FETCHBODY: Response preview: \(String(response.prefix(300)))")
            
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                // Try multiple patterns to find the body content
                var bodyContent: String?
                
                // Pattern 1: Standard BODY[section] {length} format
                if let bodyRange = response.range(of: "BODY\\[[\\d.]+\\]\\s*\\{(\\d+)\\}", options: .regularExpression) {
                    bodyContent = String(response[bodyRange.upperBound...])
                    print("📧 FETCHBODY: Found body content with standard pattern")
                }
                // Pattern 2: BODY[section] NIL
                else if response.contains("BODY[\(section)] NIL") {
                    print("📧 FETCHBODY: Section \(section) returned NIL for UID \(uid)")
                    // Trigger fallback
                    await tryFallbackSection(uid: uid, failedSection: section)
                    return
                }
                // Pattern 3: BODY[section] "quoted content"
                else if let quotedRange = response.range(of: "BODY\\[[\\d.]+\\]\\s*\"([^\"]+)\"", options: .regularExpression) {
                    let match = String(response[quotedRange])
                    if let startQuote = match.range(of: "\"")?.upperBound,
                       let endQuote = match.range(of: "\"", options: .backwards)?.lowerBound {
                        bodyContent = String(match[startQuote..<endQuote])
                        print("📧 FETCHBODY: Found quoted body content")
                    }
                }
                // Pattern 4: Try to find any content after BODY[section]
                else if let sectionRange = response.range(of: "BODY\\[[\\d.]+\\]", options: .regularExpression) {
                    let afterSection = String(response[sectionRange.upperBound...])
                    // Skip whitespace and look for content
                    let trimmed = afterSection.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("NIL") {
                        bodyContent = trimmed
                        print("📧 FETCHBODY: Found body content with loose pattern")
                    }
                }
                
                if let content = bodyContent {
                    print("📧 FETCHBODY: Processing body content, length: \(content.count)")
                    
                    // Clean up the extracted content
                    var cleanedContent = content
                    
                    // Remove trailing IMAP protocol responses more robustly
                    if let flagsStart = cleanedContent.range(of: "\\s+FLAGS\\s*\\(", options: .regularExpression) {
                        cleanedContent = String(cleanedContent[..<flagsStart.lowerBound])
                    }
                    
                    // Remove trailing command completion responses
                    if let completionStart = cleanedContent.range(of: "\\s+A\\d+\\s+OK", options: .regularExpression) {
                        cleanedContent = String(cleanedContent[..<completionStart.lowerBound])
                    }
                    
                    // Remove trailing parentheses from IMAP responses
                    if let trailingParen = cleanedContent.range(of: "\\s*\\)\\s*$", options: .regularExpression) {
                        cleanedContent = String(cleanedContent[..<trailingParen.lowerBound])
                    }
                    
                    // Remove any remaining IMAP response artifacts
                    cleanedContent = cleanedContent.replacingOccurrences(of: "^\\)\\s*", with: "", options: .regularExpression)
                    cleanedContent = cleanedContent.replacingOccurrences(of: "\\s*\\)$", with: "", options: .regularExpression)
                    
                    let cleanBody = cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("📧 FETCHBODY: Final cleaned content length: \(cleanBody.count)")
                    let (plainBody, attributedBody) = decodeEmailBody(cleanBody)
                    emails[emailIndex].body = plainBody.isEmpty ? "No content available" : plainBody
                    emails[emailIndex].attributedBody = attributedBody
                    
                    // Clean up tracking for this UID on successful load
                    attemptedSections.removeValue(forKey: uid)
                    emailFetchStartTimes.removeValue(forKey: uid)
                } else {
                    print("📧 FETCHBODY: No body content found in response")
                    print("📧 FETCHBODY: Full response for debugging: \(response)")
                    
                    // Check if this is a NIL response
                    if response.contains("BODY[\(section)] NIL") {
                        print("📧 FETCHBODY: Section \(section) returned NIL for UID \(uid)")
                        await tryFallbackSection(uid: uid, failedSection: section)
                        return
                    }
                    // Check if the email might be empty or very short
                    else if response.contains("BODY[\(section)] \"\"") || response.contains("BODY[\(section)] \"\\r\\n\"") {
                        print("📧 FETCHBODY: Section \(section) is empty for UID \(uid)")
                        emails[emailIndex].body = "Email appears to be empty"
                        emails[emailIndex].attributedBody = nil
                        attemptedSections.removeValue(forKey: uid)
                        emailFetchStartTimes.removeValue(forKey: uid)
                    }
                    // Try fallback before giving error
                    else {
                        print("📧 FETCHBODY: Unexpected response format, trying fallback")
                        await tryFallbackSection(uid: uid, failedSection: section)
                        return
                    }
                }
            } else {
                print("📧 FETCHBODY: Email with UID \(uid) no longer exists in list")
            }
        } catch {
            print("❌ FETCHBODY: Error fetching body for UID \(uid): \(error)")
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].body = "Error loading email: \(error.localizedDescription)"
                emails[emailIndex].attributedBody = nil
                // Clean up tracking on error
                attemptedSections.removeValue(forKey: uid)
                emailFetchStartTimes.removeValue(forKey: uid)
            }
        }
    }
    
    func parseExistsResponse(_ response: String) {
        let lines = response.components(separatedBy: .newlines)
        for line in lines {
            if line.contains(" EXISTS") {
                let components = line.components(separatedBy: .whitespaces)
                if let countString = components.first(where: { $0.allSatisfy(\.isNumber) }),
                   let count = Int(countString) {
                    paginationState.totalMessages = count
                    loadingProgress = "Found \(count) messages"
                    
                    // Now that we know the message count, fetch the emails
                    if count > 0 {
                        Task {
                            await fetchEmails()
                        }
                    }
                }
            }
        }
    }
    
    private func getPasswordFromKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let password = String(data: data, encoding: .utf8) {
            return password
        } else {
            print("❌ Failed to retrieve password from keychain for \(account): \(status)")
            return nil
        }
    }
    
    func disconnect() async {
        connectionStatus = "Disconnecting..."
        
        try? await channel?.close()
        eventLoopGroup = nil
        
        isConnected = false
        connectionStatus = "Disconnected"
        
        // Stop auto-refresh timer
        stopAutoRefresh()
    }
    
    // MARK: - Auto-refresh functionality
    
    private func setupSettingsObserver() {
        SettingsManager.shared.$settings
            .sink { [weak self] settings in
                self?.updateAutoRefresh(with: settings)
            }
            .store(in: &cancellables)
    }
    
    private func updateAutoRefresh(with settings: AppSettings) {
        stopAutoRefresh()
        
        if settings.autoFetchEnabled && isConnected {
            setupAutoRefresh()
        }
    }
    
    private func setupAutoRefresh() {
        let settings = SettingsManager.shared.settings
        
        guard settings.autoFetchEnabled else {
            return
        }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.autoFetchInterval, repeats: true) { _ in
            Task { @MainActor in
                guard let folder = self.selectedFolder else { return }
                
                await self.refreshCurrentFolder()
            }
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    private func refreshCurrentFolder() async {
        guard let folderName = selectedFolder, isConnected else { return }
        
        print("🔄 Refreshing \(folderName)...")
        await fetchEmails()
    }
    
    // MARK: - Public Methods
    
    func reloadCurrentFolder() async {
        
        guard let folderName = selectedFolder, isConnected else {
            print("⚠️ Cannot reload: no folder selected or not connected")
            return
        }
        
        print("🔄 Manual reload requested for \(folderName)")
        await refreshCurrentFolder()
    }
    
    func markAsRead(uid: UInt32) async {
        guard isConnected else {
            print("⚠️ Cannot mark as read: not connected")
            return
        }
        
        print("📧 Marking email UID \(uid) as read")
        
        do {
            let storeCommand = "UID STORE \(uid) +FLAGS (\\Seen)"
            let _ = try await executeCommand(storeCommand)
            
            // Update local email state
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].isRead = true
                print("✅ Email UID \(uid) marked as read locally")
            }
            
        } catch {
            print("❌ Failed to mark email as read: \(error)")
        }
    }
    
    func markAsUnread(uid: UInt32) async {
        guard isConnected else {
            print("⚠️ Cannot mark as unread: not connected")
            return
        }
        
        print("📧 Marking email UID \(uid) as unread")
        
        do {
            let storeCommand = "UID STORE \(uid) -FLAGS (\\Seen)"
            let _ = try await executeCommand(storeCommand)
            
            // Update local email state
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].isRead = false
                print("✅ Email UID \(uid) marked as unread locally")
            }
            
        } catch {
            print("❌ Failed to mark email as unread: \(error)")
        }
    }
    
    func toggleReadStatus(uid: UInt32) async {
        guard let email = emails.first(where: { $0.uid == uid }) else {
            print("❌ Email with UID \(uid) not found")
            return
        }
        
        if email.isRead {
            await markAsUnread(uid: uid)
        } else {
            await markAsRead(uid: uid)
        }
    }
    
    // MARK: - Email Content Decoding
    
    private func decodeEmailBody(_ body: String) -> (String, NSAttributedString?) {
        print("📧 DECODE START: First 200 chars: \(String(body.prefix(200)))")
        print("📧 DECODE START: Body length: \(body.count) characters")
        
        // Enhanced MIME detection - catch any MIME multipart content
        let hasMimeBoundary = body.contains("--_") || body.hasPrefix("--") || body.contains("\n--")
        let hasContentType = body.contains("Content-Type:")
        let hasTransferEncoding = body.contains("Content-Transfer-Encoding:")
        let hasQuotedPrintable = body.contains("=E") || body.contains("=F") || body.contains("=A") || 
                                body.contains("=C") || body.contains("=D") || body.contains("=3D")
        
        // Test base64 detection on the raw content
        let couldBeBase64 = isBase64Content(body)
        
        print("📧 DETECTION: boundary=\(hasMimeBoundary), contentType=\(hasContentType), encoding=\(hasTransferEncoding), quoted=\(hasQuotedPrintable), couldBeBase64=\(couldBeBase64)")
        
        // If we detect MIME structure, always use MIME parsing
        if hasMimeBoundary || hasContentType || hasTransferEncoding {
            print("📧 Using MIME parsing")
            let result = parseMimeContent(body)
            print("📧 MIME RESULT: First 200 chars: \(String(result.0.prefix(200)))")
            return result
        }
        
        // Check if it's base64 encoded (long lines of base64 characters)
        if couldBeBase64 {
            print("📧 Attempting direct base64 decode on entire content")
            let decoded = decodeBase64Content(body)
            if decoded != body {  // If decoding changed the content
                print("📧 Base64 decode successful, checking for HTML")
                // If decoded content is HTML, create rich text
                if decoded.contains("<html") || decoded.contains("<HTML") {
                    print("📧 Decoded content is HTML, processing for rich text")
                    return processHTMLContent(decoded)
                }
                let cleaned = removeEmailSignatureClutter(cleanWhitespace(decoded))
                print("📧 Base64 decode result: \(String(cleaned.prefix(200)))")
                return (cleaned, nil)
            } else {
                print("📧 Base64 decode failed or returned unchanged content")
            }
        }
        
        // Check for quoted-printable encoding (as fallback for unhandled MIME)
        if hasQuotedPrintable || (body.contains("=") && (body.contains("=E") || body.contains("=F") || body.contains("=3D"))) {
            print("📧 Using quoted-printable fallback")
            let decoded = cleanWhitespace(decodeQuotedPrintable(body))
            let cleaned = removeEmailSignatureClutter(decoded)
            print("📧 QP FALLBACK RESULT: First 200 chars: \(String(cleaned.prefix(200)))")
            return (cleaned, nil)
        }
        
        // Check for multipart content with encoding headers (another fallback)
        if body.contains("Content-Transfer-Encoding: quoted-printable") {
            let decoded = cleanWhitespace(decodeMultipartQuotedPrintable(body))
            let cleaned = removeEmailSignatureClutter(decoded)
            return (cleaned, nil)
        }
        
        // Final fallback - if we still have MIME boundaries, this means our parsing failed
        if body.contains("--_") && body.contains("Content-Type:") {
            print("📧 Using emergency MIME cleanup")
            // Emergency cleanup for failed MIME parsing
            let result = emergencyMimeCleanup(body)
            print("📧 EMERGENCY RESULT: First 200 chars: \(String(result.0.prefix(200)))")
            return result
        }
        
        // Extra aggressive check for any remaining encoded content
        if hasQuotedPrintable {
            print("📧 Using final quoted-printable cleanup")
            let decoded = decodeQuotedPrintable(body)
            let cleaned = cleanWhitespace(decoded)
            let finalCleaned = removeEmailSignatureClutter(cleaned)
            print("📧 FINAL QP RESULT: First 200 chars: \(String(finalCleaned.prefix(200)))")
            return (finalCleaned, nil)
        }
        
        let cleaned = cleanWhitespace(body)
        let finalCleaned = removeEmailSignatureClutter(cleaned)
        
        // Ultra-aggressive final check - if the result still contains MIME patterns, apply emergency cleanup
        if finalCleaned.contains("--_") || finalCleaned.contains("Content-Type:") || finalCleaned.contains("=E") {
            print("📧 ULTRA-AGGRESSIVE: Still contains MIME patterns, applying emergency cleanup")
            let ultraClean = emergencyMimeCleanup(finalCleaned)
            print("📧 ULTRA RESULT: First 200 chars: \(String(ultraClean.0.prefix(200)))")
            return ultraClean
        }
        
        // Apply encoding fixes before final return
        let encodingFixed = fixEncodingIssues(finalCleaned)
        print("📧 PLAIN FINAL RESULT: First 200 chars: \(String(encodingFixed.prefix(200)))")
        return (encodingFixed, nil)
    }
    
    private func decodeByTransferEncoding(_ content: String, encoding: String) -> String {
        print("📧 Decoding content with encoding: \(encoding)")
        print("📧 Content preview (first 100 chars): \(String(content.prefix(100)))")
        
        switch encoding {
        case "base64":
            let decoded = decodeBase64Content(content)
            print("📧 Base64 decode result preview: \(String(decoded.prefix(200)))")
            return decoded
        case "quoted-printable":
            let decoded = decodeQuotedPrintable(content)
            print("📧 QP decode result preview: \(String(decoded.prefix(200)))")
            return decoded
        case "7bit", "8bit", "binary":
            print("📧 No decoding needed for \(encoding)")
            return content  // No decoding needed
        default:
            print("📧 Unknown encoding \(encoding), using as-is")
            return content
        }
    }
    
    private func decodeBase64Content(_ content: String) -> String {
        // Remove whitespace and newlines from base64 content
        let cleanBase64 = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        
        print("📧 Attempting base64 decode on \(cleanBase64.count) characters")
        print("📧 Clean base64 preview: \(String(cleanBase64.prefix(50)))...")
        print("📧 Clean base64 ends with: ...\(String(cleanBase64.suffix(20)))")
        
        guard let decodedData = Data(base64Encoded: cleanBase64) else {
            print("📧 Failed to create Data from base64 string")
            print("📧 Base64 validation failed - might not be valid base64")
            return content  // Return original if decoding fails
        }
        
        print("📧 Successfully created Data object, size: \(decodedData.count) bytes")
        
        guard let decodedString = String(data: decodedData, encoding: .utf8) else {
            print("📧 Failed to create UTF-8 string from base64 data, trying Latin1")
            // Try Latin1 encoding for older emails
            if let latin1String = String(data: decodedData, encoding: .isoLatin1) {
                print("📧 Successfully decoded base64 content as Latin1")
                print("📧 Latin1 decode preview: \(String(latin1String.prefix(200)))")
                return latin1String
            }
            print("📧 Failed to decode base64 content with any encoding")
            return content
        }
        
        print("📧 Successfully decoded base64 content as UTF-8")
        print("📧 UTF-8 decode preview: \(String(decodedString.prefix(200)))")
        return decodedString
    }
    
    private func decodeRFC2047(_ text: String) -> String {
        // RFC 2047 encoded-word format: =?charset?encoding?encoded-text?=
        // Example: =?UTF-8?B?SGVsbG8gV29ybGQ=?= (Base64)
        // Example: =?UTF-8?Q?Hello=20World?= (Quoted-Printable)
        
        var result = text
        let pattern = "=\\?([^?]+)\\?([BQbq])\\?([^?]+)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        
        // Process all encoded words in the text
        while let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.count)) {
            guard match.numberOfRanges >= 4 else { break }
            
            let fullMatch = String(result[Range(match.range(at: 0), in: result)!])
            let charset = String(result[Range(match.range(at: 1), in: result)!]).uppercased()
            let encoding = String(result[Range(match.range(at: 2), in: result)!]).uppercased()
            let encodedText = String(result[Range(match.range(at: 3), in: result)!])
            
            var decodedText = ""
            
            switch encoding {
            case "B": // Base64
                if let data = Data(base64Encoded: encodedText) {
                    if let decoded = String(data: data, encoding: .utf8) {
                        decodedText = decoded
                    } else if charset == "ISO-8859-1" || charset == "LATIN1" {
                        // Try Latin1 encoding for older emails
                        decodedText = String(data: data, encoding: .isoLatin1) ?? encodedText
                    }
                }
                
            case "Q": // Quoted-Printable
                // RFC 2047 quoted-printable is slightly different from regular quoted-printable
                // Underscores represent spaces, and regular QP encoding for other characters
                var qpText = encodedText.replacingOccurrences(of: "_", with: " ")
                decodedText = decodeQuotedPrintable(qpText)
                
            default:
                decodedText = encodedText // Unknown encoding, use as-is
            }
            
            // Replace the encoded word with decoded text
            result = result.replacingOccurrences(of: fullMatch, with: decodedText)
        }
        
        return result
    }
    
    private func fixEncodingIssues(_ text: String) -> String {
        var fixed = text
        
        // Common UTF-8 bytes interpreted as Latin-1 patterns
        let encodingFixes = [
            // German umlauts (most important for your use case)
            "Ã¤": "ä",    // ä (UTF-8: C3 A4)
            "Ã¶": "ö",    // ö (UTF-8: C3 B6) 
            "Ã¼": "ü",    // ü (UTF-8: C3 BC)
            "Ã„": "Ä",    // Ä (UTF-8: C3 84)
            "Ã–": "Ö",    // Ö (UTF-8: C3 96)
            "Ãœ": "Ü",    // Ü (UTF-8: C3 9C)
            "ÃŸ": "ß",    // ß (UTF-8: C3 9F)
            
            // French accents
            "Ã©": "é",    // é (UTF-8: C3 A9)
            "Ã¨": "è",    // è (UTF-8: C3 A8)
            "Ã¡": "á",    // á (UTF-8: C3 A1)
            "Ã ": "à",    // à (UTF-8: C3 A0)
            "Ã§": "ç"     // ç (UTF-8: C3 A7)
        ]
        
        // Only apply fixes if we detect the problematic patterns
        let hasEncodingIssues = encodingFixes.keys.contains { fixed.contains($0) }
        
        if hasEncodingIssues {
            print("📧 ENCODING: Detected encoding issues, applying fixes")
            print("📧 ENCODING: Before: \(String(fixed.prefix(100)))")
            
            for (wrong, correct) in encodingFixes {
                fixed = fixed.replacingOccurrences(of: wrong, with: correct)
            }
            
            print("📧 ENCODING: After: \(String(fixed.prefix(100)))")
        }
        
        return fixed
    }
    
    private func decodeModifiedUTF7(_ text: String) -> String {
        // Modified UTF-7 decoding for IMAP folder names
        // Pattern: &XXX- where XXX is base64-encoded UTF-16
        
        var result = text
        let pattern = "&([A-Za-z0-9+/]*)-"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        
        print("📁 MUTF7: Decoding '\(text)'")
        
        // Process all encoded sequences
        while let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.count)) {
            guard match.numberOfRanges >= 2 else { break }
            
            let fullMatch = String(result[Range(match.range(at: 0), in: result)!])
            let base64Part = String(result[Range(match.range(at: 1), in: result)!])
            
            var decodedText = ""
            
            if base64Part.isEmpty {
                // &- represents &
                decodedText = "&"
            } else {
                // Decode base64 to UTF-16, then convert to string
                // Add padding if needed
                var paddedBase64 = base64Part
                while paddedBase64.count % 4 != 0 {
                    paddedBase64 += "="
                }
                
                if let data = Data(base64Encoded: paddedBase64) {
                    // Convert UTF-16BE data to string
                    if let decoded = String(data: data, encoding: .utf16BigEndian) {
                        decodedText = decoded
                    } else if let decoded = String(data: data, encoding: .utf16LittleEndian) {
                        decodedText = decoded
                    } else {
                        // Fallback: manual decode common patterns
                        decodedText = decodeCommonModifiedUTF7Patterns(base64Part)
                    }
                }
            }
            
            print("📁 MUTF7: '\(fullMatch)' -> '\(decodedText)'")
            result = result.replacingOccurrences(of: fullMatch, with: decodedText)
        }
        
        print("📁 MUTF7: Final result: '\(result)'")
        return result
    }
    
    private func decodeCommonModifiedUTF7Patterns(_ base64: String) -> String {
        // Common Modified UTF-7 patterns for German characters
        let commonPatterns = [
            "APY": "ö",  // &APY- = ö
            "APQ": "ä",  // &APQ- = ä  
            "APw": "ü",  // &APw- = ü
            "AOU": "Ä",  // &AOU- = Ä
            "AOY": "Ö",  // &AOY- = Ö
            "AOw": "Ü",  // &AOw- = Ü
            "AN8": "ß"   // &AN8- = ß
        ]
        
        return commonPatterns[base64] ?? base64
    }
    
    private func isBase64Content(_ content: String) -> Bool {
        // Remove all whitespace for analysis
        let cleaned = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        
        print("📧 Base64 detection input: '\(String(content.prefix(100)))...'")
        print("📧 Base64 detection cleaned: '\(String(cleaned.prefix(100)))...'")
        
        // Must be reasonably long and contain mostly base64 characters
        guard cleaned.count > 50 else { 
            print("📧 Base64 detection: Too short (\(cleaned.count) chars)")
            return false 
        }
        
        // Count base64 characters
        let base64CharSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let base64Chars = cleaned.unicodeScalars.filter { base64CharSet.contains($0) }.count
        let ratio = Double(base64Chars) / Double(cleaned.count)
        
        print("📧 Base64 detection: \(base64Chars)/\(cleaned.count) chars = \(String(format: "%.1f", ratio*100))% base64")
        
        // Also check if it looks like typical base64 email content (starts with common patterns)
        let startsWithHTMLBase64 = cleaned.hasPrefix("PGh0bWw") || cleaned.hasPrefix("PCEtLQ") // <html or <!--
        let startsWithCommonBase64 = cleaned.hasPrefix("TWltZS") || cleaned.hasPrefix("Q29udGV") // MIME- or Conte
        
        print("📧 Base64 patterns: startsWithHTML=\(startsWithHTMLBase64), startsWithCommon=\(startsWithCommonBase64)")
        
        // If more than 85% of characters are valid base64, OR it has typical base64 patterns, consider it base64 content
        let isBase64 = ratio > 0.85 || startsWithHTMLBase64 || startsWithCommonBase64
        print("📧 Is base64 content: \(isBase64) (ratio=\(String(format: "%.1f", ratio*100))%)")
        return isBase64
    }
    
    private func decodeQuotedPrintable(_ text: String) -> String {
        var decoded = text
        
        // Replace quoted-printable sequences
        let quotedPrintablePattern = "=([0-9A-Fa-f]{2})"
        let regex = try? NSRegularExpression(pattern: quotedPrintablePattern)
        
        while let match = regex?.firstMatch(in: decoded, range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)) {
            let hexString = String(decoded[Range(match.range(at: 1), in: decoded)!])
            if let hexValue = UInt8(hexString, radix: 16),
               let unicodeScalar = UnicodeScalar(UInt32(hexValue)) {
                let character = String(Character(unicodeScalar))
                decoded = decoded.replacingCharacters(in: Range(match.range, in: decoded)!, with: character)
            } else {
                break
            }
        }
        
        // Replace soft line breaks (=\n)
        decoded = decoded.replacingOccurrences(of: "=\n", with: "")
        decoded = decoded.replacingOccurrences(of: "=\r\n", with: "")
        
        // Fix line wrapping - rejoin lines that were broken in the middle of words
        decoded = fixLineWrapping(decoded)
        
        return decoded
    }
    
    private func decodeMultipartQuotedPrintable(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var inQuotedPrintableSection = false
        var bodyLines: [String] = []
        
        for line in lines {
            // Skip MIME boundary markers
            if line.hasPrefix("--_") || (line.hasPrefix("--") && line.count > 10) {
                continue
            }
            
            // Skip all Content-* headers
            if line.hasPrefix("Content-") {
                if line.contains("quoted-printable") {
                    inQuotedPrintableSection = true
                }
                continue
            }
            
            // Empty line means start of content
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inQuotedPrintableSection {
                inQuotedPrintableSection = true
                continue
            }
            
            // Collect content lines (skip headers)
            if inQuotedPrintableSection {
                bodyLines.append(line)
            }
        }
        
        let quotedPrintableBody = bodyLines.joined(separator: "\n")
        return decodeQuotedPrintable(quotedPrintableBody)
    }
    
    private func extractTextFromHTML(_ html: String) -> String {
        var text = html
        
        // Remove script and style content first
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        
        // Convert common HTML elements to text equivalents
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br[^>]*/>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: .regularExpression)
        
        // Convert links to readable format: <a href="url">text</a> → text (url)
        text = text.replacingOccurrences(of: "<a[^>]*href=\"([^\"]*)\"[^>]*>([^<]*)</a>", 
                                       with: "$2 ($1)", 
                                       options: .regularExpression)
        
        // Remove all remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        
        // Remove image placeholder text patterns (more comprehensive)
        text = text.replacingOccurrences(of: "\\[Ein Bild,[^\\]]*\\][^\\n]*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[Image:[^\\]]*\\][^\\n]*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[Picture:[^\\]]*\\][^\\n]*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "KI-generierte Inhalte können fehlerhaft sein\\.", with: "", options: .regularExpression)
        
        // Decode HTML entities
        text = decodeHTMLEntities(text)
        
        // Clean up whitespace and formatting
        text = cleanupExtractedText(text)
        
        return text
    }
    
    private func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        
        // Common HTML entities
        decoded = decoded.replacingOccurrences(of: "&nbsp;", with: " ")
        decoded = decoded.replacingOccurrences(of: "&amp;", with: "&")
        decoded = decoded.replacingOccurrences(of: "&lt;", with: "<")
        decoded = decoded.replacingOccurrences(of: "&gt;", with: ">")
        decoded = decoded.replacingOccurrences(of: "&quot;", with: "\"")
        decoded = decoded.replacingOccurrences(of: "&#39;", with: "'")
        decoded = decoded.replacingOccurrences(of: "&apos;", with: "'")
        
        // German umlauts and special characters
        decoded = decoded.replacingOccurrences(of: "&auml;", with: "ä")
        decoded = decoded.replacingOccurrences(of: "&ouml;", with: "ö")
        decoded = decoded.replacingOccurrences(of: "&uuml;", with: "ü")
        decoded = decoded.replacingOccurrences(of: "&Auml;", with: "Ä")
        decoded = decoded.replacingOccurrences(of: "&Ouml;", with: "Ö")
        decoded = decoded.replacingOccurrences(of: "&Uuml;", with: "Ü")
        decoded = decoded.replacingOccurrences(of: "&szlig;", with: "ß")
        
        return decoded
    }
    
    private func cleanupExtractedText(_ text: String) -> String {
        var cleaned = text
        
        // Fix common text extraction issues
        cleaned = cleaned.replacingOccurrences(of: "<mailto:([^>]+)>", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "<(https?://[^>]+)>", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "<([^>]+)>", with: "", options: .regularExpression)
        
        // Fix broken words (missing spaces)
        cleaned = cleaned.replacingOccurrences(of: "bitten wir umIhre", with: "bitten wir um Ihre")
        cleaned = cleaned.replacingOccurrences(of: "Datenschutzerkl ärung", with: "Datenschutzerklärung")
        
        // Remove remaining angle bracket artifacts
        cleaned = cleaned.replacingOccurrences(of: "[<>]", with: "", options: .regularExpression)
        
        // Remove excessive whitespace
        cleaned = cleaned.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        
        // Remove excessive line breaks (more than 2 consecutive)
        cleaned = cleaned.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        
        // Remove empty lines at the beginning and end
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
    
    private func parseMimeContent(_ content: String) -> (String, NSAttributedString?) {
        print("📧 MIME PARSE START: Content has \(content.components(separatedBy: .newlines).count) lines")
        let lines = content.components(separatedBy: .newlines)
        var textParts: [String] = []
        var htmlParts: [String] = []
        var currentPart: [String] = []
        var isInContent = false
        var isTextPlain = false
        var isTextHtml = false
        var currentEncoding: String = "7bit"  // default encoding
        var skipUntilNextBoundary = false
        var hasEncounteredBoundary = false
        
        for line in lines {
            // Detect MIME boundary markers
            let isBoundary = line.hasPrefix("--_") || (line.hasPrefix("--") && line.count > 10 && line.contains("_"))
            
            if isBoundary {
                hasEncounteredBoundary = true
                
                // Process previous part if we were collecting content
                if isInContent && !currentPart.isEmpty {
                    let partContent = currentPart.joined(separator: "\n")
                    let decodedContent = decodeByTransferEncoding(partContent, encoding: currentEncoding)
                    if isTextPlain {
                        textParts.append(decodedContent)
                    } else if isTextHtml {
                        htmlParts.append(decodedContent)
                    }
                }
                
                // Reset for new part
                currentPart = []
                isInContent = false
                isTextPlain = false
                isTextHtml = false
                currentEncoding = "7bit"  // reset to default
                skipUntilNextBoundary = false
                continue
            }
            
            // If we haven't encountered a boundary yet, this might be a simple email with headers
            if !hasEncounteredBoundary && line.hasPrefix("Content-Type:") {
                // This is likely a simple single-part email with headers
                if line.contains("text/plain") {
                    isTextPlain = true
                } else if line.contains("text/html") {
                    isTextHtml = true
                }
                continue
            }
            
            // Skip empty lines before content headers
            if !isInContent && line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Empty line after headers indicates start of content
                if hasEncounteredBoundary || isTextPlain || isTextHtml {
                    isInContent = true
                }
                continue
            }
            
            // Skip content-type headers and other MIME headers
            if line.hasPrefix("Content-Type:") {
                isTextPlain = line.contains("text/plain")
                isTextHtml = line.contains("text/html")
                continue
            }
            
            if line.hasPrefix("Content-Transfer-Encoding:") {
                // Extract the encoding type
                currentEncoding = line.replacingOccurrences(of: "Content-Transfer-Encoding:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                print("📧 Found encoding: \(currentEncoding)")
                continue
            }
            
            if line.hasPrefix("Content-Disposition:") || line.hasPrefix("Content-ID:") {
                continue
            }
            
            // Empty line indicates end of headers, start of content
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInContent {
                isInContent = true
                continue
            }
            
            // Collect content lines
            if isInContent && (isTextPlain || isTextHtml) {
                currentPart.append(line)
            }
        }
        
        // Process the final part if we were still collecting content
        if isInContent && !currentPart.isEmpty {
            let partContent = currentPart.joined(separator: "\n")
            let decodedContent = decodeByTransferEncoding(partContent, encoding: currentEncoding)
            if isTextPlain {
                textParts.append(decodedContent)
            } else if isTextHtml {
                htmlParts.append(decodedContent)
            }
        }
        
        // Process text/plain and text/html parts
        print("📧 MIME PARSE: Found textParts=\(textParts.count), htmlParts=\(htmlParts.count)")
        if !textParts.isEmpty && !htmlParts.isEmpty {
            // We have both - use HTML for rich formatting but keep plain text as fallback
            print("📧 MIME PARSE: Using HTML content (with plain text fallback)")
            let htmlContent = htmlParts.first!
            let (plainText, attributedText) = processHTMLContent(htmlContent)
            return (plainText, attributedText)
        } else if !textParts.isEmpty {
            // Only plain text available
            print("📧 MIME PARSE: Using plain text content")
            let cleanText = cleanWhitespace(textParts.first!)
            let finalText = removeEmailSignatureClutter(cleanText)
            let encodingFixed = fixEncodingIssues(finalText)
            return (encodingFixed, nil)
        } else if !htmlParts.isEmpty {
            // Only HTML available
            print("📧 MIME PARSE: Using HTML content only")
            let htmlContent = htmlParts.first!
            let (plainText, attributedText) = processHTMLContent(htmlContent)
            return (plainText, attributedText)
        }
        
        // If no parts were extracted, fall back to emergency cleanup
        if content.contains("--_") && content.contains("Content-Type:") {
            return emergencyMimeCleanup(content)
        }
        
        // Before giving up, check if the entire content might be base64
        print("📧 MIME PARSE: No parts found, checking if content might be base64")
        if isBase64Content(content) {
            print("📧 MIME PARSE: Content appears to be base64, attempting decode")
            let decoded = decodeBase64Content(content)
            if decoded != content {
                print("📧 MIME PARSE: Base64 decode successful in fallback")
                if decoded.contains("<html") || decoded.contains("<HTML") {
                    return processHTMLContent(decoded)
                }
                let cleaned = removeEmailSignatureClutter(cleanWhitespace(decoded))
                return (cleaned, nil)
            }
        }
        
        // Final fallback: clean the original content
        print("📧 MIME PARSE: Using final fallback - no parts found")
        print("📧 MIME PARSE: textParts=\(textParts.count), htmlParts=\(htmlParts.count)")
        let cleanText = cleanWhitespace(content)
        let finalText = removeEmailSignatureClutter(cleanText)
        let encodingFixed = fixEncodingIssues(finalText)
        print("📧 FINAL FALLBACK RESULT: First 200 chars: \(String(encodingFixed.prefix(200)))")
        return (encodingFixed, nil)
    }
    
    private func cleanWhitespace(_ text: String) -> String {
        var cleaned = text
        
        // Fix line wrapping first
        cleaned = fixLineWrapping(cleaned)
        
        // Remove duplicate content blocks (common in email signatures)
        cleaned = removeDuplicateBlocks(cleaned)
        
        // Remove excessive blank lines (more than 2 consecutive)
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        
        // Remove leading/trailing whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove excessive spaces within lines
        cleaned = cleaned.replacingOccurrences(of: " {3,}", with: "  ", options: .regularExpression)
        
        return cleaned
    }
    
    private func fixLineWrapping(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var currentParagraph = ""
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Empty line indicates paragraph break
            if trimmedLine.isEmpty {
                if !currentParagraph.isEmpty {
                    result.append(currentParagraph.trimmingCharacters(in: .whitespaces))
                    currentParagraph = ""
                }
                result.append("")
                continue
            }
            
            // If previous line ended with a letter and current line starts with a letter,
            // it's likely a word that was split across lines
            if !currentParagraph.isEmpty && 
               currentParagraph.last?.isLetter == true && 
               trimmedLine.first?.isLetter == true &&
               !trimmedLine.contains(":") &&  // Avoid joining headers
               trimmedLine.count > 0 {
                // Join with previous line without space if it looks like a split word
                currentParagraph += trimmedLine
            } else {
                // Add space if continuing a paragraph
                if !currentParagraph.isEmpty {
                    currentParagraph += " "
                }
                currentParagraph += trimmedLine
            }
        }
        
        // Add final paragraph
        if !currentParagraph.isEmpty {
            result.append(currentParagraph.trimmingCharacters(in: .whitespaces))
        }
        
        return result.joined(separator: "\n")
    }
    
    private func removeDuplicateBlocks(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        var uniqueParagraphs: [String] = []
        var seenBlocks: Set<String> = []
        
        for paragraph in paragraphs {
            let cleanParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip very short paragraphs for duplicate detection
            if cleanParagraph.count < 20 {
                uniqueParagraphs.append(paragraph)
                continue
            }
            
            // Check if we've seen this block before (with some tolerance for minor differences)
            let normalizedBlock = cleanParagraph.lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            
            if !seenBlocks.contains(normalizedBlock) {
                seenBlocks.insert(normalizedBlock)
                uniqueParagraphs.append(paragraph)
            }
        }
        
        return uniqueParagraphs.joined(separator: "\n\n")
    }
    
    private func removeEmailSignatureClutter(_ text: String) -> String {
        var cleaned = text
        
        // Remove common email signature patterns
        let signaturePatterns = [
            // Legal disclaimers and confidentiality notices
            "Diese elektronische Nachricht ist vertraulich[\\s\\S]*?durchzuführen\\.",
            "This electronic message is confidential[\\s\\S]*?virus checking\\.",
            
            // Social media links and image placeholders
            "\\[Ein Bild,[^\\]]*\\][^\\n]*",
            "\\[Image:[^\\]]*\\][^\\n]*",
            
            // Office hours in repetitive format  
            "Bürozeiten und Telefonzeiten:[\\s\\S]*?per E-Mail jederzeit für dich erreichbar\\.",
            
            // Legal footer links (with or without angle brackets)
            "Impressum[^\\n]*\\|[^\\n]*Datenschutzerklärung[^\\n]*",
            
            // Remove isolated social media hashtags and slogans
            "^#[a-zA-Z]+$",
            "^MENSCHLICH\\. BEWEGEND\\. MEHR\\.$"
        ]
        
        for pattern in signaturePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        
        // Remove duplicate contact information blocks
        cleaned = removeDuplicateContactBlocks(cleaned)
        
        // Clean up any resulting excessive whitespace
        cleaned = cleaned.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
    
    private func removeDuplicateContactBlocks(_ text: String) -> String {
        // Split into paragraphs and look for duplicate contact information
        let paragraphs = text.components(separatedBy: "\n\n")
        var result: [String] = []
        var seenContactInfo: Set<String> = []
        
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if this looks like contact information
            if trimmed.contains("Viktoria Glenz") || 
               (trimmed.contains("Telefon:") && trimmed.contains("E-Mail:")) ||
               (trimmed.contains("Mercedesstr. 3") && trimmed.contains("74366 Kirchheim")) {
                
                // Create a normalized version for comparison
                let normalized = trimmed.lowercased()
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "[^a-zA-Z0-9@. ]", with: "", options: .regularExpression)
                
                // Only keep the first occurrence of this contact block
                if !seenContactInfo.contains(normalized) {
                    seenContactInfo.insert(normalized)
                    result.append(paragraph)
                }
            } else {
                // Keep non-contact paragraphs
                result.append(paragraph)
            }
        }
        
        return result.joined(separator: "\n\n")
    }
    
    private func processHTMLContent(_ html: String) -> (String, NSAttributedString?) {
        // Create attributed string from HTML
        let attributedString = EmailHTMLParser.parseHTML(html)
        
        // Also create a clean plain text version for fallback
        let plainText = extractTextFromHTML(html)
        let cleanPlainText = removeEmailSignatureClutter(cleanWhitespace(plainText))
        
        return (cleanPlainText, attributedString)
    }
    
    private func emergencyMimeCleanup(_ content: String) -> (String, NSAttributedString?) {
        // Emergency fallback when MIME parsing fails
        print("🚨 Emergency MIME cleanup triggered")
        
        // Simple approach: find the first text/plain section and extract it
        let parts = content.components(separatedBy: "--_")
        
        for part in parts {
            if part.contains("Content-Type: text/plain") {
                // Extract content after headers
                let lines = part.components(separatedBy: .newlines)
                var contentLines: [String] = []
                var pastHeaders = false
                
                for line in lines {
                    if pastHeaders {
                        contentLines.append(line)
                    } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pastHeaders = true
                    }
                }
                
                let rawText = contentLines.joined(separator: "\n")
                let decoded = decodeQuotedPrintable(rawText)
                let cleaned = cleanWhitespace(decoded)
                let finalCleaned = removeEmailSignatureClutter(cleaned)
                
                print("✅ Emergency cleanup extracted text: \(finalCleaned.prefix(100))...")
                return (finalCleaned, nil)
            }
        }
        
        // Ultimate fallback: just decode quoted-printable and clean
        print("⚠️ No text/plain part found, applying basic cleanup")
        let decoded = decodeQuotedPrintable(content)
        let cleaned = cleanWhitespace(decoded)
        let finalCleaned = removeEmailSignatureClutter(cleaned)
        return (finalCleaned, nil)
    }
    
    // MARK: - Command Execution System
    
    private func generateCommandTag() -> String {
        commandCounter += 1
        return "A\(commandCounter)"
    }
    
    private func executeCommand(_ command: String, timeout: TimeInterval = 30.0) async throws -> String {
        guard let channel = self.channel else {
            throw IMAPError.noConnection
        }
        
        // Rate limiting: enforce minimum interval between commands (adaptive based on bulk mode)
        let effectiveInterval = bulkProcessingMode ? minimumCommandInterval : minimumCommandInterval * 2
        let timeSinceLastCommand = Date().timeIntervalSince(lastCommandTime)
        if timeSinceLastCommand < effectiveInterval {
            let delayNeeded = effectiveInterval - timeSinceLastCommand
            try await Task.sleep(nanoseconds: UInt64(delayNeeded * 1_000_000_000))
        }
        
        lastCommandTime = Date()
        let tag = generateCommandTag()
        let fullCommand = "\(tag) \(command)\r\n"
        
        return try await withCheckedThrowingContinuation { continuation in
            pendingCommands[tag] = { result in
                continuation.resume(with: result)
            }
            
            // Set up timeout
            Task { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let completion = pendingCommands.removeValue(forKey: tag) {
                    completion(.failure(IMAPError.commandTimeout))
                }
            }
            
            // Send command
            var buffer = channel.allocator.buffer(capacity: fullCommand.count)
            buffer.writeString(fullCommand)
            
            channel.writeAndFlush(buffer).whenComplete { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        print("✅ Command sent: \(tag) \(command)")
                    case .failure(let error):
                        if let completion = self.pendingCommands.removeValue(forKey: tag) {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }
    
    func handleCommandResponse(tag: String, response: String, isComplete: Bool) {
        guard let completion = pendingCommands[tag] else { return }
        
        if isComplete {
            pendingCommands.removeValue(forKey: tag)
            completion(.success(response))
        }
    }

    func parseBodyResponse(_ response: String) {
        if let uidMatch = response.range(of: "UID (\\d+)", options: .regularExpression) {
            let uidString = String(response[uidMatch]).components(separatedBy: " ").last!
            let uid = UInt32(uidString)!

            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                // Check for NIL response (empty body section)
                if response.contains("BODY[") && response.contains("] NIL") {
                    // Extract the section that returned NIL
                    if let sectionMatch = response.range(of: "BODY\\[([\\d.]+)\\]\\s+NIL", options: .regularExpression) {
                        let sectionRange = response.range(of: "[\\d.]+", options: .regularExpression, range: sectionMatch)!
                        let failedSection = String(response[sectionRange])
                        print("📧 Section \(failedSection) returned NIL for UID \(uid)")
                        
                        // Try fallback section
                        Task {
                            await tryFallbackSection(uid: uid, failedSection: failedSection)
                        }
                    }
                    return
                }
                
                if let bodyRange = response.range(of: "BODY\\[[\\d.]+\\]\\s*\\{(\\d+)\\}", options: .regularExpression) {
                    var bodyContent = String(response[bodyRange.upperBound...])
                    
                    // Clean up IMAP protocol data from body content
                    if let flagsStart = bodyContent.range(of: "\\s+FLAGS\\s*\\(", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<flagsStart.lowerBound])
                    }
                    
                    if let completionStart = bodyContent.range(of: "\\s+A\\d+\\s+OK", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<completionStart.lowerBound])
                    }
                    
                    if let trailingParen = bodyContent.range(of: "\\s*\\)\\s*$", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<trailingParen.lowerBound])
                    }
                    
                    let cleanBody = bodyContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    let (plainBody, attributedBody) = decodeEmailBody(cleanBody)
                    emails[emailIndex].body = plainBody.isEmpty ? "No content available" : plainBody
                    emails[emailIndex].attributedBody = attributedBody
                    
                    // Clean up tracking for this UID on successful load
                    attemptedSections.removeValue(forKey: uid)
                    emailFetchStartTimes.removeValue(forKey: uid)
                }
            }
        }
    }
}

private class IMAPClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    weak var imapClient: IMAPClient?
    
    init(imapClient: IMAPClient? = nil) {
        self.imapClient = imapClient
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("IMAP connection established")
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
            print("IMAP Server: \(string)")
            
            // Parse command completion responses (starts with tag)
            let lines = string.components(separatedBy: .newlines)
            for line in lines {
                if line.hasPrefix("A") && (line.contains(" OK ") || line.contains(" NO ") || line.contains(" BAD ")) {
                    if let spaceIndex = line.firstIndex(of: " ") {
                        let tag = String(line[..<spaceIndex])
                        Task { @MainActor in
                            imapClient?.handleCommandResponse(tag: tag, response: string, isComplete: true)
                        }
                    }
                }
            }
            
            // Parse LIST responses
            if string.contains("* LIST") {
                Task { @MainActor in
                    imapClient?.parseFolderResponse(string)
                }
            }
            
            // Parse FETCH responses
            if string.contains("* ") && string.contains("FETCH") {
                Task { @MainActor in
                    if string.contains("BODY[") {
                        imapClient?.parseBodyResponse(string)
                    } else {
                        imapClient?.parseEmailResponse(string)
                    }
                }
            }
            
            // Parse EXISTS responses for message count
            if string.contains("* ") && string.contains(" EXISTS") {
                Task { @MainActor in
                    imapClient?.parseExistsResponse(string)
                }
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("IMAP Error: \(error)")
        context.close(promise: nil)
    }
}

struct IMAPFolder: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let attributes: [String]
    let separator: String
    let accountId: String
    
    var icon: String {
        if attributes.contains("\\Inbox") || name == "INBOX" {
            return "tray"
        } else if attributes.contains("\\Drafts") {
            return "doc"
        } else if attributes.contains("\\Sent") {
            return "paperplane"
        } else if attributes.contains("\\Junk") {
            return "xmark.bin"
        } else if attributes.contains("\\Trash") {
            return "trash"
        } else {
            return "folder"
        }
    }
}

struct IMAPEmail: Identifiable, Hashable {
    let id = UUID()
    let uid: UInt32
    let subject: String
    let from: String
    let date: String
    var body: String?
    var attributedBody: NSAttributedString?
    var isRead: Bool
    
    // Hashable conformance - exclude NSAttributedString from hash
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
        hasher.combine(subject)
        hasher.combine(from)
        hasher.combine(date)
        hasher.combine(body)
        hasher.combine(isRead)
    }
    
    // Equatable conformance - exclude NSAttributedString from equality
    static func == (lhs: IMAPEmail, rhs: IMAPEmail) -> Bool {
        return lhs.id == rhs.id &&
               lhs.uid == rhs.uid &&
               lhs.subject == rhs.subject &&
               lhs.from == rhs.from &&
               lhs.date == rhs.date &&
               lhs.body == rhs.body &&
               lhs.isRead == rhs.isRead
    }
}

enum IMAPError: Error {
    case noConnection
    case authenticationFailed
    case connectionFailed
    case commandTimeout
    case invalidResponse
}

class PaginationState {
    var currentPage = 0
    var pageSize = 50
    var totalMessages = 0
    var isLoadingMore = false
    var hasMoreMessages: Bool {
        return (currentPage * pageSize) < totalMessages
    }
    
    func reset() {
        currentPage = 0
        totalMessages = 0
        isLoadingMore = false
    }
    
    func nextPage() {
        currentPage += 1
    }
}

typealias CommandCompletion = (Result<String, Error>) -> Void

extension String {
    func matches(pattern: String) -> Bool {
        return range(of: pattern, options: .regularExpression) != nil
    }
}

@MainActor
class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    @Published var accounts: [MailAccount] = []
    @Published var imapClients: [String: IMAPClient] = [:]
    @Published var allFolders: [IMAPFolder] = []
    @Published var allEmails: [IMAPEmail] = []
    @Published var selectedAccount: String?
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        loadAccounts()
    }
    
    private func loadAccounts() {
        accounts = ConfigManager.shared.accounts
        print("🔧 Loaded \(accounts.count) accounts")
    }
    
    func connectToAllAccounts() async {
        print("🔧 Connecting to \(accounts.count) accounts...")
        
        for account in accounts {
            let client = IMAPClient()
            imapClients[account.email] = client
            
            // Subscribe to client changes
            client.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
                self?.updateAggregatedData()
            }.store(in: &cancellables)
            
            Task {
                await client.connect(account: account)
                await updateAggregatedData()
            }
        }
    }
    
    private func mergeEmailsPreservingBodies(freshEmails: [IMAPEmail]) {
        print("🔄 Merging \(freshEmails.count) fresh emails with \(allEmails.count) existing emails, preserving bodies...")

        // If freshEmails is empty, it means the folder is actually empty
        // We should clear allEmails to reflect this
        // (The race condition is now prevented by clearing allEmails in selectFolder)
        if freshEmails.isEmpty {
            print("📭 Fresh emails is empty - folder is empty, clearing allEmails")
            allEmails.removeAll()
            return
        }

        // Create a dictionary of existing emails by UID for quick lookup
        var existingByUID: [UInt32: IMAPEmail] = [:]
        for email in allEmails {
            existingByUID[email.uid] = email
        }

        // Merge fresh emails with existing ones
        var merged: [IMAPEmail] = []
        for freshEmail in freshEmails {
            if let existing = existingByUID[freshEmail.uid],
               existing.body != nil && existing.body != "Loading..." {
                // Preserve the existing body that we already loaded
                var updated = freshEmail
                updated.body = existing.body
                updated.attributedBody = existing.attributedBody
                merged.append(updated)
                print("🔄 Preserved body for UID \(freshEmail.uid)")
            } else {
                // New email or no body yet
                merged.append(freshEmail)
            }
        }

        allEmails = merged
        print("✅ Merge complete: now have \(allEmails.count) emails")
    }

    private func updateAggregatedData() {
        // Aggregate all folders from all clients
        allFolders = imapClients.values.flatMap { $0.folders }

        // Aggregate emails ONLY from the explicitly selected account
        // Don't use fallback to avoid showing wrong emails during folder switch
        if let selectedAccount = selectedAccount,
           let client = imapClients[selectedAccount] {
            print("📧 updateAggregatedData: Using emails from selected account '\(selectedAccount)' (\(client.emails.count) emails)")
            mergeEmailsPreservingBodies(freshEmails: client.emails)
            isLoadingEmails = client.isLoadingEmails
            loadingProgress = client.loadingProgress
        } else {
            // No account selected - clear emails instead of showing random account's emails
            if selectedAccount != nil {
                print("⚠️ updateAggregatedData: selectedAccount '\(selectedAccount!)' has no client")
            } else {
                print("⚠️ updateAggregatedData: No account selected yet")
            }
            // Don't modify allEmails if no proper account is selected
            // This prevents race condition showing wrong emails
        }
    }
    
    func selectFolder(_ folderName: String, accountId: String) async {
        print("📂 AccountManager: Selecting folder '\(folderName)' for account '\(accountId)'")

        // CRITICAL: Clear emails immediately to prevent race condition
        // If we don't do this, objectWillChange from the client might show old emails
        allEmails.removeAll()
        selectedAccount = accountId

        guard let client = imapClients[accountId] else {
            print("❌ No IMAP client found for account: \(accountId)")
            return
        }

        await client.selectFolder(folderName)
        await updateAggregatedData()
    }
    
    func getClient(for accountId: String) -> IMAPClient? {
        return imapClients[accountId]
    }
    
    func reloadCurrentFolder() async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for reload")
            return
        }
        
        await client.reloadCurrentFolder()
        await updateAggregatedData()
    }
    
    func markAsRead(uid: UInt32) async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for mark as read")
            return
        }
        
        await client.markAsRead(uid: uid)
        await updateAggregatedData()
    }
    
    func toggleReadStatus(uid: UInt32) async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for toggle read")
            return
        }
        
        await client.toggleReadStatus(uid: uid)
        await updateAggregatedData()
    }
}

struct IMAPCommand {
    let tag: String
    let command: String
    let completion: CommandCompletion
    let timeout: TimeInterval
    
    init(tag: String, command: String, timeout: TimeInterval = 30.0, completion: @escaping CommandCompletion) {
        self.tag = tag
        self.command = command
        self.completion = completion
        self.timeout = timeout
    }
}