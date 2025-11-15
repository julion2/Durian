# colonMime Attachment Integration Guide

**Date:** 2025-11-15  
**Purpose:** Add attachment extraction capabilities to colonMime wrapper  
**Status:** 🔧 IMPLEMENTATION GUIDE

---

## 🎯 Overview

This guide explains how to extend your colonMime C++ wrapper to handle email attachments using VMime's built-in attachment support. This will replace the broken manual IMAP parsing with battle-tested MIME parsing.

---

## 🏗️ Architecture

### Current State
```
IMAP Response → Manual String parsing → Base64 decode → ❌ 2 bytes (broken)
```

### Target State
```
IMAP Response → colonMime → VMime attachment API → ✅ Perfect files
```

---

## 📋 What VMime Already Provides

VMime (the library colonMime is based on) has full attachment support:

### C++ VMime API (Reference)
```cpp
// Get attachment count
size_t vmime::message::getAttachmentCount()

// Get specific attachment
vmime::shared_ptr<vmime::attachment> vmime::message::getAttachmentAt(size_t index)

// Attachment properties
attachment->getName()           // Filename
attachment->getType()           // MIME type
attachment->getData()           // Raw binary data
attachment->getEncoding()       // Base64, quoted-printable, etc.
attachment->getSize()           // Size in bytes
attachment->getContentDisposition()  // inline vs attachment
```

---

## 🔧 Implementation Steps

### Step 1: Add Attachment Struct to colonMime

**File:** `colonMime/Sources/colonMime/colonMime.swift` (or wherever your Swift wrapper is)

Add a new struct to represent attachments:

```swift
/// Represents an email attachment
public struct MimeAttachment {
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let size: Int
    public let contentId: String?  // For inline images
    public let isInline: Bool
    
    public init(filename: String, 
                mimeType: String, 
                data: Data, 
                size: Int,
                contentId: String? = nil,
                isInline: Bool = false) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.size = size
        self.contentId = contentId
        self.isInline = isInline
    }
}
```

---

### Step 2: Add Attachment Methods to MimeMessage Class

**File:** `colonMime/Sources/colonMime/colonMime.swift`

Add these properties/methods to your `MimeMessage` class:

```swift
public class MimeMessage {
    // ... existing properties (hasHtmlBody, hasTextBody, etc.) ...
    
    /// Number of attachments in the message
    public var attachmentCount: Int {
        // Call C++ wrapper to get vmime message->getAttachmentCount()
        return Int(colonmime_get_attachment_count(messagePtr))
    }
    
    /// Get all attachments
    public var attachments: [MimeAttachment] {
        var result: [MimeAttachment] = []
        for i in 0..<attachmentCount {
            if let attachment = getAttachment(at: i) {
                result.append(attachment)
            }
        }
        return result
    }
    
    /// Get specific attachment by index
    public func getAttachment(at index: Int) -> MimeAttachment? {
        guard index >= 0 && index < attachmentCount else {
            return nil
        }
        
        // Call C++ wrapper to get attachment data
        var filename: UnsafePointer<CChar>?
        var mimeType: UnsafePointer<CChar>?
        var data: UnsafePointer<UInt8>?
        var dataSize: Int = 0
        var contentId: UnsafePointer<CChar>?
        var isInline: Bool = false
        
        let success = colonmime_get_attachment(
            messagePtr,
            Int32(index),
            &filename,
            &mimeType,
            &data,
            &dataSize,
            &contentId,
            &isInline
        )
        
        guard success else { return nil }
        guard let data = data, dataSize > 0 else { return nil }
        
        let attachmentData = Data(bytes: data, count: dataSize)
        let filenameStr = filename.map { String(cString: $0) } ?? "attachment_\(index)"
        let mimeTypeStr = mimeType.map { String(cString: $0) } ?? "application/octet-stream"
        let contentIdStr = contentId.map { String(cString: $0) }
        
        // Free C strings if needed (depends on your C++ wrapper implementation)
        // colonmime_free_string(filename)
        // colonmime_free_string(mimeType)
        // colonmime_free_string(contentId)
        // colonmime_free_data(data)
        
        return MimeAttachment(
            filename: filenameStr,
            mimeType: mimeTypeStr,
            data: attachmentData,
            size: dataSize,
            contentId: contentIdStr,
            isInline: isInline
        )
    }
}
```

