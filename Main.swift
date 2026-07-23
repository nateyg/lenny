import SwiftUI
import AppKit

// MARK: - Assets

enum Asset {
	static func image(_ name: String) -> NSImage? {
		guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
		return NSImage(contentsOf: url)
	}

	static let background = image("Lenny_background.png")
	static let beam = image("Lenny_beam.png")
	static let hero = image("lenny_hero.png")
	/// Closed eyelids, pre-baked at the artwork's own size and registered to it.
	static let eyelids = image("eyelids.png")

	/// Menu bar glyph. Marked as a template so macOS tints it to match the other
	/// status items instead of showing the black-on-white artwork.
	static let menuBarEyes: NSImage? = {
		guard let img = image("eyes_template.png") else { return nil }
		let h: CGFloat = 15
		let w = img.size.height > 0 ? h * img.size.width / img.size.height : h
		img.size = NSSize(width: w, height: h)
		img.isTemplate = true
		return img
	}()
}

/// Where things sit inside `Lenny_background.png`, as fractions of the artwork.
/// All measured from the PNGs rather than eyeballed, so the scene stays aligned
/// at any window size.
enum Art {
	static let aspect: CGFloat = 1280.0 / 960.0

	/// Beam image drawn this wide relative to the art, matching Storyboard 3.
	static let beamScale: CGFloat = 1.044
	static let beamRatio: CGFloat = 1404.0 / 1041.0
	/// The bright spot's center within the beam image.
	static let spotX: CGFloat = 0.228
	static let spotY: CGFloat = 0.902
	/// Where that spot sits on the floor.
	static let spotFloorY: CGFloat = 0.711
	/// Where the spot starts and where it comes to rest. Starting with its centre
	/// on the right edge means it enters half-clipped, which buys 50% more travel
	/// than starting fully on screen — the crawl reads more clearly. The chalk
	/// line sits at x≈0.34 at the spot's height, so resting half a width to its
	/// right leaves "Coding Time" readable with the light touching it.
	static let spotStartX: CGFloat = 1.0
	static let spotLineX: CGFloat = 0.52

	static let orange = Color(red: 0.914, green: 0.416, blue: 0.267)
	static func logo(_ size: CGFloat) -> Font { .custom("BomberBalloon", size: size) }
}

// MARK: - Dock

/// Works out which side of Claude we're sitting on in the Dock, so Lenny can
/// look at it. The Dock's pinned order lives in its own preferences domain;
/// there's no API for the live tile layout, so this only knows about apps that
/// are actually *kept* in the Dock — anything merely running is appended at the
/// end and isn't listed here.
enum DockNeighbors {
	private static let claudeIDs = [
		"com.anthropic.claudefordesktop",
		"com.anthropic.claude",
	]

	/// nil when either app isn't pinned, so the caller can fall back.
	static func isLeftOfClaude() -> Bool? {
		guard let defaults = UserDefaults(suiteName: "com.apple.dock"),
		      let apps = defaults.array(forKey: "persistent-apps") as? [[String: Any]]
		else { return nil }

		let ids: [String] = apps.map {
			let tile = $0["tile-data"] as? [String: Any]
			return tile?["bundle-identifier"] as? String ?? ""
		}
		guard let me = ids.firstIndex(of: Bundle.main.bundleIdentifier ?? ""),
		      let claude = ids.firstIndex(where: { claudeIDs.contains($0) })
		else { return nil }
		return me < claude
	}

	/// Swaps the running app's Dock tile so the eyes point at Claude.
	@MainActor
	static func updateIcon() {
		let name: String
		switch isLeftOfClaude() {
		case .some(true):  name = "Lenny_Icon_left of claude.png"   // we're left, so look right
		case .some(false): name = "Lenny_Icon_right of claude.png"
		case .none:        name = "Lenny_Icon.png"
		}
		if let icon = Asset.image(name) { NSApp.applicationIconImage = icon }
	}
}

