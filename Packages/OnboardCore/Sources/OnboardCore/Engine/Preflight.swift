import Foundation

public enum PreflightError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRoot
    case notADE
    case requiredEndpointsUnreachable([String])

    public var exitCode: ExitCode {
        switch self {
        case .notRoot: .notRoot
        case .notADE: .notADE
        case .requiredEndpointsUnreachable: .networkPreflightFailed
        }
    }

    public var description: String {
        switch self {
        case .notRoot:
            "must run as root"
        case .notADE:
            "device is not ADE-enrolled (requireADE is set)"
        case .requiredEndpointsUnreachable(let urls):
            "required endpoints unreachable: \(urls.joined(separator: ", "))"
        }
    }
}

/// Checks run before provisioning. Dependencies are injectable for tests.
public struct Preflight: Sendable {
    public var uid: @Sendable () -> uid_t
    public var processRunner: any ProcessRunning
    /// True when the URL responds with any HTTP status.
    public var probe: @Sendable (URL, Duration) async -> Bool

    public init(
        uid: @escaping @Sendable () -> uid_t = { getuid() },
        processRunner: any ProcessRunning = LiveProcessRunner(),
        probe: @escaping @Sendable (URL, Duration) async -> Bool = Preflight.liveProbe
    ) {
        self.uid = uid
        self.processRunner = processRunner
        self.probe = probe
    }

    public func run(configuration: Configuration) async throws {
        guard uid() == 0 else { throw PreflightError.notRoot }

        if configuration.requireADE {
            guard await isADEEnrolled() else { throw PreflightError.notADE }
        }

        let timeout = Duration.seconds(configuration.network.timeoutSeconds)

        var unreachable: [String] = []
        for url in configuration.network.requiredURLs where !(await probe(url, timeout)) {
            unreachable.append(url.absoluteString)
        }
        guard unreachable.isEmpty else {
            throw PreflightError.requiredEndpointsUnreachable(unreachable)
        }

        for url in configuration.network.warnURLs where !(await probe(url, timeout)) {
            OnboardLog.daemon.warning("warn endpoint unreachable: \(url.absoluteString, privacy: .public)")
        }
    }

    /// Parses `profiles status -type enrollment` for "Enrolled via DEP: Yes".
    public func isADEEnrolled() async -> Bool {
        guard let result = try? await processRunner.run(
            executable: "/usr/bin/profiles",
            arguments: ["status", "-type", "enrollment"],
            environment: nil,
            timeout: .seconds(30),
            lineHandler: nil
        ) else { return false }
        guard result.exitCode == 0 else { return false }
        for line in result.standardOutput.split(separator: "\n") {
            let normalized = line.lowercased()
            if normalized.contains("enrolled via dep"), normalized.contains("yes") {
                return true
            }
        }
        return false
    }

    @Sendable
    public static func liveProbe(url: URL, timeout: Duration) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = TimeInterval(timeout.components.seconds)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}
