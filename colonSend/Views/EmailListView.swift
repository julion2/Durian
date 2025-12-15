import SwiftUI

enum DateGrouping: Hashable, Comparable {
    case today, yesterday, thisWeek, lastWeek
    case month(year: Int, month: Int)

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case .month(let year, let month):
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM yyyy"
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            if let date = Calendar.current.date(from: components) {
                return formatter.string(from: date)
            }
            return "\(month)/\(year)"
        }
    }

    var sortOrder: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .thisWeek: return 2
        case .lastWeek: return 3
        case .month(let year, let month): 
            // Muss > 3 sein (nach lastWeek), neuere Monate = kleinerer Wert
            return 100 + (2100 - year) * 12 + (12 - month)
        }
    }

    static func < (lhs: DateGrouping, rhs: DateGrouping) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

struct EmailListView: View {
    let emails: [MailMessage]
    @Binding var selection: Set<String>
    let onEmailAppear: (MailMessage) -> Void
    
    // Context menu callbacks
    var onTogglePin: ((String) -> Void)?
    var onToggleRead: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    var body: some View {
        let items = buildEmailList()

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        listItemView(item)
                    }
                }
            }
            .onChange(of: selection) { _, newSelection in
                if let selectedId = newSelection.first {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(selectedId, anchor: .center)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func listItemView(_ item: ListItem) -> some View {
        switch item {
        case .header(let title, let style):
            headerView(title: title, style: style)
        case .email(let email):
            emailRow(email: email)
        }
    }
    
    @ViewBuilder
    private func headerView(title: String, style: HeaderStyle) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(style == .pinned ? .semibold : .medium)
            .foregroundStyle(style == .pinned ? Color.yellow : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .padding(.horizontal, 12)
    }
    
    // MARK: - List Building
    
    private enum HeaderStyle {
        case pinned, date
    }
    
    private enum ListItem: Identifiable {
        case header(String, HeaderStyle)
        case email(MailMessage)
        
        var id: String {
            switch self {
            case .header(let title, _): return "header-\(title)"
            case .email(let email): return email.id
            }
        }
    }
    
    private func buildEmailList() -> [ListItem] {
        var items: [ListItem] = []
        
        // Pinned emails first
        let pinnedEmails = emails.filter { $0.isPinned }.sorted { $0.timestamp > $1.timestamp }
        if !pinnedEmails.isEmpty {
            items.append(.header("Pinned", .pinned))
            items.append(contentsOf: pinnedEmails.map { .email($0) })
        }
        
        // Then unpinned emails grouped by date
        let unpinnedEmails = emails.filter { !$0.isPinned }
        let grouped = groupEmails(unpinnedEmails)
        
        for (group, groupEmails) in grouped {
            items.append(.header(group.displayName, .date))
            items.append(contentsOf: groupEmails.map { .email($0) })
        }
        
        return items
    }
    
    @ViewBuilder
    private func emailRow(email: MailMessage) -> some View {
        EmailRowView(
            email: email,
            isSelected: selection.contains(email.id),
            onTogglePin: { 
                selection = [email.id]
                onTogglePin?(email.id) 
            },
            onToggleRead: { 
                selection = [email.id]
                onToggleRead?(email.id) 
            },
            onDelete: { 
                selection = [email.id]
                onDelete?(email.id) 
            }
        )
        .id(email.id)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = [email.id]
        }
        .onAppear {
            onEmailAppear(email)
        }
    }

    private func groupEmails(_ emails: [MailMessage]) -> [(DateGrouping, [MailMessage])] {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!

        var groups: [DateGrouping: [MailMessage]] = [:]
        for email in emails {
            let emailDate = Date(timeIntervalSince1970: TimeInterval(email.timestamp))
            let group = categorizeDate(emailDate, todayStart: todayStart, yesterdayStart: yesterdayStart, thisWeekStart: thisWeekStart, lastWeekStart: lastWeekStart, calendar: calendar)
            if groups[group] == nil { groups[group] = [] }
            groups[group]?.append(email)
        }
        // Innerhalb jeder Gruppe nach timestamp sortieren (neueste zuerst)
        return groups.map { ($0.key, $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.0 < $1.0 }
    }

    private func categorizeDate(_ date: Date, todayStart: Date, yesterdayStart: Date, thisWeekStart: Date, lastWeekStart: Date, calendar: Calendar) -> DateGrouping {
        if date >= todayStart { return .today }
        else if date >= yesterdayStart { return .yesterday }
        else if date >= thisWeekStart { return .thisWeek }
        else if date >= lastWeekStart { return .lastWeek }
        else {
            let c = calendar.dateComponents([.year, .month], from: date)
            return .month(year: c.year ?? 2024, month: c.month ?? 1)
        }
    }
}