// MARK: - Model

@MainActor
final class LennyModel: ObservableObject {
	/// True only when Claude Code has actually refused work.
	@Published private(set) var isLockedOut = false
	@Published private(set) var resetAt: Date?
	@Published private(set) var timeRemaining: TimeInterval = 0
	/// How far the spotlight has travelled, 0…1. Only meaningful while locked out.
	@Published private(set) var progress: Double = 0
	@Published private(set) var hasBlock = false

	@AppStorage("soundEnabled") var soundEnabled = true

	private var tick: Timer?
	private var scan: Timer?
	/// The span the spotlight is crossing: the lockout, or the 5-hour block.
	private var window: TimeInterval = TranscriptReader.blockHours
	private var didPlayReset = false
	private var demo: Task<Void, Never>?
	private var player: NSSound?

	init() {
		refresh()
		tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.updateCountdown() }
		}
		// Reading transcripts hits the disk, so do it far less often than the tick.
		scan = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.refresh() }
		}
		// Timers don't fire while the lid is shut, so a Mac that slept wakes up
		// showing whatever was true hours ago. Catch both the wake and the moment
		// you look at the window.
		for (center, name) in [
			(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
			(NotificationCenter.default, NSApplication.didBecomeActiveNotification),
		] {
			center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor in self?.refresh() }
			}
		}
	}

	deinit { tick?.invalidate(); scan?.invalidate() }

	func refresh() {
		guard demo == nil else { return }
		DockNeighbors.updateIcon()

		// Priority order. The desktop app's own usage file is the truth when you
		// code through Claude Desktop; an explicit 429 lockout still wins over it
		// (it names the reset outright); the CLI transcript is the last resort.
		if let desktop = DesktopUsage.current() {
			let maxed = desktop.isMaxed
			if maxed && !isLockedOut { bounce() }
			isLockedOut = maxed
			resetAt = desktop.resetAt
			window = desktop.resetAt.timeIntervalSince(desktop.blockStart)
			hasBlock = true
		} else if let lockout = LockoutReader.current() {
			if !isLockedOut { bounce() }        // the moment Claude Code turns you away
			isLockedOut = true
			resetAt = lockout.resetAt
			window = max(60, lockout.resetAt.timeIntervalSince(lockout.hitAt))
			hasBlock = true
		} else {
			isLockedOut = false
			let block = TranscriptReader.activeBlock()
			resetAt = block?.reset
			window = TranscriptReader.blockHours
			hasBlock = block != nil
		}
		if resetAt != nil { didPlayReset = false }
		updateCountdown()
	}

	private func updateCountdown() {
		guard demo == nil else { return }
		guard let resetAt else {
			timeRemaining = 0
			progress = 0
			return
		}

		// The light always crawls toward the line; only the stakes change. Free to
		// code, it's counting down to your window rolling over. Locked out, it's
		// counting down to when you can work again.
		let remaining = resetAt.timeIntervalSinceNow
		timeRemaining = max(0, remaining)
		progress = min(1, max(0, 1 - timeRemaining / window))

		if remaining <= 0 && !didPlayReset {
			didPlayReset = true
			playResetSound()
			bounce()
			refresh()
		}
	}

	/// Jumps the Dock icon until you look at him. `.criticalRequest` keeps
	/// bouncing until the app is activated; `.informationalRequest` bounces once.
	private func bounce() {
		NSApp.requestUserAttention(.criticalRequest)
	}

	/// Runs the whole thing in a few seconds — the locked-out state, so the
	/// countdown races in red while the spotlight crawls to the line. For showing
	/// it off without waiting five hours.
	func runDemo() {
		demo?.cancel()
		demo = Task { @MainActor in
			let steps = 150, span = 9.0
			let from = window
			isLockedOut = true
			hasBlock = true
			for step in 0...steps {
				guard !Task.isCancelled else { return }
				let t = Double(step) / Double(steps)
				progress = t
				timeRemaining = from * (1 - t)
				try? await Task.sleep(for: .milliseconds(Int(span / Double(steps) * 1000)))
			}
			timeRemaining = 0
			playResetSound()
			bounce()
			try? await Task.sleep(for: .seconds(2.5))
			demo = nil
			refresh()
		}
	}

	private func playResetSound() {
		guard soundEnabled else { return }
		for name in ["homer-woohoo.mp3", "woohoo.mp3", "woohoo.wav", "woohoo.aiff"] {
			if let url = Bundle.main.url(forResource: name, withExtension: nil),
			   let sound = NSSound(contentsOf: url, byReference: true) {
				// Held on the model: a local NSSound can be deallocated the moment
				// this returns, which cuts playback off or drops it entirely.
				player = sound
				sound.play()
				return
			}
		}
		player = NSSound(named: "Glass")
		player?.play()
	}
}

