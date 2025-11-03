import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import Security
import Combine
import AppKit
import ColonMime

// MARK: - Separated Components
// Note: The following have been extracted to separate files for better organization:
// - Models: IMAPModels.swift (IMAPFolder, IMAPEmail, IMAPError, PaginationState, etc.)
// - Account Management: AccountManager.swift (multi-account coordination)
// - Network Handler: IMAPClientHandler.swift (network I/O handling)
// - Text Decoding: IMAPTextDecodingUtilities.swift (base64, RFC2047, quoted-printable, etc.)
// - Text Cleaning: IMAPTextCleaningUtilities.swift (whitespace, signatures, duplicates, etc.)

// MARK: - Literal Tracking

struct LiteralExpectation {
    let size: Int
    var receivedBytes: Int = 0
    var startOffset: Int = 0
    
    var isComplete: Bool { 
        receivedBytes >= size || (size - receivedBytes) <= 2
    }
}

// MARK: - IMAPClient Main Class

@MainActor
class IMAPClient: ObservableObject {
    // MARK: - Properties
    
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
    
    // FIX: Store command metadata to enable proper response matching
    private struct PendingCommand {
        let tag: String
        let commandString: String
        let requestedUID: UInt32?
        let requestedSection: String?
        let sentAt: Date
        var responseBuffer: String
        var completion: CommandCompletion
    }
    
    private var pendingCommands: [String: PendingCommand] = [:]
    private var lastSentTag: String?
    private var responseBuffers: [String: String] = [:]
    private var responseBufferLastSizes: [String: Int] = [:]
    private var responseBufferLastUpdated: [String: Date] = [:]
    private var literalExpectations: [String: [LiteralExpectation]] = [:]
    private var paginationState = PaginationState()
    private var attemptedSections: [UInt32: Set<String>] = [:]
    private var lastCommandTime: Date = Date.distantPast
    private let minimumCommandInterval: TimeInterval = 0.05  // 50ms between commands (faster for bulk)
    private var emailFetchStartTimes: [UInt32: Date] = [:]
    private var emailFetchTimeout: TimeInterval = 15.0  // 15 seconds timeout (faster fail)
    private var failedFetches: Set<UInt32> = []  // Track permanently failed emails
    private var bulkProcessingMode: Bool = false
    private var activeFetchTasks: [UInt32: Task<Void, Never>] = [:]  // Track active fetch tasks for cancellation
    
    // MARK: - Initialization
    
    init() {
        setupSettingsObserver()
    }
    
