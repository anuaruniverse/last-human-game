import SwiftUI
import Combine
import CoreTransferable
import UniformTypeIdentifiers
import AudioToolbox
import UIKit

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.68, green: 0.36, blue: 1.00)
    static let accent2 = Color(red: 0.20, green: 0.92, blue: 0.82)
    static let danger = Color(red: 1.00, green: 0.30, blue: 0.42)

    static let bgTop = Color.black
    static let bgBottom = Color(red: 0.03, green: 0.03, blue: 0.07)
}

// MARK: - Model

enum CardType: String, Codable {
    case human
    case ai
}

struct CardItem: Codable, Identifiable, Hashable {
    let id: Int
    let type: CardType
    let text: String
    let difficulty: Int
}

// MARK: - Loader

final class CardBank {
    static func load() -> [CardItem] {
        guard let url = Bundle.main.url(forResource: "cards", withExtension: "json") else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([CardItem].self, from: data)
        } catch {
            print("cards.json load error:", error)
            return []
        }
    }
}

// MARK: - Share Transferable

struct SharePNG: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.data
        }
    }
}

// MARK: - Sound + Haptics

enum GameSound {
    static func tap() {
        AudioServicesPlaySystemSound(1104)
    }

    static func success() {
        AudioServicesPlaySystemSound(1057)
    }

    static func error() {
        AudioServicesPlaySystemSound(1006)
    }

    static func trap() {
        AudioServicesPlaySystemSound(1113)
    }

    static func combo() {
        AudioServicesPlaySystemSound(1025)
    }

    static func scan() {
        AudioServicesPlaySystemSound(1157)
    }
}

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Settings

final class SettingsStore: ObservableObject {
    @Published var hardMode: Bool {
        didSet {
            UserDefaults.standard.set(hardMode, forKey: "hardMode")
        }
    }

    init() {
        self.hardMode = UserDefaults.standard.bool(forKey: "hardMode")
    }
}

// MARK: - Game ViewModel

final class GameVM: ObservableObject {
    enum Screen {
        case menu
        case game
        case win
        case lose
    }

    enum TrapMode {
        case none
        case mirror
        case invert
    }

    @Published var screen: Screen = .menu

    @Published var level: Int = max(1, UserDefaults.standard.integer(forKey: "level"))
    @Published var streak: Int = 0
    @Published var bestStreak: Int = UserDefaults.standard.integer(forKey: "bestStreak")

    @Published var timerMs: Int = 3500
    @Published var scanLeft: Int = 2
    @Published var current: CardItem?

    @Published var bannerText: String = ""
    @Published var bannerVisible: Bool = false

    @Published var confidenceText: String = ""
    @Published var confidenceVisible: Bool = false

    @Published var comboText: String = ""
    @Published var comboVisible: Bool = false

    @Published var focusMode: Bool = false
    @Published var focusCardsLeft: Int = 0

    @Published var trapActive: Bool = false

    let cardsPerLevel: Int = 12
    let baseMsPerCard: Int = 3500

    private var all: [CardItem] = []
    private var usedRecentIds: [Int] = []
    private let recentLimit = 30

    private var tickTask: Task<Void, Never>?
    private var trapMode: TrapMode = .none

    var hardMode: Bool = false

    init() {
        all = CardBank.load()

        if all.isEmpty {
            all = [
                CardItem(id: 9991, type: .human, text: "I miss you.", difficulty: 1),
                CardItem(id: 9992, type: .ai, text: "System update completed successfully.", difficulty: 1),
                CardItem(id: 9993, type: .human, text: "What should we eat tonight?", difficulty: 1),
                CardItem(id: 9994, type: .ai, text: "Optimization routine finished with 0 errors.", difficulty: 1)
            ]
        }
    }

    // MARK: - Flow

    func startGame(hardMode: Bool) {
        self.hardMode = hardMode
        streak = 0
        focusMode = false
        focusCardsLeft = 0
        scanLeft = scansForLevel(level, hardMode: hardMode)
        screen = .game
        nextCard()
        startTimer()
    }

    func tryAgain() {
        streak = 0
        focusMode = false
        focusCardsLeft = 0
        scanLeft = scansForLevel(level, hardMode: hardMode)
        screen = .game
        nextCard()
        restartTimer()
        startTimer()
    }