// MARK: - App

@main
struct LennyApp: App {
	@StateObject private var model = LennyModel()
	@AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

	var body: some Scene {
		WindowGroup("Lenny") {
			Group {
				if hasCompletedSetup {
					LennyWindow()
				} else {
					SetupView(hasCompletedSetup: $hasCompletedSetup)
				}
			}
			.environmentObject(model)
			.frame(minWidth: 460, minHeight: 340)
		}
		.defaultSize(width: 640, height: 518)
		.commands {
			CommandGroup(replacing: .newItem) {}
			CommandGroup(after: .toolbar) {
				Button("Preview Reset") { model.runDemo() }
					.keyboardShortcut("d")
			}
		}

		MenuBarExtra {
			MenuContent().environmentObject(model)
		} label: {
			if let eyes = Asset.menuBarEyes {
				Image(nsImage: eyes)
			} else {
				Text("👀")
			}
		}
	}
}

// MARK: - Setup

struct SetupView: View {
	@EnvironmentObject var model: LennyModel
	@Binding var hasCompletedSetup: Bool
	@State private var status: String?
	@State private var connected = false

	private var transcriptsExist: Bool {
		FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/projects")
	}

	/// The copy column is sized to what the button used to span; the button now
	/// sits at three quarters of that.
	private let copyWidth: CGFloat = 300
	private var buttonWidth: CGFloat { copyWidth * 0.75 }

	var body: some View {
		HStack(spacing: 0) {
			hero
			VStack(spacing: 20) {
				Spacer(minLength: 0)

				Text("LENNY")
					.font(Art.logo(60))

				Text("Lenny is a Claude Code usage tracker and screensaver that counts down the time until reset. Nothing leaves your Mac. Please don't tell anyone how I live.")
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.lineSpacing(2)
					.fixedSize(horizontal: false, vertical: true)
					.frame(width: copyWidth)

				Button {
					connect()
				} label: {
					Text(connected ? "Connected" : "Connect to Claude Code")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(.white)
						.padding(.vertical, 12)
						.frame(width: buttonWidth)
						.background(Capsule().fill(Art.orange))
				}
				.buttonStyle(.plain)

				if let status {
					Text(status)
						.font(.footnote)
						.foregroundStyle(connected ? .secondary : Color.orange)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
						.frame(width: copyWidth)
				}

				Spacer(minLength: 0)
			}
			.padding(.leading, 14)
			.padding(.trailing, 32)
			.frame(maxWidth: .infinity)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(nsColor: .textBackgroundColor))
	}

	/// Drawn as an overlay so his size doesn't drive the layout: he's scaled well
	/// past the window and anchored low, so the window's edge crops his legs
	/// instead of leaving him floating in the middle.
	@ViewBuilder
	private var hero: some View {
		if let img = Asset.hero {
			Color.clear
				.frame(width: 265)
				.overlay(alignment: .bottom) {
					Image(nsImage: img)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(width: 396)
						.offset(y: 40)
				}
				.clipped()
		}
	}

