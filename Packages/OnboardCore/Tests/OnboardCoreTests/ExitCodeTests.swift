import Testing
@testable import OnboardCore

@Test func exitCodesMatchReferenceScript() {
    #expect(ExitCode.notRoot.rawValue == 10)
    #expect(ExitCode.userSessionTimeout.rawValue == 11)
    #expect(ExitCode.notADE.rawValue == 12)
    #expect(ExitCode.networkPreflightFailed.rawValue == 13)
    #expect(ExitCode.installomatorMissing.rawValue == 20)
    #expect(ExitCode.installomatorDebugUnverifiable.rawValue == 23)
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
