// MonoClTests/TooltipOwnerTests.swift
import AppKit
import ClaudeUsage
import Engine
import Testing

@testable import MonoCl

@MainActor
@Suite("Tooltip owner")
struct TooltipOwnerTests {
    private let now = Date(timeIntervalSince1970: 1_788_177_600)

    /// A delegate whose store holds a session reading MonoCl can vouch
    /// for, resetting two hours after `now`.
    private func delegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.store.apply(
            .samples(
                session: UsageSample(percent: 25, resetsAt: now.addingTimeInterval(2 * 3600)),
                week: nil,
                asOf: now,
                tokenExpiresAt: now.addingTimeInterval(6 * 3600)
            ))
        delegate.store.revalidate(now: now)
        return delegate
    }

    @Test("The countdown follows the clock without anything re-rendering")
    func countdownAdvancesBetweenRenders() {
        // The defect this pins: the hover text used to be composed when
        // the icon was rendered, which happens on a poll.  Between polls
        // the countdown stood still while the clock ran, so it claimed
        // more time than was left.  Nothing revalidates between these two
        // calls -- only the clock moves.
        let delegate = delegate()

        #expect(delegate.tooltipText(now: now).contains("resets in 2 hours"))
        #expect(
            delegate.tooltipText(now: now.addingTimeInterval(3600)).contains("resets in 1 hour"))
    }

    @Test("The percentage is left as of its poll, not invented at hover time")
    func percentageDoesNotDrift() {
        // Only the clock is free.  The utilisation cannot be known
        // without a fetch, so it stays exactly what the last poll said.
        let delegate = delegate()

        #expect(delegate.tooltipText(now: now.addingTimeInterval(3600)).contains("25%"))
    }

    /// Records what was handed to `addToolTip`, and what the button's
    /// bounds were at that moment.  There is no public way to read a
    /// registered tooltip rect back, so observing the call is the only
    /// way to assert anything about it.
    private final class RecordingButton: NSButton {
        static let bare = NSRect(x: 0, y: 0, width: 16, height: 22)
        static let holdingGlyph = NSRect(x: 0, y: 0, width: 50, height: 22)

        var registeredRect: NSRect?
        var boundsWhenRegistered: NSRect?
        var hadImageWhenRegistered: Bool?
        var registrationCount = 0

        /// Reproduces what a variable-length status button was measured
        /// to do on macOS 26: taking the image resizes it there and then,
        /// 16pt bare to 50pt holding the 34pt glyph.  A detached
        /// `NSButton` never lays out and stays 0x0, which would make
        /// every rect assertion below `zero == zero` and unfalsifiable.
        ///
        /// Losing the image shrinks it back, so the width is a witness to
        /// whether an image is on the button right now rather than to
        /// whether one ever was.  Were it one-way, a render that cleared
        /// the image before assigning would leave the button already wide
        /// and let an early registration pass the assertions below.
        override var image: NSImage? {
            didSet { setFrameSize(image == nil ? Self.bare.size : Self.holdingGlyph.size) }
        }

        override func addToolTip(
            _ rect: NSRect,
            owner: Any,
            userData: UnsafeMutableRawPointer?
        ) -> NSView.ToolTipTag {
            registeredRect = rect
            boundsWhenRegistered = bounds
            hadImageWhenRegistered = image != nil
            registrationCount += 1
            return super.addToolTip(rect, owner: owner, userData: userData)
        }
    }

    @Test("The rect is registered against the button as it stands once the glyph is on it")
    func rectIsRegisteredAfterTheImage() {
        // The defect this pins: the rect was registered at launch, before
        // any image existed.  A variable-length status button is sized to
        // its content, so it is narrower then than it ends up -- measured
        // on macOS 26, 16pt bare against 50pt holding a 34pt glyph.  The
        // registered rect covered the left third of the icon and hovering
        // the rest showed nothing.
        //
        // A missing tooltip is silent, so the invariant has to be caught
        // at the call: by the time the rect is registered the image is
        // already on the button, and the rect is that button's bounds
        // rather than a width captured earlier.
        let delegate = delegate()
        let button = RecordingButton(frame: RecordingButton.bare)

        delegate.renderIcon(on: button)

        #expect(button.hadImageWhenRegistered == true)
        // The width is the point: registering before the image would
        // record the bare 16pt rect, which is the defect.
        #expect(button.registeredRect == RecordingButton.holdingGlyph)
        #expect(button.registeredRect == button.boundsWhenRegistered)
    }

    @Test("A button that resizes under the rect is given a fresh one")
    func rectFollowsAFrameChange() {
        // Rendering re-takes the rect, but only a poll or a menu opening
        // makes it run.  The menu bar's thickness follows the display, so
        // the button can change size with nothing scheduled to notice --
        // and a rect describing the old size fails by showing no tooltip
        // over part of the button, which nobody can see happening.
        let delegate = delegate()
        let button = RecordingButton(frame: RecordingButton.bare)
        defer { delegate.stopObservingButtonGeometry() }
        delegate.observeButtonGeometry(button)
        delegate.renderIcon(on: button)
        #expect(button.registeredRect == RecordingButton.holdingGlyph)

        let taller = NSSize(width: 50, height: 24)
        button.setFrameSize(taller)

        #expect(button.registeredRect == NSRect(origin: .zero, size: taller))
    }

    @Test("Renders that resize nothing leave the rect where it is")
    func repeatedRendersDoNotChurnTheRect() {
        // Re-registering tears the rect down and rebuilds it, which drops
        // any tooltip on screen at the time; AppKit will not put it back
        // until the pointer leaves and returns.  A poll landing mid-hover
        // would therefore snatch the text away from the reader it was
        // just updated for.
        let delegate = delegate()
        let button = RecordingButton(frame: RecordingButton.bare)
        defer { delegate.stopObservingButtonGeometry() }
        delegate.observeButtonGeometry(button)

        delegate.renderIcon(on: button)
        delegate.renderIcon(on: button)
        delegate.renderIcon(on: button)

        #expect(button.registrationCount == 1)
    }

    @Test("Unobserving leaves the frame unwatched")
    func stopObservingStopsFollowingTheFrame() {
        // The token is held so the registration can be handed back.  If
        // it were discarded the block would outlive every attempt to stop
        // it, and nothing would say so.
        let delegate = delegate()
        let button = RecordingButton(frame: RecordingButton.bare)
        defer { delegate.stopObservingButtonGeometry() }
        delegate.observeButtonGeometry(button)
        delegate.renderIcon(on: button)
        delegate.stopObservingButtonGeometry()
        let registrationsBefore = button.registrationCount

        button.setFrameSize(NSSize(width: 50, height: 24))

        #expect(button.registrationCount == registrationsBefore)
    }

    @Test("VoiceOver is told the readings, not just the app's name")
    func statesTheReadingsAsAccessibilityHelp() {
        // A tooltip rect feeds no accessibility help; only the `toolTip`
        // property does, and the rect replaced it.  What that property
        // used to carry was the whole hover text, so anything less here
        // is a regression that is silent to everyone not using
        // VoiceOver -- the app's name alone would say nothing about
        // utilisation, resets or platform state.
        let delegate = delegate()
        let button = NSButton()

        delegate.renderIcon(on: button)

        #expect(button.accessibilityHelp() == delegate.tooltipText())
        #expect(button.accessibilityHelp()?.contains("25%") == true)
        #expect(button.accessibilityHelp()?.contains("Session") == true)
    }

    @Test("AppKit's tooltip owner call yields the same text")
    func ownerCallbackComposesTheTooltip() {
        // The owner callback is what AppKit invokes as the tooltip is
        // about to appear; it must return the composed text rather than
        // a cached string.
        let delegate = delegate()
        let button = NSButton(title: "", target: nil, action: nil)

        let text = delegate.view(button, stringForToolTip: 0, point: .zero, userData: nil)

        #expect(text.contains("Session"))
        #expect(text.contains("25%"))
        #expect(text.split(separator: "\n").count == 3)
    }
}
