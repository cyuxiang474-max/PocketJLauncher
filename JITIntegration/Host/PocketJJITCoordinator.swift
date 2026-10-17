import ExtensionFoundation
import Foundation
import XPC

@available(iOS 26.0, *)
private final class PocketJJITSession {
    let process: AppExtensionProcess
    let session: XPCSession

    init(process: AppExtensionProcess, session: XPCSession) {
        self.process = process
        self.session = session
    }

    deinit {
        session.cancel(reason: "PocketJ JIT request finished")
        process.invalidate()
    }
}

@objc(PocketJJITCoordinator)
public final class PocketJJITCoordinator: NSObject {
    private static var activeSession: AnyObject?

    @objc(enableJITWithTargetPID:pairingData:completion:)
    public static func enableJIT(targetPID: Int32, pairingData: Data,
                                 completion: @escaping (Bool, String) -> Void) {
        guard #available(iOS 26.0, *) else {
            completion(false, "Built-in JIT requires iOS 26 or later.")
            return
        }

        Task { @MainActor in
            do {
                NSLog("[PocketJJITCoordinator] bundleID=\(Bundle.main.bundleIdentifier ?? "(null)") bundlePath=\(Bundle.main.bundlePath)")
                NSLog("[PocketJJITCoordinator] creating Monitor for .pocketJJITHelper")
                let monitor = try await AppExtensionPoint.Monitor(
                    appExtensionPoint: .pocketJJITHelper)
                NSLog("[PocketJJITCoordinator] Monitor ok, identities=\(monitor.identities.count)")
                for identity in monitor.identities {
                    NSLog("[PocketJJITCoordinator] identity=\(String(describing: identity))")
                }
                guard let identity = monitor.identities.first else {
                    NSLog("[PocketJJITCoordinator] no identity: the system did not "
                          + "register this host's app extension")
                    throw NSError(domain: "PocketJJIT", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "PocketJ JIT Helper was not found in this installation."])
                }

                let process = try await AppExtensionProcess(configuration: .init(
                    appExtensionIdentity: identity,
                    onInterruption: { activeSession = nil }))
                let xpcSession = try process.makeXPCSession()
                try xpcSession.activate()
                activeSession = PocketJJITSession(process: process, session: xpcSession)
                let request = PocketJJITMessage(targetPID: targetPID,
                                                pairingData: pairingData)
                try xpcSession.send(request) {
                    (result: Result<PocketJJITMessage.Response, any Error>) in
                    activeSession = nil
                    switch result {
                    case .success(let response):
                        DispatchQueue.main.async {
                            completion(response.success, response.message)
                        }
                    case .failure(let error):
                        DispatchQueue.main.async {
                            completion(false, error.localizedDescription)
                        }
                    }
                }
            } catch {
                activeSession = nil
                // "Failed to add observer" carries no context on its own. Log
                // the full error so the launch log names the failing stage.
                var cursor: Error? = error
                var depth = 0
                while let current = cursor, depth < 8 {
                    let nsError = current as NSError
                    NSLog("[PocketJJITCoordinator] error[\(depth)] domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
                    cursor = nsError.userInfo[NSUnderlyingErrorKey] as? Error
                    depth += 1
                }
                NSLog("[PocketJJITCoordinator] failing stage identified above")
                let nsError = error as NSError
                completion(false,
                           "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]")
            }
        }
    }
}