	/// Connecting is the whole setup, so a successful check goes straight in.
	private func connect() {
		guard transcriptsExist else {
			status = "Couldn't find ~/.claude/projects. Run Claude Code once, then try again."
			return
		}
		model.refresh()
		connected = true
		status = "Connected."
		Task {
			try? await Task.sleep(for: .milliseconds(650))
			hasCompletedSetup = true
		}
	}
}

// MARK: - Main window

struct LennyWindow: View {
	@EnvironmentObject var model: LennyModel

	var body: some View {
		GeometryReader { geo in
			// Size the scene first, then hand the status bar the same width so its
			// text lines up with the edges of the image rather than the window.
			let art = fittedSize(in: CGSize(width: geo.size.width,
			                                height: geo.size.height - StatusBar.height))
			VStack(spacing: 0) {
				BarFloor(size: art)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
				StatusBar(width: art.width)
			}
		}
		.background(Color.black)
		.preferredColorScheme(.dark)
		.background(WindowAspectLock(aspect: Art.aspect, extraHeight: StatusBar.height))
	}

	private func fittedSize(in size: CGSize) -> CGSize {
		let w = min(size.width, size.height * Art.aspect)
		return CGSize(width: w, height: w / Art.aspect)
	}
}

/// The bar floor: background, the travelling spotlight, and Lenny's blink.
///
/// Everything above the background is an overlay so it can't grow the layout —
/// the beam is far taller than the artwork and must simply be clipped at the
/// frame edge rather than pushing the scene around.
struct BarFloor: View {
	@EnvironmentObject var model: LennyModel
	let size: CGSize

	@State private var eyesClosed = false

	var body: some View {
		Color.black
			.frame(width: size.width, height: size.height)
			.overlay(alignment: .topLeading) {
				if let bg = Asset.background {
					Image(nsImage: bg)
						.resizable()
						.frame(width: size.width, height: size.height)
				}
			}
			.overlay(alignment: .topLeading) {
				if let lids = Asset.eyelids {
					Image(nsImage: lids)
						.resizable()
						.frame(width: size.width, height: size.height)
						.opacity(eyesClosed ? 1 : 0)
						.allowsHitTesting(false)
				}
			}
			.overlay(alignment: .topLeading) { beam }
			.clipped()
			.task { await blinkLoop() }
	}

	@ViewBuilder
	private var beam: some View {
		if let beamImage = Asset.beam {
			let w = size.width * Art.beamScale
			let h = w * Art.beamRatio
			let spotX = Art.spotStartX + (Art.spotLineX - Art.spotStartX) * model.progress
			Image(nsImage: beamImage)
				.resizable()
				.frame(width: w, height: h)
				.offset(x: size.width * spotX - w * Art.spotX,
				        y: size.height * Art.spotFloorY - h * Art.spotY)
				.animation(.linear(duration: 0.5), value: model.progress)
				.allowsHitTesting(false)
		}
	}

	/// Lenny blinks on his own schedule, with the occasional double-blink.
	private func blinkLoop() async {
		while !Task.isCancelled {
			try? await Task.sleep(for: .milliseconds(Int.random(in: 7000...16000)))
			await blinkOnce()
			if Bool.random() && Bool.random() {
				try? await Task.sleep(for: .milliseconds(150))
				await blinkOnce()
			}
		}
	}

	private func blinkOnce() async {
		eyesClosed = true
		try? await Task.sleep(for: .milliseconds(130))
		eyesClosed = false
	}
}

/// Screensaver mode: the scene, borderless, above everything, on every display.
/// Any key or click dismisses it.
///
/// This is not a real macOS screen saver — that needs a separate `.saver` bundle
/// target that the system loads, signed and installed on its own. This is the
/// same idea you can trigger yourself.
@MainActor
enum Screensaver {
	private final class Window: NSWindow {
		override var canBecomeKey: Bool { true }    // borderless windows can't, by default
	}

