import XCTest
@testable import Earshot

/// Exercises ``EntitlementFactMapper`` — the verify/reject decision for a
/// single transaction result — with hand-built ``RawTransactionResult``
/// fixtures. This is the layer that would otherwise require a real or
/// `SKTestSession`-simulated StoreKit transaction to exercise; abstracting
/// StoreKit's `VerificationResult<Transaction>` down to
/// ``RawTransactionResult`` (see ``StoreKitEntitlementSource``) makes the
/// actual "unverified -> deny" / "unknown product -> deny" logic reachable
/// from a plain unit test (#634).
final class EntitlementFactMapperTests: XCTestCase {
    func testVerifiedKnownProductProducesAFact() {
        let result = RawTransactionResult.verified(
            productID: EarshotPlusProduct.plusLifetime.rawValue,
            revocationDate: nil,
            expirationDate: nil
        )
        let fact = EntitlementFactMapper.fact(from: result)
        XCTAssertEqual(fact, EntitlementFact(product: .plusLifetime))
    }

    func testVerifiedKnownProductCarriesRevocationAndExpirationThrough() {
        let revoked = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = Date(timeIntervalSince1970: 1_700_100_000)
        let result = RawTransactionResult.verified(
            productID: EarshotPlusProduct.plusMonthly.rawValue,
            revocationDate: revoked,
            expirationDate: expired
        )
        let fact = EntitlementFactMapper.fact(from: result)
        XCTAssertEqual(fact?.revocationDate, revoked)
        XCTAssertEqual(fact?.expirationDate, expired)
    }

    func testUnverifiedTransactionProducesNoFact() {
        let result = RawTransactionResult.unverified(
            productID: EarshotPlusProduct.plusLifetime.rawValue,
            reason: "signature validation failed"
        )
        XCTAssertNil(EntitlementFactMapper.fact(from: result))
    }

    func testUnverifiedTransactionForAnUnknownProductStillProducesNoFact() {
        let result = RawTransactionResult.unverified(productID: "not.a.real.product", reason: "bad JWS")
        XCTAssertNil(EntitlementFactMapper.fact(from: result))
    }

    func testVerifiedButUnrecognizedProductIDProducesNoFact() {
        let result = RawTransactionResult.verified(
            productID: "media.payown.earshot.plus.retired",
            revocationDate: nil,
            expirationDate: nil
        )
        XCTAssertNil(EntitlementFactMapper.fact(from: result))
    }

    func testVerifiedTipProductStillProducesAFact() {
        // The mapper only decides verify/reject + product recognition; whether
        // a recognized product actually grants Plus is EntitlementEngine's job
        // (tips never do — see EntitlementEngineTests).
        let result = RawTransactionResult.verified(
            productID: EarshotPlusProduct.tipSmall.rawValue,
            revocationDate: nil,
            expirationDate: nil
        )
        XCTAssertEqual(EntitlementFactMapper.fact(from: result), EntitlementFact(product: .tipSmall))
    }
}
