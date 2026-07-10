import Foundation

enum FlaskStatus {
    case starting
    case running
    case stoppedByUser
    case crashed
}

protocol FlaskSupervisorDelegate: AnyObject {
    func flaskStatusChanged(_ status: FlaskStatus)
    /// Fired at most once per health-monitor tick (~5s), piggybacking on the
    /// single shared /api/jobs request the supervisor already makes — callers
    /// must NOT start their own independent polling timer against Flask's
    /// single-threaded dev server, since overlapping pollers can fill its
    /// small listen backlog and cause connections to silently stall.
    func flaskJobsUpdated(_ jobs: [[String: Any]])
}

/// Launches and supervises `app.py`, replacing start-headless.sh's launch step.
/// Mirrors its venv-bootstrap logic, and is careful not to race with app.py's
/// own self-managed /api/quit and /api/restart process lifecycle: on any
/// unexpected exit it probes /api/jobs before deciding whether to relaunch,
/// so it recognizes when Flask's own self-respawn (from /api/restart) has
/// already taken over the port instead of double-launching.
///
/// Every decision chain (initial start, post-crash relaunch, health-monitor
/// recovery) is tagged with a monotonically increasing `generation` token.
/// Only the chain matching the current generation is allowed to act — this
/// prevents two overlapping settle/retry loops from both trying to launch a
/// process at once, which previously created a thundering-herd of probes
/// against Flask's single-threaded dev server.
final class FlaskSupervisor {
    weak var delegate: FlaskSupervisorDelegate?

    private let appDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("backup-manager")
    private let port = 8787
    /// See LocalNetwork.swift: 127.0.0.1:8787 is unreliable on this machine
    /// due to a pf loopback-NAT side effect, so probes go over the LAN IP.
    private var baseURL: URL { URL(string: "http://\(LocalNetwork.currentLANAddress() ?? "127.0.0.1"):\(port)")! }

    private var pythonPath: URL { appDir.appendingPathComponent(".venv/bin/python") }
    private var venvDir: URL { appDir.appendingPathComponent(".venv") }
    private let logPath = "/tmp/backup-manager.out"

    private var process: Process?
    private var environmentVerified = false

    /// Set (via a WKScriptMessageHandler bridge from app.js's quitApp()) right
    /// before the web UI calls POST /api/quit, so the next process exit is
    /// recognized as intentional and is not auto-relaunched.
    private var intentionalQuit = false
    private var healthTimer: DispatchSourceTimer?
    private var healthMissCount = 0

    private var generation = 0
    private var lastLaunchAttempt: Date?
    private var consecutiveFailures = 0
    private let minLaunchInterval: TimeInterval = 3
    private let maxConsecutiveFailures = 4

    func markIntentionalQuit() {
        intentionalQuit = true
    }

    func manualRestart() {
        generation += 1
        healthTimer?.cancel()
        healthTimer = nil
        consecutiveFailures = 0
        attemptLaunch(generation: generation)
    }

