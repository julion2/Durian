import Foundation

extension FileManager {
    func resolveDurianPath() -> String? {
        // 1. Check ~/.local/bin/durian
        let homeURL = self.homeDirectoryForCurrentUser
        let localBinURL = homeURL.appendingPathComponent(".local/bin/durian")
        if self.fileExists(atPath: localBinURL.path) {
            return localBinURL.path
        }
        
        // 2. Check standard Homebrew path
        let brewPath = "/opt/homebrew/bin/durian"
        if self.fileExists(atPath: brewPath) {
            return brewPath
        }
        
        // 3. Fallback to /usr/local/bin
        let usrLocalPath = "/usr/local/bin/durian"
        if self.fileExists(atPath: usrLocalPath) {
            return usrLocalPath
        }
        
        return nil
    }
}
