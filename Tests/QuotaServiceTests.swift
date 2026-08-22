import XCTest
@testable import MacCLIProxyAPI

final class QuotaServiceTests: XCTestCase {
    private func failure(_ message: String) -> Result<Any, Error> {
        .failure(AppError(message))
    }

    /// The management `api-call` path hands the stored credential to xAI without refreshing it,
    /// so a 6-hour-old token 401s here while everything else still works. The credential is not
    /// broken — a real request refreshes it — so the message must point at that, not at re-auth.
    func testExpiredCredentialTellsUserHowToRecover() {
        let upstream = "Invalid or expired credentials (auth_kind=bearer, upstream=PermissionDenied)"
        let message = QuotaService.xaiFailureMessage(
            weekly: failure(upstream),
            monthly: failure(upstream)
        )
        XCTAssertTrue(message.contains("已过期"), message)
        XCTAssertTrue(message.contains("Grok"), message)
        XCTAssertFalse(message.contains("重新登录"), message)
        XCTAssertFalse(message.contains("配额请求失败"), message)
    }

    /// Anything we do not recognise still has to carry the upstream text; swallowing it is what
    /// made the original bug undiagnosable from the UI.
    func testUnknownFailureKeepsUpstreamText() {
        let message = QuotaService.xaiFailureMessage(
            weekly: failure("上游返回 503"),
            monthly: failure("上游返回 503")
        )
        XCTAssertTrue(message.contains("上游返回 503"), message)
    }

    func testFallsBackWhenUpstreamSaidNothing() {
        let message = QuotaService.xaiFailureMessage(weekly: failure(""), monthly: failure(""))
        XCTAssertEqual(message, "xAI 配额请求失败")
    }

    func testXaiWeeklyOmitsPercentWhenUnused() {
        let payload: [String: Any] = [
            "weekly": [
                "config": [
                    "currentPeriod": [
                        "type": "USAGE_PERIOD_TYPE_WEEKLY",
                        "end": "2027-01-01T00:00:00Z",
                    ],
                    "onDemandCap": ["val": 0],
                    "onDemandUsed": ["val": 0],
                    "isUnifiedBillingUser": true,
                ],
            ],
        ]
        let metrics = QuotaService.quotaMetrics(provider: .xai, payload: payload)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].label, "每周")
        XCTAssertEqual(metrics[0].remainingPercent, 100)
        XCTAssertNotNil(metrics[0].reset)
        XCTAssertEqual(QuotaService.xaiPlan(from: payload), "SuperGrok")
    }

    func testXaiMonthlyLimitZeroShowsPayAsYouGoUsed() {
        let payload: [String: Any] = [
            "monthly": [
                "config": [
                    "monthlyLimit": ["val": 0],
                    "used": ["val": 123],
                    "onDemandCap": ["val": 0],
                    "billingPeriodEnd": "2026-09-01T00:00:00+00:00",
                ],
            ],
        ]
        let metrics = QuotaService.quotaMetrics(provider: .xai, payload: payload)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].label, "本月已用（按量计费）")
        XCTAssertNil(metrics[0].remainingPercent)
        XCTAssertEqual(metrics[0].detail, "$1.23")
    }

    func testXaiRealSuperGrokWeeklyAndPayAsYouGo() {
        let payload: [String: Any] = [
            "weekly": [
                "config": [
                    "currentPeriod": [
                        "type": "USAGE_PERIOD_TYPE_WEEKLY",
                        "start": "2026-08-10T10:56:25.672140+00:00",
                        "end": "2026-08-17T10:56:25.672140+00:00",
                    ],
                    "creditUsagePercent": 1.0,
                    "productUsage": [
                        ["product": "GrokBuild", "usagePercent": 1.0],
                    ],
                    "onDemandCap": ["val": 0],
                    "onDemandUsed": ["val": 0],
                    "isUnifiedBillingUser": true,
                    "prepaidBalance": ["val": 0],
                ],
            ],
            "monthly": [
                "config": [
                    "monthlyLimit": ["val": 0],
                    "used": ["val": 123],
                    "onDemandCap": ["val": 0],
                    "billingPeriodEnd": "2026-09-01T00:00:00+00:00",
                ],
            ],
        ]
        let metrics = QuotaService.quotaMetrics(provider: .xai, payload: payload)
        XCTAssertEqual(metrics.map(\.label), ["每周", "本月已用（按量计费）", "GrokBuild"])
        XCTAssertEqual(metrics[0].remainingPercent, 99)
        XCTAssertEqual(metrics[1].detail, "$1.23")
        XCTAssertEqual(metrics[2].remainingPercent, 99)
        XCTAssertEqual(QuotaService.xaiPlan(from: payload), "SuperGrok")
    }

    func testXaiMonthlyIncludedStillShowsRemainingAndCap() {
        let payload: [String: Any] = [
            "weekly": [
                "config": [
                    "currentPeriod": ["type": "weekly", "end": "2027-01-01T00:00:00Z"],
                    "creditUsagePercent": 25,
                ],
            ],
            "monthly": [
                "config": [
                    "monthlyLimit": ["val": 1000],
                    "used": ["val": 1200],
                    "onDemandCap": ["val": 500],
                    "billingPeriodEnd": "2027-01-31T00:00:00Z",
                ],
            ],
        ]
        let metrics = QuotaService.quotaMetrics(provider: .xai, payload: payload)
        let weekly = metrics.first { $0.label == "每周" }
        let included = metrics.first { $0.label == "每月包含" }
        let onDemand = metrics.first { $0.label == "按量额度" }
        XCTAssertEqual(weekly?.remainingPercent, 75)
        XCTAssertEqual(included?.remainingPercent, 0)
        XCTAssertEqual(included?.detail, "$0.00 / $10.00")
        XCTAssertEqual(onDemand?.remainingPercent, 60)
        XCTAssertEqual(onDemand?.detail, "$3.00 / $5.00")
    }
}