    // MARK: - Connection Management
    
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
                .channelOption(ChannelOptions.autoRead, value: true)
                .channelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator(
                    minimum: 1024,
                    initial: 16384,
                    maximum: 1048576
                ))
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
            print("IMAP_SELECT: Error - Not connected")
            return
        }
        
        print("IMAP_SELECT: Selecting folder: \(folderName)")
        self.selectedFolder = folderName
        
        emails.removeAll()
        selectedFolderName = folderName
        
        let encodedFolderName = encodeModifiedUTF7(folderName)
        print("IMAP_SELECT: Encoded folder name: \(encodedFolderName)")
        
        let selectCommand = "SELECT \"\(encodedFolderName)\""
        
        do {
            let response = try await executeCommand(selectCommand)
            print("IMAP_SELECT: Response: \(String(response.prefix(200)))")
            print("IMAP_SELECT: Completed for \(folderName)")
        } catch {
            print("IMAP_SELECT: Failed - \(error)")
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

                print("✅ Loaded \(loadedCount) emails from \(folder)")
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
        let fetchBlocks = splitFetchResponse(response)
        
        for fetchBlock in fetchBlocks {
            if fetchBlock.contains("BODYSTRUCTURE") {
                if let email = parseEmailFetch(fetchBlock) {
                    if !emails.contains(where: { $0.uid == email.uid }) {
                        Task { @MainActor in
                            emails.append(email)
                            print("📧 Added email UID \(email.uid): \(email.subject)")
                        }
                    }
                }
                parseBodyStructureAndFetchBody(response: fetchBlock)
            } else if let email = parseEmailFetch(fetchBlock) {
                if !emails.contains(where: { $0.uid == email.uid }) {
                    Task { @MainActor in
                        emails.append(email)
                        print("📧 Added email UID \(email.uid): \(email.subject)")
                    }
                }
            }
        }
    }
    
    /// Splits a multi-FETCH IMAP response into individual email blocks.
    /// IMAP servers can send multiple emails in one response (e.g., "27 FETCH items").
    /// This function uses parenthesis depth tracking to correctly split the response,
    /// since FETCH data contains nested structures like ENVELOPE ((...)(...)...).
    private func splitFetchResponse(_ response: String) -> [String] {
        var blocks: [String] = []
        var currentBlock = ""
        var parenDepth = 0
        
        let lines = response.components(separatedBy: "\n")
        
        for line in lines {
            if line.contains("* ") && line.contains(" FETCH (") && parenDepth == 0 {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                }
                currentBlock = line
                parenDepth = line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            } else {
                currentBlock += "\n" + line
                parenDepth += line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            }
        }
        
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }
        
        return blocks.filter { !$0.isEmpty }
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
        
        // ENCODING FIX: For non-RFC2047 strings that came from IMAP server,
        // we need to recover the original bytes by converting to ISO-8859-1 and back to UTF-8
        // This fixes mojibake caused by ByteBuffer.getString() misinterpreting bytes
        if !cleaned.contains("=?") {
            // Not RFC2047 encoded - likely plain text that was misinterpreted
            if let data = cleaned.data(using: .isoLatin1),
               let utf8String = String(data: data, encoding: .utf8) {
                cleaned = utf8String
            }
        }
        
        // Apply RFC 2047 decoding for encoded subjects
        let rfc2047Decoded = decodeRFC2047(cleaned)
        
        // Apply encoding correction for remaining UTF-8/Latin-1 mix-ups
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
            
            let attachments = parseIncomingAttachments(from: bodyStructContent, uid: uid)
            if !attachments.isEmpty {
                Task { @MainActor in
                    if let index = emails.firstIndex(where: { $0.uid == uid }) {
                        var email = emails[index]
                        email.incomingAttachments = attachments
                        emails[index] = email
                        print("📧 BODYSTRUCTURE: Updated email \(uid) with \(attachments.count) attachments")
                    }
                }
            }
            
            // Determine the correct section to fetch based on structure
            let section = determineTextSection(from: bodyStructContent)
            print("📧 BODYSTRUCTURE: Fetching section '\(section)' for UID \(uid)")
            
            // Cancel any existing fetch task for this UID
            activeFetchTasks[uid]?.cancel()
            
            // Set loading state immediately
            Task { @MainActor in
                if let index = emails.firstIndex(where: { $0.uid == uid }) {
                    emails[index].bodyState = .loading
                }
            }
            
            // Create and track new fetch task
            let fetchTask = Task {
                await fetchBody(uid: uid, section: section)
            }
            activeFetchTasks[uid] = fetchTask
        }
    }
    
    private func determineTextSection(from bodyStructure: String) -> String {
        // FIX: Case-insensitive matching for IMAP types (RFC 3501)
        let normalized = bodyStructure.uppercased()
        
        print("📧 BODYSTRUCTURE (normalized): \(normalized.prefix(200))")
        
        // Check if this is a complex multipart structure (nested)
        if normalized.hasPrefix("(((") {
            // Triple nesting: outer multipart -> inner multipart -> parts
            // Example: mixed -> alternative -> (text/plain, text/html)
            // Section numbering: 1.1 for first part of inner multipart
            if normalized.contains("\"TEXT\" \"PLAIN\"") {
                print("📧 BODYSTRUCTURE: Triple-nested multipart - using section 1.1 for text/plain")
                return "1.1"  // outer[1] -> inner[1] = 1.1
            } else if normalized.contains("\"TEXT\" \"HTML\"") {
                print("📧 BODYSTRUCTURE: Triple-nested multipart - using section 1.2 for text/html")
                return "1.2"  // outer[1] -> inner[2] = 1.2
            } else {
                return "1.1"    // fallback to first part of inner multipart
            }
        } else if normalized.hasPrefix("((") {
            // Double nesting without triple - this is less common
            // Try section 1.1 for first nested part
            print("📧 BODYSTRUCTURE: Double-nested multipart - using section 1.1")
            return "1.1"
        } else if normalized.hasPrefix("(") && normalized.contains("\"ALTERNATIVE\"") {
            // FIX: Simple multipart/alternative - parts are numbered 1, 2 NOT 1.1, 1.2!
            // IMAP section numbering: (part1)(part2) "ALTERNATIVE" = sections "1" and "2"
            if normalized.contains("\"TEXT\" \"PLAIN\"") {
                print("📧 BODYSTRUCTURE: Multipart/alternative - using section 1 for text/plain")
                return "1"    // First part (text/plain)
            } else if normalized.contains("\"TEXT\" \"HTML\"") {
                print("📧 BODYSTRUCTURE: Multipart/alternative - using section 2 for text/html")
                return "2"    // Second part (text/html)
            } else {
                return "1"    // fallback to first part
            }
        } else if normalized.hasPrefix("(") && normalized.contains("\"MIXED\"") {
            // Multipart/mixed - text is typically first part
            print("📧 BODYSTRUCTURE: Multipart/mixed - using section 1")
            return "1"
        } else if normalized.hasPrefix("(") && normalized.contains("\"RELATED\"") {
            // Multipart/related - text is typically first part
            print("📧 BODYSTRUCTURE: Multipart/related - using section 1")
            return "1"
        } else if normalized.contains("\"TEXT\" \"PLAIN\"") || normalized.contains("\"TEXT\" \"HTML\"") {
            // Simple single-part text message
            return "1"
        } else {
            // Unknown structure, try section 1
            print("⚠️ BODYSTRUCTURE: Unknown structure, defaulting to section 1")
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
        
        // FIX: Define fallback sections to try (ordered by simplest first, not most nested)
        // Try common sections in order of likelihood: simple -> alternative -> nested
        let allFallbackSections: [String] = ["1", "2", "1.1", "1.2", "2.1", "1.1.1", "1.1.2", "2.1.1"]
        
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
                let errorMsg = "Unable to load email content (all sections failed)"
                emails[emailIndex].body = errorMsg
                emails[emailIndex].attributedBody = nil
                emails[emailIndex].bodyState = .failed(message: "All sections failed")
            }
            // Clean up tracking for this UID
            attemptedSections.removeValue(forKey: uid)
            emailFetchStartTimes.removeValue(forKey: uid)
            activeFetchTasks.removeValue(forKey: uid)
            return
        }
        
        print("📧 Trying fallback section \(sectionToTry) for UID \(uid)")
        
        // Cancel existing task and create new one for fallback
        activeFetchTasks[uid]?.cancel()
        let fallbackTask = Task {
            await fetchBody(uid: uid, section: sectionToTry)
        }
        activeFetchTasks[uid] = fallbackTask
    }
    
    /// Fetches the body structure and then the body for a specific email UID.
    /// This is used when a user clicks on an email that doesn't have its body loaded yet.
    func fetchEmailBody(uid: UInt32) async {
        print("📧 FETCH_EMAIL_BODY: Fetching BODYSTRUCTURE for UID \(uid)")
        
        // Check if already loading or loaded
        if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
            switch emails[emailIndex].bodyState {
            case .loaded:
                print("📧 FETCH_EMAIL_BODY: UID \(uid) already loaded, skipping")
                return
            case .loading:
                print("📧 FETCH_EMAIL_BODY: UID \(uid) already loading, skipping")
                return
            case .failed:
                print("📧 FETCH_EMAIL_BODY: UID \(uid) previously failed, retrying...")
                // Reset failed state and continue
                emails[emailIndex].bodyState = .loading
            case .notLoaded:
                // Set to loading
                emails[emailIndex].bodyState = .loading
            }
        }
        
        let fetchCommand = "UID FETCH \(uid) (BODYSTRUCTURE)"
        
        do {
            let response = try await executeCommand(fetchCommand, timeout: 30.0)
            print("📧 FETCH_EMAIL_BODY: Got BODYSTRUCTURE response for UID \(uid)")
            
            // Parse the BODYSTRUCTURE and trigger body fetch
            parseBodyStructureAndFetchBody(response: response)
            
        } catch {
            print("❌ FETCH_EMAIL_BODY: Failed to fetch BODYSTRUCTURE for UID \(uid): \(error)")
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].bodyState = .failed(message: "Failed to fetch structure")
            }
        }
    }

    /// Fetches the full body of a draft email by UID.
    /// Uses BODY.PEEK[] instead of BODY[] to avoid marking the message as read.
    /// Directly updates the email in the emails array without triggering merges,
    /// which prevents the body swap bug.
    func fetchDraftBody(uid: UInt32) async {
        let fetchCommand = "UID FETCH \(uid) (BODY[])"
        
        print("DRAFT_FETCH: Command sent for UID \(uid)")
        
        do {
            let response = try await executeCommand(fetchCommand, timeout: 30.0)
            
            print("DRAFT_FETCH: Response received - \(response.count) bytes total")
            
            var bodyContent: String?
            
            if let bodyRange = response.range(of: "BODY\\[\\]\\s*\\{(\\d+)\\}", options: .regularExpression) {
                let sizeMatch = String(response[bodyRange])
                if let sizeRange = sizeMatch.range(of: "\\d+", options: .regularExpression),
                   let size = Int(sizeMatch[sizeRange]) {
                    print("DRAFT_FETCH: Expected \(size) bytes of body data")
                    
                    guard let responseData = response.data(using: .utf8) else {
                        print("DRAFT_FETCH: ERROR - Cannot convert response to UTF-8 data")
                        return
                    }
                    
                    let prefixStr = String(response[..<bodyRange.upperBound])
                    guard let prefixData = prefixStr.data(using: .utf8) else {
                        print("DRAFT_FETCH: ERROR - Cannot convert prefix to UTF-8 data")
                        return
                    }
                    
                    var byteOffset = prefixData.count
                    
                    while byteOffset < responseData.count {
                        let byte = responseData[byteOffset]
                        if byte == 0x0D || byte == 0x0A {
                            byteOffset += 1
                        } else {
                            break
                        }
                    }
                    
                    let endOffset = min(byteOffset + size, responseData.count)
                    let bodyData = responseData[byteOffset..<endOffset]
                    
                    if let extractedBody = String(data: bodyData, encoding: .utf8) {
                        bodyContent = extractedBody
                        print("DRAFT_FETCH: Extracted \(extractedBody.count) chars (\(bodyData.count) bytes)")
                    } else {
                        print("DRAFT_FETCH: ERROR - Cannot decode body data as UTF-8")
                    }
                }
            }
            
            if let bodyContent = bodyContent, !bodyContent.isEmpty {
                let (plainBody, attachments) = parseMIMEDraftBody(bodyContent)
                
                await MainActor.run {
                    if let index = emails.firstIndex(where: { $0.uid == uid }) {
                        var email = emails[index]
                        email.rawBody = bodyContent
                        email.body = plainBody
                        email.attachments = attachments
                        emails[index] = email
                        print("DRAFT_FETCH: SUCCESS - Stored \(plainBody.count) chars, \(attachments.count) attachments for UID \(uid)")
                    } else {
                        print("DRAFT_FETCH: ERROR - UID \(uid) not found in emails array")
                    }
                }
            } else {
                print("DRAFT_FETCH: ERROR - No body content extracted from response")
            }
            
        } catch {
            print("DRAFT_FETCH: ERROR - Command failed: \(error)")
        }
    }
    
    private func parseMIMEDraftBody(_ mimeBody: String) -> (String, [EmailAttachment]) {
        var plainText = ""
        var attachments: [EmailAttachment] = []
        
        let lines = mimeBody.components(separatedBy: .newlines)
        
        guard let boundaryLine = lines.first(where: { $0.contains("boundary=") }) else {
            print("DRAFT_MIME: No boundary found, treating as plain text")
            return (mimeBody, [])
        }
        
        guard let boundaryMatch = boundaryLine.range(of: "boundary=\"([^\"]+)\"", options: .regularExpression) else {
            print("DRAFT_MIME: Could not extract boundary")
            return (mimeBody, [])
        }
        
        let boundaryString = String(boundaryLine[boundaryMatch])
        guard let boundary = boundaryString.split(separator: "\"").dropFirst().first else {
            print("DRAFT_MIME: Invalid boundary format")
            return (mimeBody, [])
        }
        
        print("DRAFT_MIME: Parsing with boundary: \(boundary)")
        
        let parts = mimeBody.components(separatedBy: "--\(boundary)")
        
        for part in parts {
            if part.contains("Content-Type: text/plain") {
                let partLines = part.components(separatedBy: .newlines)
                var contentStarted = false
                var contentLines: [String] = []
                
                for line in partLines {
                    if contentStarted {
                        contentLines.append(line)
                    } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contentStarted = true
                    }
                }
                
                plainText = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                print("DRAFT_MIME: Extracted plain text (\(plainText.count) chars)")
                
            } else if part.contains("Content-Disposition: attachment") {
                if let attachment = parseAttachmentPart(part) {
                    attachments.append(attachment)
                    print("DRAFT_MIME: Extracted attachment: \(attachment.filename)")
                }
            }
        }
        
        return (plainText, attachments)
    }
    
    private func parseAttachmentPart(_ part: String) -> EmailAttachment? {
        let lines = part.components(separatedBy: .newlines)
        
        var filename: String?
        var mimeType: String?
        var encoding: String?
        var contentStarted = false
        var contentLines: [String] = []
        
        for line in lines {
            if line.contains("filename=") {
                if let filenameMatch = line.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) {
                    let filenameString = String(line[filenameMatch])
                    filename = filenameString.split(separator: "\"").dropFirst().first.map(String.init)
                }
            } else if line.hasPrefix("Content-Type:") {
                let components = line.replacingOccurrences(of: "Content-Type:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: ";")
                mimeType = components.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("Content-Transfer-Encoding:") {
                encoding = line.replacingOccurrences(of: "Content-Transfer-Encoding:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            } else if contentStarted {
                contentLines.append(line)
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentStarted = true
            }
        }
        
        guard let filename = filename,
              let mimeType = mimeType,
              !contentLines.isEmpty else {
            print("DRAFT_MIME: Missing required attachment fields")
            return nil
        }
        
        let contentString = contentLines.joined(separator: "").replacingOccurrences(of: "\r", with: "")
        
        guard let data = Data(base64Encoded: contentString) else {
            print("DRAFT_MIME: Failed to decode base64 attachment data")
            return nil
        }
        
        return EmailAttachment(filename: filename, mimeType: mimeType, data: data)
    }
    
    private func extractUIDFromResponse(_ response: String) -> UInt32? {
        if let uidMatch = response.range(of: "UID (\\d+)", options: .regularExpression) {
            let uidText = String(response[uidMatch])
            if let uidString = uidText.components(separatedBy: " ").last,
               let uid = UInt32(uidString) {
                return uid
            }
        }
        return nil
    }
    
    private func fetchBody(uid: UInt32, section: String) async {
        // Check for task cancellation
        if Task.isCancelled {
            print("📧 FETCHBODY: Task cancelled for UID \(uid)")
            return
        }
        
        let command = "UID FETCH \(uid) (BODY[\(section)])"
        print("📧 FETCHBODY: Starting fetch for UID \(uid), section \(section)")
        
        // Track when this fetch started
        emailFetchStartTimes[uid] = Date()
        
        // Check if this UID has been trying too long
        if let startTime = emailFetchStartTimes[uid],
           Date().timeIntervalSince(startTime) > emailFetchTimeout {
            print("📧 FETCHBODY: Timeout reached for UID \(uid), giving up")
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].bodyState = .failed(message: "Timeout")
                emails[emailIndex].body = "Email loading timed out"
                emails[emailIndex].attributedBody = nil
                attemptedSections.removeValue(forKey: uid)
                emailFetchStartTimes.removeValue(forKey: uid)
                activeFetchTasks.removeValue(forKey: uid)
            }
            return
        }
        
        do {
            // FIX: Pass UID and section metadata for proper response matching
            let response = try await executeCommand(command, uid: uid, section: section)
            
            // FIX: Check cancellation AFTER network I/O completes but BEFORE updating state
            guard !Task.isCancelled else {
                print("📧 FETCHBODY: Task cancelled after fetch for UID \(uid), aborting state update")
                attemptedSections.removeValue(forKey: uid)
                emailFetchStartTimes.removeValue(forKey: uid)
                activeFetchTasks.removeValue(forKey: uid)
                return
            }
            
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
                    
                    // Update bodyState and legacy fields
                    let finalBody = plainBody.isEmpty ? "No content available" : plainBody
                    emails[emailIndex].body = finalBody
                    emails[emailIndex].attributedBody = attributedBody
                    emails[emailIndex].bodyState = .loaded(body: finalBody, attributedBody: attributedBody)
                    
                    // Clean up tracking for this UID on successful load
                    attemptedSections.removeValue(forKey: uid)
                    emailFetchStartTimes.removeValue(forKey: uid)
                    activeFetchTasks.removeValue(forKey: uid)
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
                        emails[emailIndex].bodyState = .loaded(body: "Email appears to be empty", attributedBody: nil)
                        attemptedSections.removeValue(forKey: uid)
                        emailFetchStartTimes.removeValue(forKey: uid)
                        activeFetchTasks.removeValue(forKey: uid)
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
                let errorMsg = "Error loading email: \(error.localizedDescription)"
                emails[emailIndex].body = errorMsg
                emails[emailIndex].attributedBody = nil
                emails[emailIndex].bodyState = .failed(message: error.localizedDescription)
                // Clean up tracking on error
                attemptedSections.removeValue(forKey: uid)
                emailFetchStartTimes.removeValue(forKey: uid)
                activeFetchTasks.removeValue(forKey: uid)
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
                guard self.selectedFolder != nil else { return }

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
    
    func appendMessage(to folderName: String, message: String, flags: [String] = []) async throws -> UInt32? {
        print("IMAP_APPEND: Starting append to folder: \(folderName)")
        
        guard isConnected else {
            print("IMAP_APPEND: Error - Not connected")
            throw IMAPError.noConnection
        }
        
        let encodedFolderName = encodeModifiedUTF7(folderName)
        print("IMAP_APPEND: Encoded folder name: \(encodedFolderName)")
        print("IMAP_APPEND: Message size: \(message.utf8.count) bytes")
        
        let messageLength = message.utf8.count
        let flagsString = flags.isEmpty ? "" : "(\(flags.joined(separator: " "))) "
        
        var fullCommand = "APPEND \"\(encodedFolderName)\" \(flagsString){\(messageLength)}\r\n"
        fullCommand += message
        fullCommand += "\r\n"
        
        print("IMAP_APPEND: Executing command")
        let response = try await executeCommand(fullCommand, timeout: 60.0)
        
        print("IMAP_APPEND: Response received: \(String(response.prefix(200)))")
        
        if let uidMatch = response.range(of: "APPENDUID \\d+ (\\d+)", options: .regularExpression) {
            let uidString = String(response[uidMatch])
            if let uidValue = uidString.components(separatedBy: " ").last,
               let uid = UInt32(uidValue) {
                print("IMAP_APPEND: Success - UID: \(uid)")
                return uid
            }
        }
        
        if response.contains("OK") && response.contains("APPEND") {
            print("IMAP_APPEND: Warning - OK but no UID in response")
            return nil
        }
        
        print("IMAP_APPEND: Failed - Response: \(response)")
        return nil
    }
    
    func copyMessage(uid: UInt32, toFolder: String) async throws {
        guard isConnected else {
            throw IMAPError.noConnection
        }
        
        print("📧 Copying message UID \(uid) to folder: \(toFolder)")
        
        let copyCommand = "UID COPY \(uid) \"\(toFolder)\""
        let _ = try await executeCommand(copyCommand)
        
        print("✅ Message copied successfully")
    }
    
    func deleteMessage(uid: UInt32) async throws {
        print("IMAP_DELETE: Starting delete for UID: \(uid)")
        
        guard isConnected else {
            print("IMAP_DELETE: Error - Not connected")
            throw IMAPError.noConnection
        }
        
        let deleteCommand = "UID STORE \(uid) +FLAGS (\\\\Deleted)"
        print("IMAP_DELETE: Executing command: \(deleteCommand)")
        
        let response = try await executeCommand(deleteCommand)
        print("IMAP_DELETE: Response: \(String(response.prefix(100)))")
        
        print("IMAP_DELETE: Message marked as deleted")
    }
    
    func expunge() async throws {
        print("IMAP_EXPUNGE: Starting expunge")
        
        guard isConnected else {
            print("IMAP_EXPUNGE: Error - Not connected")
            throw IMAPError.noConnection
        }
        
        let expungeCommand = "EXPUNGE"
        print("IMAP_EXPUNGE: Executing command")
        
        let response = try await executeCommand(expungeCommand)
        print("IMAP_EXPUNGE: Response: \(String(response.prefix(100)))")
        
        print("IMAP_EXPUNGE: Completed")
    }
    
    func moveMessage(uid: UInt32, toFolder: String) async throws {
        guard isConnected else {
            throw IMAPError.noConnection
        }
        
        print("📧 Moving message UID \(uid) to folder: \(toFolder)")
        
        try await copyMessage(uid: uid, toFolder: toFolder)
        try await deleteMessage(uid: uid)
        try await expunge()
        
        print("✅ Message moved successfully")
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
                    let attributedString = EmailHTMLParser.parseHTML(decoded)
                    let plainText = extractTextFromHTML(decoded)
                    let cleanedPlainText = removeEmailSignatureClutter(cleanWhitespace(plainText))
                    return (cleanedPlainText, attributedString)
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
            print("📧 Using emergency MIME cleanup - calling parseMimeContent")
            // Use the MIME parser for this content
            return parseMimeContent(body)
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
        
        // Ultra-aggressive final check - if the result still contains MIME patterns, apply MIME parsing
        if finalCleaned.contains("--_") || finalCleaned.contains("Content-Type:") || finalCleaned.contains("=E") {
            print("📧 ULTRA-AGGRESSIVE: Still contains MIME patterns, calling parseMimeContent")
            return parseMimeContent(finalCleaned)
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
        print("📧 COLONMIME: Starting RFC-compliant MIME parsing")
        
        // ENCODING FIX: Convert String back to Data using ISO-8859-1 to recover original bytes
        // This is necessary because Swift's ByteBuffer.getString() may have incorrectly
        // interpreted non-UTF-8 bytes as UTF-8, causing mojibake.
        // By converting back to ISO-8859-1, we recover the original bytes that VMime can
        // then properly decode according to the email's declared charset.
        guard let rawData = content.data(using: .isoLatin1) else {
            print("❌ COLONMIME: Failed to convert string to data, falling back to legacy parser")
            return parseMimeContentLegacy(content)
        }
        
        print("📧 COLONMIME: Converted string to \(rawData.count) bytes using ISO-8859-1")
        
        // Try using ColonMime library for robust MIME parsing
        do {
            let message = try MimeMessage(data: rawData)
            
            print("📧 COLONMIME: Successfully parsed email")
            print("📧 COLONMIME: Has HTML body: \(message.hasHtmlBody)")
            print("📧 COLONMIME: Has text body: \(message.hasTextBody)")
            print("📧 COLONMIME: Attachment count: \(message.attachmentCount)")
            
            // Get HTML body if available, otherwise plain text
            if message.hasHtmlBody {
                let htmlBody = message.htmlBody
                print("📧 COLONMIME: Using HTML body (\(htmlBody.count) chars)")
                
                // Convert HTML to attributed string
                let attributedString = EmailHTMLParser.parseHTML(htmlBody)
                
                // Also extract plain text for fallback
                let plainText = extractTextFromHTML(htmlBody)
                let cleanedPlainText = removeEmailSignatureClutter(cleanWhitespace(plainText))
                
                return (cleanedPlainText, attributedString)
                
            } else if message.hasTextBody {
                let textBody = message.textBody
                print("📧 COLONMIME: Using plain text body (\(textBody.count) chars)")
                
                // Clean up plain text
                let cleanedText = cleanWhitespace(textBody)
                let finalText = removeEmailSignatureClutter(cleanedText)
                // Note: No need for fixEncodingIssues() anymore - VMime handles encoding correctly with raw bytes
                
                return (finalText, nil)
            } else {
                // Try the generic body property
                let body = message.body
                if !body.isEmpty {
                    print("📧 COLONMIME: Using generic body (\(body.count) chars)")
                    
                    // Check if it's HTML
                    if body.contains("<html") || body.contains("<HTML") {
                        let attributedString = EmailHTMLParser.parseHTML(body)
                        let plainText = extractTextFromHTML(body)
                        let cleanedPlainText = removeEmailSignatureClutter(cleanWhitespace(plainText))
                        return (cleanedPlainText, attributedString)
                    } else {
                        let cleanedText = cleanWhitespace(body)
                        let finalText = removeEmailSignatureClutter(cleanedText)
                        return (finalText, nil)
                    }
                }
            }
            
            print("⚠️ COLONMIME: No body content found")
            return ("", nil)
            
        } catch MimeError.emptyInput {
            print("❌ COLONMIME: Empty input, falling back to legacy parser")
            return parseMimeContentLegacy(content)
            
        } catch MimeError.invalidFormat {
            print("⚠️ COLONMIME: Invalid MIME format, falling back to legacy parser")
            return parseMimeContentLegacy(content)
            
        } catch {
            print("❌ COLONMIME: Parse error: \(error), falling back to legacy parser")
            return parseMimeContentLegacy(content)
        }
    }
    
    // Legacy MIME parser as fallback (kept for compatibility)
    private func parseMimeContentLegacy(_ content: String) -> (String, NSAttributedString?) {
        print("📧 LEGACY MIME: Using fallback parser")
        
        // Simple fallback: try to extract text content
        let lines = content.components(separatedBy: .newlines)
        var textContent: [String] = []
        var inBody = false
        
        for line in lines {
            // Skip MIME headers
            if line.hasPrefix("Content-") || line.hasPrefix("MIME-") {
                continue
            }
            
            // Empty line indicates start of body
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inBody = true
                continue
            }
            
            // Collect body lines
            if inBody && !line.hasPrefix("--") {
                textContent.append(line)
            }
        }
        
        let rawText = textContent.joined(separator: "\n")
        
        // Try to decode if base64 or quoted-printable
        let decoded = decodeByTransferEncoding(rawText, encoding: "quoted-printable")
        let cleaned = cleanWhitespace(decoded)
        let finalText = removeEmailSignatureClutter(cleaned)
        
        print("📧 LEGACY MIME: Extracted \(finalText.count) chars")
        return (finalText, nil)
    }
    
    // MARK: - Command Execution System
    
    private func generateCommandTag() -> String {
        commandCounter += 1
        return "A\(commandCounter)"
    }
    
    private func executeCommand(_ command: String, uid: UInt32? = nil, section: String? = nil, timeout: TimeInterval = 30.0) async throws -> String {
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
            // FIX: Create PendingCommand with metadata for proper response matching
            Task { @MainActor in
                self.lastSentTag = tag
                let pendingCmd = PendingCommand(
                    tag: tag,
                    commandString: command,
                    requestedUID: uid,
                    requestedSection: section,
                    sentAt: Date(),
                    responseBuffer: "",
                    completion: { result in
                        continuation.resume(with: result)
                    }
                )
                self.pendingCommands[tag] = pendingCmd
            }
            
            // Set up timeout
            Task { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let command = pendingCommands.removeValue(forKey: tag) {
                    command.completion(.failure(IMAPError.commandTimeout))
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
                        print("❌ Failed to send command: \(error)")
                        if let command = self.pendingCommands.removeValue(forKey: tag) {
                            command.completion(.failure(error))
                        }
                    }
                }
            }
        }
    }
    
    func appendToResponseBuffer(_ data: String) {
        // FIX: Match responses using command metadata instead of response content
        var targetTag: String?
        
        // 1. Check if this is a tagged response (e.g., "A1234 OK ...")
        if let tagMatch = data.range(of: "^A\\d+\\s", options: .regularExpression) {
            targetTag = String(data[tagMatch]).trimmingCharacters(in: .whitespaces)
            print("🏷️  Tagged response for: \(targetTag!)")
        }
        // 2. For untagged FETCH responses, match by UID using COMMAND metadata
        else if data.contains("* ") && data.contains("FETCH") {
            if let uidMatch = data.range(of: "UID (\\d+)", options: .regularExpression) {
                let uidString = String(data[uidMatch]).components(separatedBy: " ").last!
                if let uid = UInt32(uidString) {
                    // FIX: Search pending commands by their requestedUID metadata
                    for (tag, cmd) in pendingCommands {
                        if cmd.requestedUID == uid {
                            targetTag = tag
                            print("✅ Matched untagged FETCH (UID \(uid)) to tag: \(tag)")
                            break
                        }
                    }
                    
                    if targetTag == nil {
                        print("⚠️  No command found requesting UID \(uid)")
                        print("   Pending: \(pendingCommands.map { "\($0.key)→UID:\($0.value.requestedUID?.description ?? "nil")" }.joined(separator: ", "))")
                    }
                }
            }
        }
        
        // 3. Fallback to lastSentTag only if single command in flight
        if targetTag == nil && pendingCommands.count == 1 {
            targetTag = lastSentTag
            print("📌 Using lastSentTag fallback: \(targetTag ?? "nil")")
        }
        
        guard let tag = targetTag else {
            print("❌ Could not determine target tag, dropping \(data.count) bytes")
            return
        }
        
        // Append to command's response buffer
        pendingCommands[tag]?.responseBuffer += data
        responseBufferLastSizes[tag] = pendingCommands[tag]?.responseBuffer.count ?? 0
        responseBufferLastUpdated[tag] = Date()
        
        parseLiteralExpectations(tag: tag)
    }
    
    private func parseLiteralExpectations(tag: String) {
        guard let command = pendingCommands[tag] else { return }
        let buffer = command.responseBuffer
        guard let bufferData = buffer.data(using: .utf8) else { return }
        
        let literalPattern = "\\{(\\d+)\\}"
        guard let regex = try? NSRegularExpression(pattern: literalPattern, options: []) else { return }
        
        let nsRange = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
        let matches = regex.matches(in: buffer, range: nsRange)
        
        if literalExpectations[tag] == nil {
            literalExpectations[tag] = []
        }
        
        var currentExpectations = literalExpectations[tag]!
        
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 2,
                  let sizeRange = Range(match.range(at: 1), in: buffer),
                  let size = Int(buffer[sizeRange]) else {
                continue
            }
            
            if index >= currentExpectations.count {
                let matchEndUtf16 = match.range.upperBound
                let matchEndIndex = buffer.utf16.index(buffer.utf16.startIndex, offsetBy: matchEndUtf16)
                let matchEndStringIndex = String.Index(matchEndIndex, within: buffer)!
                
                let prefixString = String(buffer[..<matchEndStringIndex])
                guard let prefixData = prefixString.data(using: .utf8) else { continue }
                
                var byteOffset = prefixData.count
                while byteOffset < bufferData.count {
                    let byte = bufferData[byteOffset]
                    if byte == 0x0D || byte == 0x0A {
                        byteOffset += 1
                    } else {
                        break
                    }
                }
                
                let expectation = LiteralExpectation(size: size, receivedBytes: 0, startOffset: byteOffset)
                currentExpectations.append(expectation)
                print("LITERAL_TRACK: Found literal \(index + 1) - expecting \(size) bytes at offset \(byteOffset)")
            }
            
            if index < currentExpectations.count {
                let startOffset = currentExpectations[index].startOffset
                let availableBytes = max(0, bufferData.count - startOffset)
                currentExpectations[index].receivedBytes = min(availableBytes, currentExpectations[index].size)
                
                let received = currentExpectations[index].receivedBytes
                let expected = currentExpectations[index].size
                let isComplete = currentExpectations[index].isComplete
                
                print("LITERAL_TRACK: Literal \(index + 1) - \(received)/\(expected) bytes (complete: \(isComplete))")
            }
        }
        
        literalExpectations[tag] = currentExpectations
    }
    
    func waitForBufferStabilization(tag: String) async {
        let maxWaitTime: TimeInterval = 10.0
        let checkInterval: UInt64 = 50_000_000
        
        let startTime = Date()
        
        print("LITERAL_TRACK: Wait started - tag=\(tag)")
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            try? await Task.sleep(nanoseconds: checkInterval)
            
            if areLiteralsComplete(tag: tag) {
                print("LITERAL_TRACK: All literals complete for tag=\(tag)")
                break
            }
            
            let expectations = literalExpectations[tag] ?? []
            for (index, exp) in expectations.enumerated() {
                print("LITERAL_TRACK: Literal \(index + 1) - \(exp.receivedBytes)/\(exp.size) bytes")
            }
        }
        
        if Date().timeIntervalSince(startTime) >= maxWaitTime {
            print("LITERAL_TRACK: Timeout waiting for literals - tag=\(tag)")
            let expectations = literalExpectations[tag] ?? []
            for (index, exp) in expectations.enumerated() {
                print("LITERAL_TRACK: TIMEOUT - Literal \(index + 1) incomplete: \(exp.receivedBytes)/\(exp.size) bytes")
            }
        }
        
        handleCommandResponse(tag: tag, isComplete: true)
    }
    
    private func areLiteralsComplete(tag: String) -> Bool {
        guard let expectations = literalExpectations[tag] else {
            return true
        }
        
        if expectations.isEmpty {
            return true
        }
        
        return expectations.allSatisfy { $0.isComplete }
    }
    
    func handleCommandResponse(tag: String, isComplete: Bool) {
        guard let completion = pendingCommands[tag] else { 
            return 
        }
        
        if isComplete {
            guard let command = pendingCommands[tag] else {
                print("LITERAL_TRACK: No pending command for \(tag)")
                return
            }
            
            let fullResponse = command.responseBuffer
            print("LITERAL_TRACK: Processing response - tag=\(tag), buffer=\(fullResponse.count) bytes")
            
            // Check if we have a tagged response
            if !fullResponse.contains("\(tag) ") {
                print("LITERAL_TRACK: No tagged response yet for \(tag)")
                return
            }
            
            print("LITERAL_TRACK: All literals complete, returning to caller")
            
            // FIX: Don't parse BODY responses here - let fetchBody() handle them
            // parseBodyResponse was causing double-processing and consuming responses
            if fullResponse.contains("* ") && fullResponse.contains("FETCH") {
                if fullResponse.contains("BODYSTRUCTURE") || !fullResponse.contains("BODY[") {
                    // Only parse ENVELOPE/BODYSTRUCTURE responses here
                    // BODY[] responses are handled by fetchBody()
                    parseEmailResponse(fullResponse)
                }
            }
            
            // Clean up
            let completion = command.completion
            pendingCommands.removeValue(forKey: tag)
            responseBufferLastSizes.removeValue(forKey: tag)
            responseBufferLastUpdated.removeValue(forKey: tag)
            literalExpectations.removeValue(forKey: tag)
            if lastSentTag == tag {
                lastSentTag = nil
            }
            completion(.success(fullResponse))
        }
    }
    
    private func isLiteralDataComplete(_ response: String) -> Bool {
        let bodyLiteralPattern = "BODY\\[[^\\]]*\\]\\s*\\{(\\d+)\\}"
        guard let regex = try? NSRegularExpression(pattern: bodyLiteralPattern, options: []) else {
            return true
        }
        
        guard let responseData = response.data(using: .utf8) else {
            return true
        }
        
        let nsRange = NSRange(response.startIndex..<response.endIndex, in: response)
        let matches = regex.matches(in: response, range: nsRange)
        
        if matches.isEmpty {
            return true
        }
        
        print("DRAFT_DEBUG: Checking \(matches.count) BODY[] literal(s)")
        
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let sizeRange = Range(match.range(at: 1), in: response),
                  let size = Int(response[sizeRange]) else {
                continue
            }
            
            let matchEndUtf16 = match.range.upperBound
            let matchEndIndex = response.utf16.index(response.utf16.startIndex, offsetBy: matchEndUtf16)
            let matchEndStringIndex = String.Index(matchEndIndex, within: response)!
            
            let prefixString = String(response[..<matchEndStringIndex])
            guard let prefixData = prefixString.data(using: .utf8) else {
                continue
            }
            var byteOffset = prefixData.count
            
            while byteOffset < responseData.count {
                let byte = responseData[byteOffset]
                if byte == 0x0D || byte == 0x0A {
                    byteOffset += 1
                } else {
                    break
                }
            }
            
            let remainingBytes = responseData.count - byteOffset
            if remainingBytes < size {
                print("DRAFT_DEBUG: Literal INCOMPLETE - need \(size) bytes, have \(remainingBytes)")
                return false
            }
        }
        
        return true
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

// Note: IMAPFolder, IMAPEmail, IMAPError, PaginationState, IMAPCommand, and String extension are now in Models/IMAPModels.swift
// Note: AccountManager is now in Managers/AccountManager.swift