---

### Step 3: Add C++ Bridge Functions

**File:** `colonMime/Sources/colonMime/colonMime_bridge.cpp` (or similar)

Add these C++ functions to bridge VMime's attachment API:

```cpp
#include <vmime/vmime.hpp>
#include <string>
#include <vector>

// Assuming you have a way to get the vmime::shared_ptr<message> from the messagePtr
// This is pseudocode - adjust to your actual implementation

extern "C" {

/// Get attachment count
int colonmime_get_attachment_count(void* messagePtr) {
    try {
        if (!messagePtr) return 0;
        
        auto msg = static_cast<vmime::shared_ptr<vmime::message>*>(messagePtr);
        return (*msg)->getAttachmentCount();
        
    } catch (const std::exception& e) {
        // Log error
        return 0;
    }
}

/// Get attachment data
bool colonmime_get_attachment(
    void* messagePtr,
    int index,
    const char** outFilename,
    const char** outMimeType,
    const uint8_t** outData,
    size_t* outDataSize,
    const char** outContentId,
    bool* outIsInline
) {
    try {
        if (!messagePtr) return false;
        
        auto msg = static_cast<vmime::shared_ptr<vmime::message>*>(messagePtr);
        
        // Get the attachment
        auto attachment = (*msg)->getAttachmentAt(index);
        if (!attachment) return false;
        
        // Get filename
        std::string filename = attachment->getName().generate();
        *outFilename = strdup(filename.c_str());  // Caller must free
        
        // Get MIME type
        vmime::mediaType mimeType = attachment->getType();
        std::string mimeTypeStr = mimeType.generate();
        *outMimeType = strdup(mimeTypeStr.c_str());  // Caller must free
        
        // Get binary data
        vmime::utility::outputStreamByteArrayAdapter output;
        attachment->getData()->extract(output);
        
        const vmime::byteArray& bytes = output.getByteArray();
        *outDataSize = bytes.size();
        
        // Allocate and copy data (caller must free)
        uint8_t* dataCopy = (uint8_t*)malloc(bytes.size());
        memcpy(dataCopy, bytes.data(), bytes.size());
        *outData = dataCopy;
        
        // Get content-ID (for inline images)
        try {
            vmime::messageId contentId = attachment->getContentId();
            std::string contentIdStr = contentId.generate();
            *outContentId = strdup(contentIdStr.c_str());
        } catch (...) {
            *outContentId = nullptr;
        }
        
        // Check if inline
        try {
            vmime::contentDisposition disposition = attachment->getDisposition();
            *outIsInline = (disposition.getName() == vmime::contentDispositionTypes::INLINE);
        } catch (...) {
            *outIsInline = false;
        }
        
        return true;
        
    } catch (const std::exception& e) {
        // Log error: e.what()
        return false;
    }
}

/// Free strings allocated by colonMime
void colonmime_free_string(const char* str) {
    if (str) free((void*)str);
}

/// Free data allocated by colonMime
void colonmime_free_data(const uint8_t* data) {
    if (data) free((void*)data);
}

} // extern "C"
```

---

### Step 4: Add C Bridge Header

**File:** `colonMime/Sources/colonMime/include/colonMime_bridge.h`

