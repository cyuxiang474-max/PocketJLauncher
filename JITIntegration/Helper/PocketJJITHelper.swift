import ExtensionFoundation
import Foundation
import StikJIT
import XPC

// NSLog from this process goes to the system log, not the host app's
// latestlog.txt. Keep the trail so a failure can explain itself in the dialog
// the user is looking at.
private final class PJITTrail {
    static let shared = PJITTrail()
    private var lines: [String] = []
    private let lock = NSLock()

    func record(_ line: String) {
        NSLog("[PocketJJIT] %@", line)
        lock.lock()
        lines.append(line)
        if lines.count > 12 { lines.removeFirst() }
        lock.unlock()
    }

    func tail(_ count: Int = 6) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(count).joined(separator: " | ")
    }
}

private struct PocketJJITMessageHandler: XPCPeerHandler {
    func handleIncomingRequest(_ message: PocketJJITMessage) -> (any Encodable)? {
        let manager = FileManager.default
        let trail = PJITTrail.shared
        // The regular Generic helper owns a writable sandbox container.
        // StikJIT uses it for the pairing file and personalized DDI cache.
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PocketJJIT", isDirectory: true)
        let pairingURL = root.appendingPathComponent("pairingFile.plist")
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try message.pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            trail.record("targetPID=\(message.targetPID) pairingBytes=\(message.pairingData.count)")
            let paths = DDIPaths.default(in: root)
            try StikJIT.enableJIT(
                targetPID: message.targetPID,
                pairingFile: pairingURL,
                ddiPaths: paths,
                script: .universal,
                preparationProgress: { stage in
                    trail.record("ddi: \(stage)")
                },
                progress: { trail.record($0) })
            return PocketJJITMessage.Response(
                success: true,
                message: "JIT enabled by the built-in PocketJ Helper.")
        } catch {
            trail.record("FAILED: \(error.localizedDescription)")
            return PocketJJITMessage.Response(
                success: false,
                message: "\(error.localizedDescription)\n[\(trail.tail())]")
        }
    }
}

@main
struct PocketJJITHelperExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "com.Erico.PocketJLauncher",
            name: "PocketJJITHelper")
    }

    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onSessionRequest: { request in
            request.accept { _ in
                PocketJJITMessageHandler()
            }
        })
    }
}
