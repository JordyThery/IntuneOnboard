import Testing
@testable import OnboardCore

/// The documented exit codes; monitoring keys off the raw values.
@Test func exitCodesAreStable() {
    #expect(ExitCode.success.rawValue == 0)
    #expect(ExitCode.notRoot.rawValue == 10)
    #expect(ExitCode.notADE.rawValue == 12)
    #expect(ExitCode.networkPreflightFailed.rawValue == 13)
    #expect(ExitCode.completedWithErrors.rawValue == 30)
}

@Test func consoleUserClassification() {
    let setup = ConsoleUser(name: "_mbsetupuser", uid: 248, gid: 248)
    #expect(setup.isSetupAssistant)
    #expect(!setup.isRealUser)

    let loginWindow = ConsoleUser(name: "loginwindow", uid: 0, gid: 0)
    #expect(loginWindow.isLoginWindow)
    #expect(!loginWindow.isRealUser)

    let user = ConsoleUser(name: "jordy", uid: 501, gid: 20)
    #expect(user.isRealUser)
}