    func nextLevel() {
        level += 1
        UserDefaults.standard.set(level, forKey: "level")
        streak = 0
        focusMode = false
        focusCardsLeft = 0
        scanLeft = scansForLevel(level, hardMode: hardMode)
        screen = .game
        nextCard()
        restartTimer()
        startTimer()
    }

    func goMenu() {
        stopTimer()
        screen = .menu
    }

    // MARK: - Input

    func swipeRight() {
        guard screen == .game else { return }
        Haptics.light()
        GameSound.tap()

        switch trapMode {
        case .none:
            answer(.human)
        case .mirror:
            answer(.ai)
        case .invert:
            answer(.ai)
        }
    }

    func swipeLeft() {
        guard screen == .game else { return }
        Haptics.light()
        GameSound.tap()

        switch trapMode {
        case .none:
            answer(.ai)
        case .mirror:
            answer(.human)
        case .invert:
            answer(.human)
        }
    }

    func scanTap() {
        guard screen == .game else { return }
        guard scanLeft > 0 else {
            showBanner("NO SCANS LEFT")
            Haptics.medium()
            return
        }

        scanLeft -= 1

        guard let current else { return }

        let isHuman = current.type == .human
        let pct = Int.random(in: 70...90)
        let label = isHuman ? "HUMAN-LIKE" : "AI-LIKE"

        showBanner("SCAN: \(label) \(pct)%")
        timerMs += 600

        Haptics.medium()
        GameSound.scan()
    }

    // MARK: - Core Logic

    private func answer(_ chosen: CardType) {
        guard let cur = current else { return }

        if chosen == cur.type {
            streak += 1
            bestStreak = max(bestStreak, streak)
            UserDefaults.standard.set(bestStreak, forKey: "bestStreak")

            showConfidence("+\(Int.random(in: 2...6))% HUMANITY")

            if streak % 3 == 0 {
                scanLeft += 1
                showCombo("+1 SCAN")
                GameSound.combo()
            }

            if streak % 5 == 0 {
                focusMode = true
                focusCardsLeft = 3
                showCombo("FOCUS MODE")
                GameSound.combo()
            }

            if streak >= cardsPerLevel {
                win()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                self.nextCard()
                self.restartTimer()
            }

        } else {
            showConfidence("-\(Int.random(in: 5...12))% HUMANITY")
            focusMode = false
            focusCardsLeft = 0
            lose()
        }
    }

    private func win() {
        stopTimer()
        screen = .win
        Haptics.success()
        GameSound.success()
    }

    private func lose() {
        stopTimer()
        screen = .lose
        Haptics.error()
        GameSound.error()
    }

    private func nextCard() {
        timerMs = msForLevel(level)
        current = pickCard(for: level)
        rollTrapForThisCard()

        if focusMode {
            focusCardsLeft -= 1
            if focusCardsLeft <= 0 {
                focusMode = false
            }
        }
    }

    // MARK: - Traps

    private func rollTrapForThisCard() {
        trapActive = false
        trapMode = .none

        guard level >= 3 else { return }

        let chance: Int
        switch level {
        case 3...4:
            chance = hardMode ? 14 : 8
        case 5...7:
            chance = hardMode ? 22 : 14
        default:
            chance = hardMode ? 30 : 20
        }

        if Int.random(in: 0..<100) < chance {
            trapActive = true
            trapMode = Bool.random() ? .mirror : .invert

            Haptics.heavy()
            GameSound.trap()

            if !hardMode {
                let label = (trapMode == .mirror) ? "MIRROR" : "INVERT"
                showBanner("AI TRAP: \(label)")
            }
        }
    }

    // MARK: - Card Selection

