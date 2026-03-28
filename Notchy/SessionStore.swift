import AppKit
import AVFoundation
import SwiftUI

extension Notification.Name {
    static let NotchyHidePanel = Notification.Name("NotchyHidePanel")
    static let NotchyExpandPanel = Notification.Name("NotchyExpandPanel")
    static let NotchyNotchStatusChanged = Notification.Name("NotchyNotchStatusChanged")

}

@Observable
class SessionStore {
    static let shared = SessionStore()

    var sessions: [TerminalSession] = []
    var activeSessionId: UUID?
    var isPinned: Bool = {
        if UserDefaults.standard.object(forKey: "isPinned") == nil { return false }
        return UserDefaults.standard.bool(forKey: "isPinned")
    }() {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: "isPinned")
        }
    }
    var isTerminalExpanded = true
    var isWindowFocused = true
    var isShowingDialog = false

    /// The most recent checkpoint for the active session, used to show the undo button
    var lastCheckpoint: Checkpoint?
    /// Project name associated with lastCheckpoint
    var lastCheckpointProjectName: String?
    /// Project directory associated with lastCheckpoint
    var lastCheckpointProjectDir: String?

    /// Non-nil while a checkpoint operation is in progress (e.g. "Taking checkpoint…", "Restoring checkpoint…")
    var checkpointStatus: String?

    /// Activity token to prevent macOS idle sleep while Claude is working
    private var sleepActivity: NSObjectProtocol?

    /// Sound playback
    private var audioPlayer: AVAudioPlayer?
    private var lastSoundPlayedAt: Date = .distantPast

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionId }
    }

    /// The status color for the notch (matches tab bar colors)
    var notchStatusColor: NSColor {
        guard let session = activeSession else { return .systemGreen }
        switch session.terminalStatus {
        case .waitingForInput: return .systemRed
        case .working: return .systemYellow
        case .idle, .interrupted, .taskCompleted: return .systemGreen
        }
    }

    private static let sessionsKey = "persistedSessions"
    private static let activeSessionKey = "activeSessionId"

    init() {
        restoreSessions()
        if sessions.isEmpty {
            createQuickSession()
        }
    }

    // MARK: - Session Persistence

    private func restoreSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionsKey),
              let persisted = try? JSONDecoder().decode([PersistedSession].self, from: data),
              !persisted.isEmpty else { return }
        sessions = persisted.map { TerminalSession(persisted: $0) }
        if let savedId = UserDefaults.standard.string(forKey: Self.activeSessionKey),
           let uuid = UUID(uuidString: savedId),
           sessions.contains(where: { $0.id == uuid }) {
            activeSessionId = uuid
        } else {
            activeSessionId = sessions.first?.id
        }
        // Mark all restored sessions as started so terminals launch immediately
        for i in sessions.indices {
            sessions[i].hasStarted = true
            sessions[i].hasBeenSelected = true
        }
    }

    private func persistSessions() {
        let persisted = sessions.map { PersistedSession(id: $0.id, projectName: $0.projectName, projectPath: $0.projectPath, workingDirectory: $0.workingDirectory) }
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
        if let activeId = activeSessionId {
            UserDefaults.standard.set(activeId.uuidString, forKey: Self.activeSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeSessionKey)
        }
    }

    func updateWorkingDirectory(_ id: UUID, directory: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].workingDirectory != directory else { return }
        sessions[index].workingDirectory = directory
        persistSessions()
    }

    func selectSession(_ id: UUID) {
        activeSessionId = id
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].hasBeenSelected = true
            startSessionIfNeeded(id)
            // Expand terminal if collapsed when user taps a tab
            if !isTerminalExpanded {
                isTerminalExpanded = true
                NotificationCenter.default.post(name: .NotchyExpandPanel, object: nil)
            }
        }
        persistSessions()
    }

    /// Mark session as started (terminal will be created when view renders)
    func startSessionIfNeeded(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if !sessions[index].hasStarted {
            sessions[index].hasStarted = true
        }
    }

    /// "+" button: creates a plain terminal session with no project association
    func createQuickSession() {
        let session = TerminalSession(
            projectName: "Terminal",
            started: true
        )
        sessions.append(session)
        activeSessionId = session.id
        persistSessions()
    }

    func renameSession(_ id: UUID, to newName: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].projectName = newName
        persistSessions()
    }

    func updateTerminalStatus(_ id: UUID, status: TerminalStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].terminalStatus != status {
            let previous = sessions[index].terminalStatus
            sessions[index].terminalStatus = status
            updateSleepPrevention()

            if status == .working && previous != .working {
                sessions[index].workingStartedAt = Date()
            }
            if status == .waitingForInput && previous != .waitingForInput {
                playSound(named: "waitingForInput")
                if isPinned && !isTerminalExpanded && id == activeSessionId {
                    isTerminalExpanded = true
                    NotificationCenter.default.post(name: .NotchyExpandPanel, object: nil)
                }
            }
            else if status == .taskCompleted && previous != .taskCompleted {
                playSound(named: "taskCompleted")
            }
            else if status == .idle && previous == .working {
                // Delay 3s before treating as "task completed" — Claude sometimes
                // goes working → idle → working again briefly.
                let workingStartedAt = sessions[index].workingStartedAt
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard let idx = self.sessions.firstIndex(where: { $0.id == id }),
                          self.sessions[idx].terminalStatus == .idle else { return }
                    // Only trigger taskCompleted for tasks that ran >10s
                    if let started = workingStartedAt, Date().timeIntervalSince(started) < 10 {
                        return
                    }
                    SessionStore.shared.updateTerminalStatus(id, status: .taskCompleted)
                    // Auto-clear taskCompleted after 3 seconds
                    try? await Task.sleep(for: .seconds(3))
                    guard let idx2 = self.sessions.firstIndex(where: { $0.id == id }),
                          self.sessions[idx2].terminalStatus == .taskCompleted else { return }
                    self.sessions[idx2].terminalStatus = .idle
                    NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
                }
            }
        }
    }

    private func playSound(named name: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSoundPlayedAt) >= 1.0 else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            lastSoundPlayedAt = now
        } catch {}
    }

    private func updateSleepPrevention() {
        let anyWorking = sessions.contains { $0.terminalStatus == .working }
        if anyWorking && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Claude is working"
            )
        } else if !anyWorking, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    /// Close tab: removes the session entirely and dismisses the project from auto-detection
    /// Refresh the lastCheckpoint for the active session
    func refreshLastCheckpoint() {
        guard let session = activeSession,
              let dir = session.projectPath else {
            lastCheckpoint = nil
            lastCheckpointProjectName = nil
            lastCheckpointProjectDir = nil
            return
        }
        let projectDir = (dir as NSString).deletingLastPathComponent
        let checkpoints = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir)
        lastCheckpoint = checkpoints.first
        lastCheckpointProjectName = session.projectName
        lastCheckpointProjectDir = projectDir
    }

    /// Restore the most recent checkpoint for the active session
    func restoreLastCheckpoint() {
        guard let checkpoint = lastCheckpoint,
              let projectDir = lastCheckpointProjectDir else { return }
        checkpointStatus = "Restoring checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
            DispatchQueue.main.async {
                self.checkpointStatus = nil
                self.lastCheckpoint = nil
            }
        }
    }

    /// Create a checkpoint with progress status
    func createCheckpointForActiveSession() {
        guard let session = activeSession,
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        let projectName = session.projectName
        checkpointStatus = "Saving checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.createCheckpoint(projectName: projectName, projectDirectory: projectDir)
            DispatchQueue.main.async {
                self.refreshLastCheckpoint()
                self.checkpointStatus = nil
            }
        }
    }

    /// Create a checkpoint for a specific session by ID
    func createCheckpoint(for sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        let projectName = session.projectName
        checkpointStatus = "Saving checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.createCheckpoint(projectName: projectName, projectDirectory: projectDir)
            DispatchQueue.main.async {
                self.refreshLastCheckpoint()
                self.checkpointStatus = nil
            }
        }
    }

    /// Sessions that have a project path (eligible for checkpoints)
    var checkpointEligibleSessions: [TerminalSession] {
        sessions.filter { $0.projectPath != nil }
    }

    /// Restore a specific checkpoint for a session
    func restoreCheckpoint(_ checkpoint: Checkpoint, for sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        checkpointStatus = "Restoring checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
            DispatchQueue.main.async {
                self.checkpointStatus = nil
                self.refreshLastCheckpoint()
            }
        }
    }

    func restartSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        TerminalManager.shared.destroyTerminal(for: id)
        sessions[index].terminalStatus = .idle
        sessions[index].generation += 1
    }

    func closeSession(_ id: UUID) {
        TerminalManager.shared.destroyTerminal(for: id)
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
        persistSessions()
    }
}