	private static var windows: [NSWindow] = []
	private static var monitors: [Any] = []

	static var isRunning: Bool { !windows.isEmpty }

	static func start(_ model: LennyModel) {
		guard !isRunning else { return }
		for screen in NSScreen.screens {
			let w = Window(contentRect: screen.frame, styleMask: [.borderless],
			               backing: .buffered, defer: false)
			w.level = .screenSaver
			w.backgroundColor = .black
			w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
			w.contentView = NSHostingView(rootView: SaverView().environmentObject(model))
			w.setFrame(screen.frame, display: true)
			w.makeKeyAndOrderFront(nil)
			windows.append(w)
		}
		NSApp.activate(ignoringOtherApps: true)
		NSCursor.hide()

		// The click that launched this also emits mouse-moved, so ignore input for a
		// beat, and require a real nudge rather than a one-pixel twitch.
		let startedAt = Date()
		let origin = NSEvent.mouseLocation
		func shouldDismiss(_ event: NSEvent) -> Bool {
			guard Date().timeIntervalSince(startedAt) > 0.8 else { return false }
			guard event.type == .mouseMoved else { return true }
			let p = NSEvent.mouseLocation
			return hypot(p.x - origin.x, p.y - origin.y) > 12
		}

		let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved]
		monitors.append(NSEvent.addLocalMonitorForEvents(matching: events) { event in
			guard shouldDismiss(event) else { return event }
			stop(); return nil
		} as Any)
		monitors.append(NSEvent.addGlobalMonitorForEvents(matching: events) { event in
			if shouldDismiss(event) { stop() }
		} as Any)
	}

	static func stop() {
		guard isRunning else { return }
		monitors.forEach(NSEvent.removeMonitor)
		monitors.removeAll()
		windows.forEach { $0.orderOut(nil) }
		windows.removeAll()
		NSCursor.unhide()
	}
}

/// The scene alone, letterboxed on black, with the countdown along the bottom.
struct SaverView: View {
	@EnvironmentObject var model: LennyModel

	var body: some View {
		GeometryReader { geo in
			let w = min(geo.size.width, geo.size.height * Art.aspect)
			ZStack {
				Color.black
				BarFloor(size: CGSize(width: w, height: w / Art.aspect))
				VStack {
					Spacer()
					Text(model.hasBlock
						 ? (model.isLockedOut
							? "Resets in \(formatTime(model.timeRemaining))"
							: "New block in \(formatTime(model.timeRemaining))")
						 : "No active block")
						.font(.system(size: 22, design: .monospaced))
						.foregroundStyle(model.hasBlock
										 ? (model.isLockedOut ? Color.red : Color.green)
										 : .secondary)
						// The art runs full height, so the readout needs its own
						// backing to stay legible over the floor.
						.padding(.horizontal, 22)
						.padding(.vertical, 11)
						.background(Capsule().fill(.black.opacity(0.72)))
						.padding(.bottom, 46)
				}
			}
			.frame(width: geo.size.width, height: geo.size.height)
		}
		.ignoresSafeArea()
	}
}

/// Keeps the window proportional to the artwork (plus the status bar) so the
/// scene never letterboxes, while the green button still does normal fullscreen.
struct WindowAspectLock: NSViewRepresentable {
	let aspect: CGFloat
	let extraHeight: CGFloat

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async { apply(to: view.window) }
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		DispatchQueue.main.async { apply(to: nsView.window) }
	}

	private func apply(to window: NSWindow?) {
		guard let window, !window.styleMask.contains(.fullScreen) else { return }
		let w = window.contentLayoutRect.width
		let h = w / aspect + extraHeight
		window.contentAspectRatio = NSSize(width: w, height: h)
		// A frame restored from an earlier run won't match the ratio; snap it once.
		guard abs(window.contentLayoutRect.height - h) > 1 else { return }
		window.setContentSize(NSSize(width: w, height: h))
	}
}