    func start() {
        let gen = generation
        delegate?.flaskStatusChanged(.starting)
        probe { [weak self] alive in
            guard let self, gen == self.generation else { return }
            if alive {
                self.delegate?.flaskStatusChanged(.running)
                self.beginHealthMonitor(generation: gen)
            } else {
                // ensureEnvironment() shells out synchronously (venv creation,
                // pip install) — on a first-ever launch this can take real
                // seconds over the network, and running it on the main thread
                // would beachball the whole app for that whole window.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    self.ensureEnvironment()
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        self.attemptLaunch(generation: gen)
                    }
                }
            }
        }
    }

    // MARK: - Environment bootstrap (mirrors start-headless.sh)

    private func ensureEnvironment() {
        guard !environmentVerified else { return }
        bootstrapBackendIfNeeded()
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: pythonPath.path) {
            runSync("/usr/bin/python3", ["-m", "venv", venvDir.path])
        }
        if !runSyncSucceeds(pythonPath.path, ["-c", "import flask"]) {
            runSync(pythonPath.path, ["-m", "pip", "install", "-q", "--upgrade", "pip"])
            runSync(pythonPath.path, ["-m", "pip", "install", "-q", "flask"])
        }
        environmentVerified = true
    }

    /// Fichiers/dossiers "gérés" par l'app — exactement ce que build-app.sh
    /// embarque dans Resources/backup-manager-src (voir ce script pour la
    /// même liste côté build). Tout le reste dans ~/backup-manager (jobs,
    /// venv, logs — qui vivent en fait ailleurs, dans ~/.config/backup-manager
    /// et ~/Library/Logs) n'est jamais touché par ce mécanisme.
    private static let managedBackendItems = [
        "app.py", "backup-engine.sh", "progress-parse.py", "verify-parse.py",
        "requirements.txt", "static", "docs", "bin", "lib", "THIRD-PARTY-NOTICES",
    ]

    /// Sur un Mac où l'app n'a jamais tourné, ~/backup-manager (app.py,
    /// backup-engine.sh, static/, bin/bmengine…) n'existe pas encore — le DMG
    /// ne contient que le shell Swift compilé. Sans ça, `python app.py`
    /// échoue instantanément (fichier introuvable), boucle jusqu'à
    /// maxConsecutiveFailures, puis reste bloqué en .crashed sans que rien
    /// n'ait jamais pu se lancer : on installe donc la copie embarquée
    /// (Resources/backup-manager-src) au tout premier lancement.
    ///
    /// Sur une machine DÉJÀ bootstrappée par une version antérieure, on
    /// resynchronise aussi ces mêmes fichiers à CHAQUE lancement (écrasés par
    /// la copie embarquée de la version actuelle) — sinon un Mac autre que
    /// celui de dev reste figé pour toujours sur le backend du tout premier
    /// install, et aucun correctif ultérieur (comme celui-ci) ne l'atteint
    /// jamais, même après avoir réinstallé/mis à jour l'app elle-même
    /// (constaté en usage réel : réinstaller le .app ne touche jamais
    /// ~/backup-manager, qui vit en dehors du bundle).
    ///
    /// Seule exception : si ~/backup-manager est un dépôt git (présence de
    /// .git — c'est le cas sur la machine de dev, jamais sur une install
    /// utilisateur bootstrappée), on ne touche RIEN, jamais — ça reste la
    /// copie de travail activement développée, pas un simple runtime.
    private func bootstrapBackendIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: appDir.appendingPathComponent(".git").path) else { return }
        guard let bundled = Bundle.main.url(forResource: "backup-manager-src", withExtension: nil) else {
            NSLog("FlaskSupervisor: bundled backend source (backup-manager-src) not found in app bundle — cannot sync ~/backup-manager")
            return
        }
        let firstInstall = !fm.fileExists(atPath: appDir.appendingPathComponent("app.py").path)
        do {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            for name in Self.managedBackendItems {
                let src = bundled.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dest = appDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: src, to: dest)
            }
            NSLog("FlaskSupervisor: \(firstInstall ? "bootstrapped" : "synced") ~/backup-manager from bundled resources")
        } catch {
            NSLog("FlaskSupervisor: \(firstInstall ? "bootstrap" : "sync") of ~/backup-manager failed: \(error)")
        }
    }

    @discardableResult
    private func runSync(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    private func runSyncSucceeds(_ launchPath: String, _ arguments: [String]) -> Bool {
        runSync(launchPath, arguments) == 0
    }

    // MARK: - Launch (generation-gated, rate-limited)

    /// Single entry point for "we currently believe Flask is down and should
    /// be (re)launched". Gated by `generation` so only the most recent chain
    /// can trigger a launch, and rate-limited so repeated failures back off
    /// into a persistent `.crashed` state instead of looping.
    private func attemptLaunch(generation gen: Int) {
        guard gen == generation else { return }

        if let last = lastLaunchAttempt, Date().timeIntervalSince(last) < minLaunchInterval {
            let wait = minLaunchInterval - Date().timeIntervalSince(last)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.attemptLaunch(generation: gen)
            }
            return
        }

        if consecutiveFailures >= maxConsecutiveFailures {
            delegate?.flaskStatusChanged(.crashed)
            return
        }

        lastLaunchAttempt = Date()
        launchProcess(generation: gen)
    }

    private func launchProcess(generation gen: Int) {
        delegate?.flaskStatusChanged(.starting)

        let proc = Process()
        proc.executableURL = pythonPath
        proc.arguments = ["app.py"]
        proc.currentDirectoryURL = appDir

        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            proc.standardOutput = handle
            proc.standardError = handle
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleTermination(generation: gen) }
        }

        do {
            try proc.run()
            process = proc
            waitUntilReady(generation: gen, attempt: 0)
        } catch {
            NSLog("FlaskSupervisor: failed to launch app.py: \(error)")
            consecutiveFailures += 1
            attemptLaunch(generation: gen)
        }
    }

    private func waitUntilReady(generation gen: Int, attempt: Int) {
        guard gen == generation else { return }
        guard attempt < 30 else {
            // Process is still alive (no termination fired) but never
            // answered — treat as a stuck launch and let the health
            // monitor / termination handler take it from here.
            return
        }
        probe { [weak self] alive in
            guard let self, gen == self.generation else { return }
            if alive {
                self.consecutiveFailures = 0
                self.delegate?.flaskStatusChanged(.running)
                self.beginHealthMonitor(generation: gen)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.waitUntilReady(generation: gen, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Termination handling

    private func handleTermination(generation gen: Int) {
        guard gen == generation else { return }
        process = nil

        if intentionalQuit {
            intentionalQuit = false
            healthTimer?.cancel()
            healthTimer = nil
            consecutiveFailures = 0
            delegate?.flaskStatusChanged(.stoppedByUser)
            return
        }

        // Give app.py's own self-respawn (from /api/restart) a moment to take
        // over the port before assuming this was a crash. app.py's dev server
        // is single-threaded and can legitimately stall for several seconds
        // (e.g. its /api/jobs handler shells out to /sbin/mount, which can
        // block if a network volume is briefly unresponsive) — a single
        // quick probe would misread that as "not alive" and trigger a
        // needless duplicate launch, so this retries generously before
        // concluding it's actually down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.probeWithRetries(remaining: 5, delay: 2) { alive in
                guard gen == self.generation else { return }
                if alive {
                    self.consecutiveFailures = 0
                    self.delegate?.flaskStatusChanged(.running)
                    self.beginHealthMonitor(generation: gen)
                } else {
                    self.consecutiveFailures += 1
                    self.attemptLaunch(generation: gen)
                }
            }
        }
    }

    // MARK: - Health monitor (covers processes we no longer own a handle to,
    // e.g. after a self-restart spawned a new detached process)

    private func beginHealthMonitor(generation gen: Int) {
        guard gen == generation else { return }
        healthTimer?.cancel()
        healthMissCount = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, gen == self.generation else { return }
            self.fetchJobs { jobs in
                guard gen == self.generation else { return }
                if let jobs {
                    self.healthMissCount = 0
                    self.consecutiveFailures = 0
                    self.delegate?.flaskJobsUpdated(jobs)
                } else {
                    self.healthMissCount += 1
                    if self.healthMissCount >= 3 {
                        self.healthTimer?.cancel()
                        self.healthTimer = nil
                        if self.process == nil {
                            self.attemptLaunch(generation: gen)
                        }
                    }
                }
            }
        }
        timer.resume()
        healthTimer = timer
    }

    // MARK: - Probe
    //
    // A single shared entry point for all "is Flask up" checks (fetchJobs),
    // so the app never runs more than one HTTP request against Flask's
    // single-threaded dev server at a time. Do not add a second, independent
    // polling timer elsewhere — route any additional periodic need through
    // FlaskSupervisorDelegate.flaskJobsUpdated instead.

    private func fetchJobs(completion: @escaping ([[String: Any]]?) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/jobs"))
        request.timeoutInterval = 4
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let jobs = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            DispatchQueue.main.async { completion(jobs) }
        }
        task.resume()
    }

    private func probe(completion: @escaping (Bool) -> Void) {
        fetchJobs { jobs in completion(jobs != nil) }
    }

    /// Retries `probe` up to `remaining` extra times (with `delay` seconds
    /// between attempts) before giving up, to tolerate app.py's dev server
    /// stalling briefly on a slow /sbin/mount call rather than misreading
    /// that as a crash.
    private func probeWithRetries(remaining: Int, delay: TimeInterval, completion: @escaping (Bool) -> Void) {
        probe { [weak self] alive in
            if alive || remaining <= 0 {
                completion(alive)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.probeWithRetries(remaining: remaining - 1, delay: delay, completion: completion)
                }
            }
        }
    }
}
