// MonoClTests/MenuBuilderTests.swift
import AppKit
import ClaudeUsage
import Indicators
import Testing
@testable import MonoCl

@MainActor
@Suite("Menu builder")
struct MenuBuilderTests {
    private let actions = MenuBuilder.Actions(
        refresh: #selector(NSApplication.terminate(_:)),
        retry: #selector(NSApplication.terminate(_:)),
        openSettings: #selector(NSApplication.terminate(_:)),
        quit: #selector(NSApplication.terminate(_:))
    )

    private func titles(_ store: IndicatorStore) -> [String] {
        MenuBuilder.menu(store: store, target: NSApp, actions: actions)
            .items.map(\.title)
    }

    @Test("The standard items are present")
    func standardItems() {
        let store = IndicatorStore()
        let t = titles(store)
        #expect(t.contains("Refresh now"))
        #expect(t.contains("Settings…"))
        #expect(t.contains("Quit MonoCl"))
    }

    @Test("Retry appears only when polling has stopped")
    func retryVisibility() {
        let store = IndicatorStore()
        #expect(titles(store).contains("Retry") == false)

        store.apply(UsageOutcome.failure(.keychainDenied))
        #expect(titles(store).contains("Retry") == true)

        store.retryUsage()
        #expect(titles(store).contains("Retry") == false)
    }

    @Test("Each indicator gets a labelled row")
    func indicatorRows() {
        let store = IndicatorStore()
        store.revalidate(now: .now)
        let t = titles(store)
        #expect(t.contains { $0.hasPrefix("Session:") })
        #expect(t.contains { $0.hasPrefix("Week:") })
        #expect(t.contains { $0.hasPrefix("Platform:") })
    }
}
