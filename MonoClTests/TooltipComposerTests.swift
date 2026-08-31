// MonoClTests/TooltipComposerTests.swift
import Foundation
import Indicators
import Testing
@testable import MonoCl

@Suite("Tooltip composition")
struct TooltipComposerTests {
    // 2026-08-31 12:00:00 UTC, chosen so the offsets below land on
    // legible times: +1h is 13:00 and +24h is noon the next day.  An
    // arbitrary epoch forces every future reader to recompute the
    // expected strings, which is how the wrong literal got here.
    private let now = Date(timeIntervalSince1970: 1_788_177_600)

    private func reading(
        _ state: IndicatorState,
        _ detail: String,
        note: String? = nil
    ) -> Reading {
        Reading(state: state, detail: detail, note: note, asOf: now)
    }

    @Test("Three known readings produce three labelled lines")
    func threeLines() {
        let text = TooltipComposer.tooltip(
            session: reading(.warning, "76%"),
            week: reading(.nominal, "20%"),
            platform: reading(.nominal, "All Systems Operational"),
            sessionResetsAt: now.addingTimeInterval(3600),
            weekResetsAt: now.addingTimeInterval(86_400),
            timeZone: TimeZone(identifier: "UTC")!
        )
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("Session"))
        #expect(lines[1].hasPrefix("Week"))
        #expect(lines[2].hasPrefix("Platform"))
        #expect(lines[0].contains("76%"))
        #expect(lines[2].contains("All Systems Operational"))
    }

    @Test("A usage line shows its reset time")
    func showsResetTime() {
        let text = TooltipComposer.tooltip(
            session: reading(.nominal, "12%"),
            week: reading(.unknown, IndicatorStore.noReading),
            platform: reading(.unknown, IndicatorStore.noReading),
            sessionResetsAt: now.addingTimeInterval(3600),
            weekResetsAt: nil,
            timeZone: TimeZone(identifier: "UTC")!
        )
        let first = String(text.split(separator: "\n")[0])
        #expect(first.contains("resets"))
        #expect(first.contains("13:00"))
    }

    @Test("An unknown reading shows an em dash and no percentage")
    func unknownLine() {
        let text = TooltipComposer.tooltip(
            session: reading(.unknown, IndicatorStore.noReading),
            week: reading(.nominal, "20%"),
            platform: reading(.nominal, "All Systems Operational"),
            sessionResetsAt: nil,
            weekResetsAt: now.addingTimeInterval(86_400),
            timeZone: TimeZone(identifier: "UTC")!
        )
        let first = String(text.split(separator: "\n")[0])
        #expect(first.contains("—"))
        #expect(first.contains("no recent reading"))
        #expect(first.contains("%") == false)
    }

    @Test("A failure detail is shown verbatim")
    func failureLine() {
        let text = TooltipComposer.tooltip(
            session: reading(.unknown, "Offline"),
            week: reading(.unknown, "Offline"),
            platform: reading(.unknown, "Offline"),
            sessionResetsAt: nil,
            weekResetsAt: nil,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(text.contains("Offline"))
    }

    @Test("A retained reading's note follows the reset time")
    func noteFollowsResetTime() {
        let text = TooltipComposer.tooltip(
            session: reading(.critical, "95%", note: "Offline"),
            week: reading(.nominal, "20%"),
            platform: reading(.nominal, "All Systems Operational"),
            sessionResetsAt: now.addingTimeInterval(3600),
            weekResetsAt: now.addingTimeInterval(86_400),
            timeZone: TimeZone(identifier: "UTC")!
        )
        let first = String(text.split(separator: "\n")[0])
        #expect(first == "Session  95%  ·  resets 13:00  ·  Offline")
    }
}
