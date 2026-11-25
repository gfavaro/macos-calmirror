import XCTest
@testable import CalmMirrorCore

final class WeekdaySelectionTests: XCTestCase {
    private func rule(_ weekdays: Set<Int> = MirrorRule.allWeekdays) -> MirrorRule {
        MirrorRule(title: "T", sourceCalendarIdentifier: "a", targetCalendarIdentifier: "b",
                   windowDays: 7, blockerLabel: "Busy", weekdays: weekdays)
    }

    func testDefaultsToEveryDay() {
        XCTAssertEqual(rule().weekdays, MirrorRule.allWeekdays)
    }

    func testAcceptsOnlySelectedStartWeekdays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let monday = DateComponents(calendar: cal, year: 2026, month: 11, day: 23, hour: 10).date!
        let tuesday = cal.date(byAdding: .day, value: 1, to: monday)!
        let r = rule([2, 4, 6]) // Mon, Wed, Fri
        XCTAssertTrue(r.acceptsWeekday(of: monday, calendar: cal))
        XCTAssertFalse(r.acceptsWeekday(of: tuesday, calendar: cal))
    }

    func testLegacyRuleDecodesWithAllWeekdays() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule([2]))) as! [String: Any]
        object.removeValue(forKey: "weekdays")
        let legacy = try JSONDecoder().decode(MirrorRule.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.weekdays, MirrorRule.allWeekdays)
    }

    func testWeekdaysRoundTrip() throws {
        let decoded = try JSONDecoder().decode(MirrorRule.self, from: JSONEncoder().encode(rule([2, 4, 6])))
        XCTAssertEqual(decoded.weekdays, [2, 4, 6])
    }

    func testValidationRejectsEmptyAndOutOfRange() {
        func validate(_ days: Set<Int>) -> MirrorRule.ValidationError? {
            MirrorRule.validate(title: "T", sourceCalendarIdentifier: "a", targetCalendarIdentifier: "b",
                                windowDays: 7, blockerLabel: "", usePlaceholder: false, weekdays: days)
        }
        XCTAssertNil(validate([2]))
        XCTAssertEqual(validate([]), .invalidWeekdays)
        XCTAssertEqual(validate([0, 8]), .invalidWeekdays)
    }

    func testParseWeekdays() {
        XCTAssertEqual(MirrorRule.parseWeekdays("mon,wed,fri"), [2, 4, 6])
        XCTAssertEqual(MirrorRule.parseWeekdays("Monday, Friday"), [2, 6])
        XCTAssertEqual(MirrorRule.parseWeekdays("weekdays"), Set(2...6))
        XCTAssertEqual(MirrorRule.parseWeekdays("weekends"), [1, 7])
        XCTAssertEqual(MirrorRule.parseWeekdays("all"), MirrorRule.allWeekdays)
        XCTAssertNil(MirrorRule.parseWeekdays("funday"))
        XCTAssertNil(MirrorRule.parseWeekdays(""))
    }
}
