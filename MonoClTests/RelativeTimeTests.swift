// MonoClTests/RelativeTimeTests.swift
import Foundation
import Testing
@testable import MonoCl

@Suite("Relative time")
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_788_177_600)

    private func describe(_ seconds: TimeInterval) -> String {
        RelativeTime.describe(now.addingTimeInterval(seconds), from: now)
    }

    @Test("The unit is the largest whole one the interval fills")
    func largestWholeUnit() {
        // The rule this pins: 12 hours is "12 hours", never "0.5 days".
        #expect(describe(12 * 3600) == "12 hours")
        #expect(describe(90 * 60) == "1 hour")
        #expect(describe(45 * 60) == "45 minutes")
    }

    @Test("A part-filled unit is truncated, not rounded")
    func truncates() {
        // 36 hours is one whole day and most of another; rounding would
        // call it two, which overstates how long the reader has.
        #expect(describe(36 * 3600) == "1 day")
        #expect(describe(119 * 60) == "1 hour")
    }

    @Test("Each unit boundary reads as the larger unit")
    func boundaries() {
        #expect(describe(59) == "under a minute")
        #expect(describe(60) == "1 minute")
        #expect(describe(3599) == "59 minutes")
        #expect(describe(3600) == "1 hour")
        #expect(describe(86_399) == "23 hours")
        #expect(describe(86_400) == "1 day")
    }

    @Test("Days are the largest unit, so a seven-day window reads in days")
    func daysAreTheCeiling() {
        // The weekly window is seven days wide, and "7 days" is a
        // plainer statement of that than "1 week".
        #expect(describe(7 * 86_400) == "7 days")
    }

    @Test("An elapsed instant reads as the smallest bucket rather than a negative")
    func elapsed() {
        // A reading whose window has already reset is untrusted and so
        // never reaches this formatter; folding the case into the
        // smallest bucket keeps the function total without a branch
        // nothing exercises.
        #expect(describe(0) == "under a minute")
        #expect(describe(-3600) == "under a minute")
    }
}