```c
#ifndef COLONMIME_BRIDGE_H
#define COLONMIME_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Get number of attachments
int colonmime_get_attachment_count(void* messagePtr);

// Get attachment details
bool colonmime_get_attachment(
    void* messagePtr,
    int index,
    const char** outFilename,
    const char** outMimeType,
    const uint8_t** outData,
    size_t* outDataSize,
    const char** outContentId,
    bool* outIsInline
);

// Memory management
void colonmime_free_string(const char* str);
void colonmime_free_data(const uint8_t* data);

#ifdef __cplusplus
}
#endif

#endif // COLONMIME_BRIDGE_H
```

---

## 🧪 Testing colonMime Attachments

### Test 1: Simple Attachment Count

```swift
// In Swift
let testEmail = """
From: test@example.com
To: user@example.com
Subject: Test with attachment
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="boundary123"

--boundary123
Content-Type: text/plain

Hello world

--boundary123
Content-Type: application/pdf; name="test.pdf"
Content-Disposition: attachment; filename="test.pdf"
Content-Transfer-Encoding: base64

JVBERi0xLjQKJeLjz9MK...
--boundary123--
"""

guard let data = testEmail.data(using: .utf8) else { return }
let message = try MimeMessage(data: data)

print("Attachment count: \(message.attachmentCount)")  // Should be 1
```

### Test 2: Extract Attachment Data

```swift
if let attachment = message.getAttachment(at: 0) {
    print("Filename: \(attachment.filename)")      // test.pdf
    print("MIME type: \(attachment.mimeType)")     // application/pdf
    print("Size: \(attachment.size) bytes")
    print("Is inline: \(attachment.isInline)")     // false
    
    // Write to file
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.filename)
    try attachment.data.write(to: url)
    print("Saved to: \(url.path)")
}
```

---

## 🔌 Integration with colonSend

Once colonMime supports attachments, update `IMAPClient.swift`:

### Replace Broken Manual Parsing

**Before (Broken):**
```swift
func fetchAttachmentData(uid: UInt32, section: String) async throws -> Data {
    let command = "UID FETCH \(uid) (BODY.PEEK[\(section)])"
    let response = try await executeCommand(command, ...)
    
    // Complex manual parsing with byte offset bugs
    let data = try extractAttachmentFromResponse(response, ...)
    return data
}
```

**After (Clean):**
```swift
func fetchAttachmentData(uid: UInt32, section: String) async throws -> Data {
    // Fetch the entire RFC822 message
    let command = "UID FETCH \(uid) (BODY.PEEK[])"
    let response = try await executeCommand(command, ...)
    
    // Convert to Data using ISO-8859-1 (preserve raw bytes)
    guard let responseData = response.data(using: .isoLatin1) else {
        throw AttachmentError.failedToExtract
    }
    
    // Parse with colonMime
    let message = try MimeMessage(data: responseData)
    
    // Find the attachment by section number
    // Section "2" means attachment index 1 (sections are 1-based)
    let sectionNumber = Int(section) ?? 1
    let attachmentIndex = sectionNumber - 1
    
    guard attachmentIndex >= 0 && attachmentIndex < message.attachmentCount else {
        throw AttachmentError.notFound
    }
    
    guard let attachment = message.getAttachment(at: attachmentIndex) else {
        throw AttachmentError.failedToExtract
    }
    
    print("COLONMIME: Extracted \(attachment.filename) - \(attachment.size) bytes")
    return attachment.data
}
```

---

## 🎯 Alternative: Section-Specific Parsing

If you want to avoid fetching the entire message, you could fetch just the BODYSTRUCTURE to map sections to attachment indices:

```swift
// Step 1: Fetch BODYSTRUCTURE to understand message structure
let structureCmd = "UID FETCH \(uid) (BODYSTRUCTURE)"
let structure = try await executeCommand(structureCmd, ...)

// Step 2: Parse structure to determine which section is which attachment
let sectionToIndexMap = parseBodyStructure(structure)

// Step 3: Fetch full message and extract specific attachment
let messageCmd = "UID FETCH \(uid) (BODY.PEEK[])"
let response = try await executeCommand(messageCmd, ...)
guard let responseData = response.data(using: .isoLatin1) else { throw ... }

let message = try MimeMessage(data: responseData)
let attachmentIndex = sectionToIndexMap[section] ?? 0
return message.getAttachment(at: attachmentIndex)?.data ?? Data()
```