    private func pickCard(for level: Int) -> CardItem {
        let maxDifficulty = difficultyForLevel(level)
        let pool = all.filter { $0.difficulty <= maxDifficulty }
        let source = pool.isEmpty ? all : pool

        let filtered = source.filter { !usedRecentIds.contains($0.id) }
        let selected = (filtered.isEmpty ? source : filtered).randomElement()!

        usedRecentIds.append(selected.id)
        if usedRecentIds.count > recentLimit {
            usedRecentIds.removeFirst()
        }

        return selected
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()

        tickTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run {
                    guard self.screen == .game else { return }

                    self.timerMs -= 50

                    if self.timerMs <= 0 {
                        self.showConfidence("-10% HUMANITY")
                        self.lose()
                    }
                }
            }
        }
    }

    private func restartTimer() {
        timerMs = msForLevel(level)
    }

    private func stopTimer() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Tuning

    private func difficultyForLevel(_ level: Int) -> Int {
        if level <= 2 { return 1 }
        if level <= 4 { return 2 }
        if level <= 6 { return 3 }
        if level <= 8 { return 4 }
        return 5
    }

    private func msForLevel(_ level: Int) -> Int {
        let base: Int

        switch level {
        case 1...2:
            base = 3500
        case 3...4:
            base = 3200
        case 5...6:
            base = 2900
        case 7...8:
            base = 2600
        case 9...10:
            base = 2350
        default:
            base = 2100
        }

        if focusMode {
            return base + 500
        }

        return base
    }

    private func scansForLevel(_ level: Int, hardMode: Bool) -> Int {
        if hardMode {
            if level <= 3 { return 1 }
            return 0
        } else {
            if level <= 3 { return 2 }
            if level <= 7 { return 1 }
            return 0
        }
    }

    // MARK: - UI Feedback

    private func showBanner(_ text: String) {
        bannerText = text
        bannerVisible = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            bannerVisible = false
        }
    }

    private func showConfidence(_ text: String) {
        confidenceText = text
        confidenceVisible = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            confidenceVisible = false
        }
    }

    private func showCombo(_ text: String) {
        comboText = text
        comboVisible = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            comboVisible = false
        }
    }
}

// MARK: - Background

struct NeonBackground: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            let x1 = 0.35 + 0.18 * sin(time * 0.30)
            let y1 = 0.25 + 0.14 * cos(time * 0.28)

            let x2 = 0.70 + 0.16 * cos(time * 0.26)
            let y2 = 0.75 + 0.12 * sin(time * 0.24)

            ZStack {
                LinearGradient(
                    colors: [Theme.bgTop, Theme.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [Theme.accent.opacity(0.16), .clear],
                    center: UnitPoint(x: x1, y: y1),
                    startRadius: 20,
                    endRadius: 520
                )

                RadialGradient(
                    colors: [Theme.accent2.opacity(0.12), .clear],
                    center: UnitPoint(x: x2, y: y2),
                    startRadius: 20,
                    endRadius: 520
                )

                Color.white.opacity(0.02)
                    .blendMode(.overlay)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Share

struct ShareCardView: View {
    let title: String
    let subtitle: String
    let badge: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.bgTop, Color(red: 0.06, green: 0.04, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Theme.accent.opacity(0.20), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 650
            )

            RadialGradient(
                colors: [Theme.accent2.opacity(0.14), .clear],
                center: .bottom,
                startRadius: 10,
                endRadius: 650
            )

            VStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(1.2)

                Text(subtitle)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .opacity(0.80)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)

                Text(badge)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )

                Spacer()

                Text("LAST HUMAN")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .opacity(0.55)
                    .padding(.bottom, 18)
            }
            .padding(.top, 28)
        }
        .frame(width: 1080, height: 1920)
    }
}

