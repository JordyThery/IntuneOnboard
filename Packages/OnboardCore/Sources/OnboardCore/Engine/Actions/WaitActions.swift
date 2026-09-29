import Foundation

/// Fixed pause. The configured seconds double as the timeout.
enum WaitAction {
    static func run(seconds: Int, timeout: Int, context: ActionContext) async -> ActionResult {
        await context.sleep(.seconds(min(seconds, timeout)))
        return ActionResult(outcome: .success, status: .done)
    }
}

/// Polls until a path exists (or is absent), up to the timeout.
enum WaitForPathAction {
    static let pollInterval = Duration.seconds(2)

    static func run(
        path: String,
        condition: ProvisioningItem.PathCondition,
        timeout: Int,
        context: ActionContext
    ) async -> ActionResult {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if satisfied(path: path, condition: condition, context: context) {
                return ActionResult(outcome: .success, status: .done)
            }
            await context.sleep(pollInterval)
        }
        // Final check so a satisfied condition right at the deadline counts.
        if satisfied(path: path, condition: condition, context: context) {
            return ActionResult(outcome: .success, status: .done)
        }
        return ActionResult(
            outcome: .failed,
            status: .timedOut,
            message: "\(path) did not become \(condition.rawValue) within \(timeout)s"
        )
    }

    private static func satisfied(path: String, condition: ProvisioningItem.PathCondition, context: ActionContext) -> Bool {
        switch condition {
        case .exists: context.fileExists(path)
        case .absent: !context.fileExists(path)
        }
    }
}