struct StatusBar: View {
	static let height: CGFloat = 38

	/// The width of the scene above, so both ends line up with the image.
	let width: CGFloat

	@EnvironmentObject var model: LennyModel

	/// Red means you're actually locked out. Green means you can code.
	private var tint: Color {
		guard model.hasBlock else { return .secondary }
		return model.isLockedOut ? .red : .green
	}

	/// Locked out, the line is when your limit lifts. Free, it's when your usage
	/// window rolls over into a fresh one.
	private var label: String {
		guard model.hasBlock else { return "No active block" }
		return model.isLockedOut
			? "Resets in \(formatTime(model.timeRemaining))"
			: "New block in \(formatTime(model.timeRemaining))"
	}

	var body: some View {
		HStack(spacing: 10) {
			Circle()
				.fill(tint)
				.frame(width: 10, height: 10)

			Text(label)
				.font(.system(size: 13, design: .monospaced))
				.foregroundStyle(tint)

			if !model.hasBlock {
				Button {
					model.refresh()
				} label: {
					Image(systemName: "arrow.clockwise")
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(.white.opacity(0.75))
				}
				.buttonStyle(.plain)
				.help("Check again")
			}

			Spacer()

			Button {
				Screensaver.start(model)
			} label: {
				HStack(spacing: 6) {
					Text("Screensaver")
						.font(.system(size: 13, design: .monospaced))
					Image(systemName: "macwindow.on.rectangle")
				}
				.foregroundStyle(.white.opacity(0.75))
			}
			.buttonStyle(.plain)
			.help("Any key or mouse move exits")

			Capsule()
				.fill(.white.opacity(0.22))
				.frame(width: 1, height: 14)
				.padding(.horizontal, 4)

			Button {
				model.soundEnabled.toggle()
			} label: {
				HStack(spacing: 6) {
					Text(model.soundEnabled ? "Sound ON" : "Sound OFF")
						.font(.system(size: 13, design: .monospaced))
					Image(systemName: model.soundEnabled ? "bell.fill" : "bell.slash")
				}
				.foregroundStyle(.white.opacity(model.soundEnabled ? 0.9 : 0.5))
			}
			.buttonStyle(.plain)
			.help("Play a sound when your limit resets")
		}
		.frame(width: width)
		.frame(maxWidth: .infinity)
		.frame(height: Self.height)
		.background(.black.opacity(0.85))
	}
}

// MARK: - Menu bar

struct MenuContent: View {
	@EnvironmentObject var model: LennyModel
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		if model.hasBlock {
			Text(model.isLockedOut
				 ? "Locked out — resets in \(formatTime(model.timeRemaining))"
				 : "Free to code — new block in \(formatTime(model.timeRemaining))")
		} else {
			Text("No active usage block")
		}

		Divider()

		Button("Open Lenny") {
			openWindow(id: "Lenny")
			NSApp.activate(ignoringOtherApps: true)
		}
		Button(model.soundEnabled ? "Sound: On" : "Sound: Off") {
			model.soundEnabled.toggle()
		}
		Button("Refresh") { model.refresh() }
		Button("Start Screensaver") {
			Screensaver.start(model)
		}
		Button("Preview Reset") {
			openWindow(id: "Lenny")
			NSApp.activate(ignoringOtherApps: true)
			model.runDemo()
		}
		Button("Show Welcome Screen") {
			UserDefaults.standard.set(false, forKey: "hasCompletedSetup")
			openWindow(id: "Lenny")
			NSApp.activate(ignoringOtherApps: true)
		}

		Divider()

		Button("Quit Lenny") { NSApp.terminate(nil) }
			.keyboardShortcut("q")
	}
}

// MARK: - Helpers

func formatTime(_ seconds: TimeInterval) -> String {
	let total = Int(seconds.rounded())
	return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}
