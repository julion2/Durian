//
//  ContentView.swift
//  colonSend
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var selectedFolder: Folder.ID? = nil
    @State private var selectedEmail: Email.ID? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedFolder) {
                Section("Email") {
                    ForEach(model.folders) { folder in
                        Label(folder.name, systemImage: folder.icon)
                    }
                }
            }.listStyle(.sidebar)
            .navigationTitle("Navigation Split View")
        } content: {
            if let folder = model.folder(id: selectedFolder) {
                List(folder.emails, selection: $selectedEmail) { email in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(email.name)
                                .font(.headline)
                            
                            Spacer()
                            
                            Text(email.date)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        
                        Text(email.subject)
                            .font(.callout)
                        
                        Text(email.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }.navigationTitle(folder.name)
            } else {
                Text("Content")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, minHeight: 240, idealHeight: 320, maxHeight: .infinity)
            }
        } detail: {
            if let email = model.email(folderId: selectedFolder, id: selectedEmail) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(email.name)
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text(email.date)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text(email.subject)
                                .font(.callout)
                        }
                        
                        Divider()
                        
                        Text(email.body)
                    }.padding(.all, 16)
                }
            } else {
                Text("Detail")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, minHeight: 240, idealHeight: 320, maxHeight: .infinity)
            }
        }
    }

    class Model: ObservableObject {
        @Published var folders: [Folder] = [
            Folder(name: "Important", icon: "folder", emails: [
                Email(name: "Steve J.", subject: "Important Meeting", body: "Please review the attached documents for tomorrow's meeting.", date: "Yesterday")
            ]),
            Folder(name: "Inbox", icon: "tray", emails: [
                Email(name: "Steve J.", subject: "Project Update", body: "The project is progressing well and we should have an update soon.", date: "Yesterday")
            ]),
            Folder(name: "Drafts", icon: "doc"),
            Folder(name: "Sent", icon: "paperplane"),
            Folder(name: "Junk", icon: "xmark.bin"),
            Folder(name: "Trash", icon: "trash"),
        ]
        
        func folder(id: Folder.ID?) -> Folder? {
            folders.first(where: { $0.id == id })
        }
        
        func email(folderId: Folder.ID?, id: Email.ID?) -> Email? {
            if let folder = folder(id: folderId) {
                folder.emails.first(where: { $0.id == id })
            } else {
                nil
            }
        }
    }
}

struct Folder: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var icon: String
    var emails: [Email] = []
}

struct Email: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subject: String
    var body: String
    var date: String
}

#Preview {
    ContentView()
}