func renderSharePNG(title: String, subtitle: String, badge: String) -> SharePNG? {
    let view = ShareCardView(title: title, subtitle: subtitle, badge: badge)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2.0

    guard let uiImage = renderer.uiImage else { return nil }
    guard let data = uiImage.pngData() else { return nil }

    return SharePNG(data: data)
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var vm = GameVM()
    @StateObject private var settings = SettingsStore()

    var body: some View {
        ZStack {
            NeonBackground()

            switch vm.screen {
            case .menu:
                MenuView(vm: vm, settings: settings)
            case .game:
                GameView(vm: vm, settings: settings)
            case .win:
                WinView(vm: vm)
            case .lose:
                LoseView(vm: vm)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Menu

struct MenuView: View {
    @ObservedObject var vm: GameVM
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 10) {
                Text("LAST HUMAN")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .tracking(1.4)

                Text("Swipe to prove you're human")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .opacity(0.75)
            }

            Spacer()

            VStack(spacing: 10) {
                Toggle(isOn: $settings.hardMode) {
                    Text("Hard Mode")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent2))
                .padding(.horizontal, 22)

                Text(settings.hardMode ? "AI traps are hidden." : "AI traps are announced.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .opacity(0.60)
            }

            Button {
                vm.startGame(hardMode: settings.hardMode)
            } label: {
                Text("BEGIN TEST")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.horizontal, 22)

            Text("Current level: \(vm.level)")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .opacity(0.65)

            Spacer()
        }
    }
}

// MARK: - Game

struct GameView: View {
    @ObservedObject var vm: GameVM
    @ObservedObject var settings: SettingsStore

    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var isAnimatingOut: Bool = false

    @State private var jitterX: CGFloat = 0
    @State private var jitterY: CGFloat = 0

    @State private var breathe: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            topBar
                .padding(.horizontal, 18)
                .padding(.top, 12)

            Spacer()

            if let card = vm.current {
                ZStack {
                    SwipeCard(
                        text: card.text,
                        timerProgress: Double(max(0, vm.timerMs)) / Double(vm.baseMsPerCard),
                        glowStrength: glowStrength,
                        breathe: breathe,
                        focusMode: vm.focusMode
                    )
                    .overlay(swipeFeedbackOverlay)
                    .offset(x: dragX + jitterX, y: dragY + jitterY)
                    .rotationEffect(.degrees(Double(dragX / 18)))
                    .scaleEffect(isAnimatingOut ? 0.98 : 1.0)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragX = value.translation.width
                                dragY = value.translation.height * 0.12
                            }
                            .onEnded { _ in
                                let threshold: CGFloat = 110

                                if dragX > threshold {
                                    swipeOut(direction: .right)
                                } else if dragX < -threshold {
                                    swipeOut(direction: .left)
                                } else {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                        dragX = 0
                                        dragY = 0
                                    }
                                }
                            }
                    )
                    .onTapGesture {
                        vm.scanTap()
                    }

                    if vm.bannerVisible {
                        pill(text: vm.bannerText)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .padding(.top, -245)
                    }

                    if vm.confidenceVisible {
                        pill(text: vm.confidenceText)
                            .transition(.opacity.combined(with: .scale))
                            .padding(.top, 260)
                    }

                    if vm.comboVisible {
                        pill(text: vm.comboText)
                            .transition(.opacity.combined(with: .scale))
                            .padding(.top, 320)
                    }
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        breathe.toggle()
                    }
                }
                .onChange(of: vm.trapActive) { newValue in
                    if newValue {
                        glitchJitter()
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: vm.bannerVisible)
                .animation(.easeInOut(duration: 0.15), value: vm.confidenceVisible)
                .animation(.easeInOut(duration: 0.15), value: vm.comboVisible)
            }

            Spacer()

            bottomHint
                .padding(.bottom, 18)
        }
    }

    private var glowStrength: Double {
        min(1.0, abs(dragX) / 140.0)
    }

    private var swipeFeedbackOverlay: some View {
        ZStack {
            if dragX < 0 {
                Text("AI")
                    .font(.system(size: 58, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.danger.opacity(0.55))
                    .opacity(min(0.33, Double(abs(dragX) / 280)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
            }

            if dragX > 0 {
                Text("HUMAN")
                    .font(.system(size: 58, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.accent2.opacity(0.55))
                    .opacity(min(0.33, Double(abs(dragX) / 280)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(24)
            }
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("LEVEL \(vm.level)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .opacity(0.92)

                Text("STREAK \(vm.streak)/\(vm.cardsPerLevel)")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .opacity(0.65)

                Text("BEST \(vm.bestStreak)")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .opacity(0.50)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text("SCAN \(vm.scanLeft)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .opacity(0.85)

                if vm.focusMode {
                    Text("FOCUS")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(Theme.accent2.opacity(0.35), lineWidth: 1)
                        )
                } else if !settings.hardMode && vm.trapActive {
                    Text("TRAP")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
            }
        }
    }

    private var bottomHint: some View {
        HStack {
            Text("Swipe ← AI")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .opacity(0.65)

            Spacer()

            Text("Tap = Scan")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .opacity(0.65)

            Spacer()

            Text("Swipe → HUMAN")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .opacity(0.65)
        }
        .padding(.horizontal, 18)
    }

    private func pill(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }

    private enum SwipeDir {
        case left
        case right
    }

    private func swipeOut(direction: SwipeDir) {
        guard !isAnimatingOut else { return }
        isAnimatingOut = true

        let outX: CGFloat = (direction == .right) ? 950 : -950

        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            dragX = outX
            dragY = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            if direction == .right {
                vm.swipeRight()
            } else {
                vm.swipeLeft()
            }

            dragX = 0
            dragY = 0
            isAnimatingOut = false
        }
    }

    private func glitchJitter() {
        let steps = 7

        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.02) {
                withAnimation(.linear(duration: 0.02)) {
                    jitterX = CGFloat(Int.random(in: -7...7))
                    jitterY = CGFloat(Int.random(in: -5...5))
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                jitterX = 0
                jitterY = 0
            }
        }
    }
}

// MARK: - Card

struct SwipeCard: View {
    let text: String
    let timerProgress: Double
    let glowStrength: Double
    let breathe: Bool
    let focusMode: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.white.opacity(0.055))
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)

            if focusMode {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Theme.accent2.opacity(0.35), lineWidth: 3)
                    .blur(radius: 4)
            }

            RoundedRectangle(cornerRadius: 28)
                .stroke(Theme.accent.opacity(0.18 * glowStrength + (breathe ? 0.06 : 0.03)), lineWidth: 2)
                .blur(radius: 2)

            RoundedRectangle(cornerRadius: 28)
                .stroke(Theme.accent2.opacity(0.14 * glowStrength), lineWidth: 2)
                .blur(radius: 3)

            VStack(spacing: 14) {
                timerBar
                    .padding(.top, 14)
                    .padding(.horizontal, 16)

                Spacer()

                Text(text)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)

                Spacer()
            }
        }
        .frame(width: 340, height: 470)
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .scaleEffect(breathe ? 1.005 : 0.995)
    }

    private var timerBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent2.opacity(0.90), Theme.accent.opacity(0.88)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * max(0.0, min(1.0, timerProgress))))
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}

