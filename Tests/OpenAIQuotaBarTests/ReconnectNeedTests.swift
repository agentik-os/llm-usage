import XCTest
@testable import OpenAIQuotaBar

final class ReconnectNeedTests: XCTestCase {
    func testSignInProblemsAreRecognisedAndOtherErrorsAreNot() {
        for message in ["This Claude sign-in is missing. Sign in again to reconnect it.",
                        "Claude didn’t renew this sign-in. Sign in again to reconnect it.",
                        "Claude Code isn’t signed in on this Mac. Run claude and sign in, then refresh.",
                        "This account needs a fresh sign-in before it can be used.",
                        "Please sign in again to refresh this account.", "HTTP 401 Unauthorized"] {
            XCTAssertTrue(Account.isSignInProblem(message), message)
        }
        for message in ["The network connection was lost.", "Rate limited, try again later.", "", nil] {
            XCTAssertFalse(Account.isSignInProblem(message), message ?? "nil")
        }
    }

    func testOnlyLiveAccountsWithASignInProblemNeedReconnect() {
        var account = Account.samples.first { $0.isCodex } ?? Account.samples[0]
        account.error = nil
        XCTAssertFalse(account.needsReconnect)
        account.error = "Please sign in again to refresh this account."
        XCTAssertTrue(account.needsReconnect)
        account.error = "The network connection was lost."
        XCTAssertFalse(account.needsReconnect)
    }
}
