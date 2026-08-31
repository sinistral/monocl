// MonoClTests/TooltipComposerTests.swift
import Foundation
import Indicators
import Testing
@testable import MonoCl

@Suite("Tooltip composition")
struct TooltipComposerTests {
    private let now = Date(timeIntervalSince1970: 1_767_000_000)

    private func reading(
        _ state: IndicatorState,
        _ detail: String
    ) -> Reading {
        Reading(state: state, detail: detail, asOf: now)
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
}
