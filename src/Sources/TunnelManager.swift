import Foundation
import AppKit

class TunnelManager {
    private var process: Process?
    private(set) var isRunning = false
    private(set) var publicURL: String?
    private let urlFoundLock = NSLock()
    
    func start(port: Int, completion: @escaping (Bool, String?) -> Void) {
        guard !isRunning else {
            completion(true, publicURL)
            return
        }
        
        // Use only the cloudflared bundled with the app (Contents/Resources,
        // same pattern as cli-proxy-api-plus) so the tunnel never depends on
        // whatever happens to be installed on the system
        var cloudflaredPath: String?
        if let resourcePath = Bundle.main.resourcePath {
            let bundledPath = (resourcePath as NSString).appendingPathComponent("cloudflared")
            // Require it to exist AND be executable — a present-but-non-executable
            // binary would otherwise pass and then fail when launched.
            if FileManager.default.fileExists(atPath: bundledPath),
               FileManager.default.isExecutableFile(atPath: bundledPath) {
                cloudflaredPath = bundledPath
            }
        }

        guard let execPath = cloudflaredPath else {
            NSLog("[TunnelManager] Bundled cloudflared not found in app Resources")
            DispatchQueue.main.async {
                self.showBundledCloudflaredMissingAlert()
            }
            completion(false, nil)
            return
        }
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: execPath)
        process?.arguments = ["tunnel", "--url", "http://localhost:\(port)"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process?.standardOutput = outputPipe
        process?.standardError = errorPipe
        
        // Parse output for URL with thread-safe flag
        var urlFound = false
        
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8) {
                // Look for the tunnel URL
                if let range = output.range(of: "https://[a-zA-Z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                    let url = String(output[range])
                    self.urlFoundLock.lock()
                    let shouldComplete = !urlFound
                    if shouldComplete { urlFound = true }
                    self.urlFoundLock.unlock()
                    
                    DispatchQueue.main.async {
                        self.publicURL = url
                        if shouldComplete {
                            completion(true, url)
                        }
                        NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                    }
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8) {
                // Also check stderr for URL
                if let range = output.range(of: "https://[a-zA-Z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                    let url = String(output[range])
                    self.urlFoundLock.lock()
                    let shouldComplete = !urlFound
                    if shouldComplete { urlFound = true }
                    self.urlFoundLock.unlock()
                    
                    DispatchQueue.main.async {
                        self.publicURL = url
                        if shouldComplete {
                            completion(true, url)
                        }
                        NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                    }
                }
            }
        }
        
        process?.terminationHandler = { [weak self] _ in
            // Clear pipe handlers to prevent memory leaks
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.publicURL = nil
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
            }
        }
        
        do {
            try process?.run()
            isRunning = true
            
            // Timeout if URL not found in 10 seconds. Terminate the slow
            // cloudflared so it can't print a URL and fire the callback later
            // against a relay that has since been torn down.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                if !urlFound {
                    self?.stop()
                    completion(false, nil)
                }
            }
        } catch {
            completion(false, nil)
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        process?.terminate()
        process = nil
        isRunning = false
        publicURL = nil
        
        NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
    }
    
    private func showBundledCloudflaredMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Bundled cloudflared Missing"
        alert.informativeText = """
        The cloudflared binary that ships inside VibeProxy.app could not be found.

        The app bundle appears to be damaged or was built without it. Reinstall VibeProxy (or rebuild with 'make install') to restore it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