// MARK: - Win / Lose

struct WinView: View {
    @ObservedObject var vm: GameVM

    private var shareItem: SharePNG? {
        renderSharePNG(
            title: "HUMAN CONFIRMED",
            subtitle: "I cleared Level \(vm.level).",
            badge: "STREAK \(vm.cardsPerLevel)/\(vm.cardsPerLevel)"
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Text("HUMAN CONFIRMED")
                .font(.system(size: 28, weight: .semibold, design: .rounded))

            Text("Level \(vm.level) cleared")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .opacity(0.7)

            Spacer()

            if let shareItem {
                ShareLink(
                    item: shareItem,
                    preview: SharePreview("LAST HUMAN", image: Image(systemName: "person.fill.checkmark"))
                ) {
                    Text("SHARE")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.85))
                .padding(.horizontal, 22)
            }

            Button {
                vm.nextLevel()
            } label: {
                Text("NEXT LEVEL")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.horizontal, 22)

            Button {
                vm.goMenu()
            } label: {
                Text("MENU")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.75))
            .padding(.horizontal, 22)

            Spacer()
        }
    }
}

struct LoseView: View {
    @ObservedObject var vm: GameVM

    private var shareItem: SharePNG? {
        renderSharePNG(
            title: "AI DETECTED BOT",
            subtitle: "I failed at Level \(vm.level).\nStreak \(vm.streak)/\(vm.cardsPerLevel).",
            badge: "PROVE ME WRONG"
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Text("AI DETECTED YOU AS BOT")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)

            Text("Streak: \(vm.streak)/\(vm.cardsPerLevel)")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .opacity(0.7)

            Spacer()

            if let shareItem {
                ShareLink(
                    item: shareItem,
                    preview: SharePreview("LAST HUMAN", image: Image(systemName: "exclamationmark.triangle.fill"))
                ) {
                    Text("SHARE")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.85))
                .padding(.horizontal, 22)
            }

            Button {
                vm.tryAgain()
            } label: {
                Text("TRY AGAIN")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .padding(.horizontal, 22)

            Button {
                vm.goMenu()
            } label: {
                Text("MENU")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.75))
            .padding(.horizontal, 22)

            Spacer()
        }
    }
}