---

## 📊 Benefits Summary

| Aspect | Manual Parsing | colonMime/VMime |
|--------|----------------|-----------------|
| **Code complexity** | 150+ lines | 10 lines |
| **Byte offset bugs** | ❌ Yes (current bug) | ✅ No |
| **Encoding support** | Base64 only | All MIME encodings |
| **Binary safety** | ❌ String index issues | ✅ Native binary |
| **Maintenance** | You maintain | VMime maintains |
| **Reliability** | 🔴 Broken (2 bytes) | 🟢 Battle-tested |

---

## 🔍 Debugging Tips

### Enable VMime Debug Output

```cpp
// In your C++ bridge initialization
vmime::utility::outputStreamAdapter out(std::cout);
vmime::logging::logger::getInstance()->setDefaultLevel(vmime::logging::logLevel::DEBUG);
```

### Check What VMime Sees

```swift
let message = try MimeMessage(data: responseData)
print("VMime parsed message:")
print("  Attachments: \(message.attachmentCount)")
print("  Has HTML: \(message.hasHtmlBody)")
print("  Has Text: \(message.hasTextBody)")

for i in 0..<message.attachmentCount {
    if let att = message.getAttachment(at: i) {
        print("  [\(i)] \(att.filename) - \(att.mimeType) - \(att.size) bytes")
    }
}
```

---

## 📋 Implementation Checklist

- [ ] Add `MimeAttachment` struct to colonMime Swift wrapper
- [ ] Add `attachmentCount` property to `MimeMessage` class
- [ ] Add `getAttachment(at:)` method to `MimeMessage` class
- [ ] Implement `colonmime_get_attachment_count()` C++ bridge
- [ ] Implement `colonmime_get_attachment()` C++ bridge
- [ ] Add memory management functions for C strings/data
- [ ] Update C bridge header with new function declarations
- [ ] Test with simple email containing one attachment
- [ ] Test with email containing multiple attachments
- [ ] Test with inline images (contentId)
- [ ] Test with different encodings (Base64, quoted-printable)
- [ ] Update `IMAPClient.fetchAttachmentData()` to use colonMime
- [ ] Remove old manual parsing code (100+ lines)
- [ ] Test with real emails from IMAP server
- [ ] Verify PDFs open correctly
- [ ] Verify performance is still fast

---

## 🚀 Expected Results

After implementation:
- ✅ Attachments extract perfectly (no more 2-byte bug)
- ✅ All MIME encodings supported automatically
- ✅ Inline images work (contentId preserved)
- ✅ Multi-part attachments handled correctly
- ✅ 100+ lines of buggy code deleted
- ✅ Consistent with email body parsing (same library)

---

## 🆘 If You Get Stuck

### VMime Documentation
- Official docs: https://www.vmime.org/documentation
- Attachment examples: Check VMime source `examples/example7.cpp`

### Common Issues

**Issue:** C++ linker errors  
**Fix:** Make sure VMime is linked in your Package.swift/Xcode project

**Issue:** Memory leaks  
**Fix:** Ensure all `strdup()`/`malloc()` calls have corresponding `free()`

**Issue:** Attachments not found  
**Fix:** Print the full message structure to see what VMime parsed

---

## 📝 Notes

- VMime handles all MIME complexity for you (multipart/mixed, nested parts, etc.)
- You already have colonMime working for email bodies - attachments use the same infrastructure
- This is the **architecturally correct** solution (not a workaround)
- Once implemented, you'll never have to debug byte offset calculations again!

---

**Status:** 📖 **READY FOR IMPLEMENTATION**  
**Priority:** 🔴 **HIGH** (fixes critical 2-byte bug)  
**Estimated time:** 2-3 hours for full implementation + testing
