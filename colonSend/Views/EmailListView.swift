//
//  EmailListView.swift
//  colonSend
//
//  Grouped email list view (Today, Yesterday, This Week, etc.)
//

import SwiftUI

// MARK: - Date Grouping

enum DateGrouping: Hashable, Comparable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case month(year: Int, month: Int)
    
    var displayName: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .thisWeek:
            return "This Week"
        case .lastWeek:
            return "Last Week"
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
    
    /// Sort order (lower = more recent)
    var sortOrder: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .thisWeek: return 2
        case .lastWeek: return 3
        case .month(let year, let month):
            // Negative so newer months come first
            return 100 - (year * 12 + month)
        }
    }
    
    static func < (lhs: DateGrouping, rhs: DateGrouping) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - Email List View

struct EmailListView: View {
    let emails: [MailMessage]
    @Binding var selection: Set<String>
    let onEmailAppear: (MailMessage) -> Void
    
    var body: some View {
        let grouped = groupEmails(emails)
        
        List {
            ForEach(grouped, id: \.0) { group, groupEmails in
                Section {
                    ForEach(groupEmails) { email in
                        EmailRowView(email: email, isSelected: selection.contains(email.id))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = [email.id]
                            }
                            .onAppear {
                                onEmailAppear(email)
                            }
                    }
                } header: {
                    Text(group.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
    }
    
    /// Group emails by date category
    private func groupEmails(_ emails: [MailMessage]) -> [(DateGrouping, [MailMessage])] {
        let calendar = Calendar.current
        let now = Date()
        
        // Calculate date boundaries
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        
        // This week: Monday of current week
        let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
        
        var groups: [DateGrouping: [MailMessage]] = [:]
        
        for email in emails {
            let emailDate = Date(timeIntervalSince1970: TimeInterval(email.timestamp))
            let group = categorizeDate(emailDate, todayStart: todayStart, yesterdayStart: yesterdayStart, thisWeekStart: thisWeekStart, lastWeekStart: lastWeekStart, calendar: calendar)
            
            if groups[group] == nil {
                groups[group] = []
            }
            groups[group]?.append(email)
        }
        
        // Sort groups by date (most recent first)
        // Emails within each group are already sorted by notmuch
        return groups
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }
    
    private func categorizeDate(_ date: Date, todayStart: Date, yesterdayStart: Date, thisWeekStart: Date, lastWeekStart: Date, calendar: Calendar) -> DateGrouping {
        if date >= todayStart {
            return .today
        } else if date >= yesterdayStart {
            return .yesterday
        } else if date >= thisWeekStart {
            return .thisWeek
        } else if date >= lastWeekStart {
            return .lastWeek
        } else {
            // Group by month
            let components = calendar.dateComponents([.year, .month], from: date)
            return .month(year: components.year ?? 2024, month: components.month ?? 1)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selection: Set<String> = []
        
        let sampleEmails: [MailMessage] = [
            // Today
            MailMessage(threadId: "1", subject: "Meeting at 3pm", from: "Julian Schenker", date: "Today 10:00", timestamp: Int(Date().timeIntervalSince1970), tags: "inbox, unread"),
            // Yesterday
            MailMessage(threadId: "2", subject: "Your receipt", from: "Lime Receipts", date: "Yesterday", timestamp: Int(Date().addingTimeInterval(-86400).timeIntervalSince1970), tags: "inbox"),
            // This week
            MailMessage(threadId: "3", subject: "Weekly update", from: "Atlassian", date: "Mon 09:00", timestamp: Int(Date().addingTimeInterval(-172800).timeIntervalSince1970), tags: "inbox"),
            // Last week
            MailMessage(threadId: "4", subject: "Invoice #123", from: "HubSpot Billing", date: "Dec 05", timestamp: Int(Date().addingTimeInterval(-604800).timeIntervalSince1970), tags: "inbox, attachment"),
            // Older
            MailMessage(threadId: "5", subject: "Welcome!", from: "Service", date: "Nov 15", timestamp: Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970), tags: "inbox"),
        ]
        
        var body: some View {
            EmailListView(
                emails: sampleEmails,
                selection: $selection,
                onEmailAppear: { _ in }
            )
            .frame(width: 400, height: 600)
        }
    }
    
    return PreviewWrapper()
}
