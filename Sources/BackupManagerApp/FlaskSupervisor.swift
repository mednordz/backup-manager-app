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
    // Pas /tmp (world-writable -- risque de symlink race sur un Mac
    // multi-utilisateurs, ce script/app est distribué publiquement) : un
    // dossier propre à l'utilisateur, comme le reste des logs de l'app.
    // Tenu synchronisé avec start-headless.sh et app.py (api_restart), qui
    // écrivent au même chemin.
    private let logPath: String = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/BackupManager")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backup-manager.out").path
    }()

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
    /// Rythme du sondage de secours en état .crashed. Lent à dessein : il ne
    /// sert qu'à se raviser, pas à surveiller.
    private let crashedRecoveryInterval: TimeInterval = 10

    func markIntentionalQuit() {
        intentionalQuit = true
        // Safety net: if no process termination follows within a reasonable
        // window (e.g. the quit request never actually reached app.py), a
        // later unrelated crash could otherwise be silently misattributed
        // to this intentional quit and skip the crash-recovery path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.intentionalQuit else { return }
            NSLog("FlaskSupervisor: markIntentionalQuit() timed out with no process exit — resetting flag")
            self.intentionalQuit = false
        }
    }

    /// Termine le process app.py, si un est en cours. Appelé depuis
    /// applicationWillTerminate — sans ça, le child process (lancé via
    /// Process(), pas dans le même groupe de process que l'app) devient
    /// orphelin et continue de tourner indéfiniment après que l'app ait
    /// quitté, gardant le port 8787 occupé pour la prochaine instance
    /// (constaté en usage réel : un process zombie datant d'un lancement
    /// précédent a survécu à plusieurs cycles quitter/relancer, y compris
    /// une désinstallation complète, et répondait toujours aux requêtes API
    /// à la place de la nouvelle instance).
    func stop() {
        guard let p = process else { return }
        p.terminationHandler = nil
        if p.isRunning {
            p.terminate()
            // Bounded wait: p.waitUntilExit() alone can block the calling
            // thread (applicationWillTerminate, on the main thread)
            // indefinitely if app.py ignores SIGTERM or is wedged. Wait on a
            // background queue instead, with a 5s timeout, and escalate to
            // SIGKILL if the process hasn't exited by then.
            let sema = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                p.waitUntilExit()
                sema.signal()
            }
            if sema.wait(timeout: .now() + 5) == .timedOut {
                NSLog("FlaskSupervisor: app.py still running 5s after SIGTERM, sending SIGKILL")
                kill(p.processIdentifier, SIGKILL)
            }
        }
        process = nil
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
        // bootstrapBackendIfNeeded() must run unconditionally, before the
        // probe and regardless of its result — previously it only ran when
        // Flask was NOT already alive, so a machine where Flask survived
        // app relaunch (or was already running for any other reason) never
        // got resynced with the bundled backend, permanently missing any
        // fix shipped in a later app update. Its own guard against
        // overwriting a `.git` dev checkout lives inside the function
        // itself, so calling it more often doesn't weaken that protection.
        // File I/O -> off the main thread, same reasoning as ensureEnvironment() below.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.bootstrapBackendIfNeeded()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.probe { [weak self] alive in
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
        }
    }

    // MARK: - Environment bootstrap (mirrors start-headless.sh)

    private func ensureEnvironment() {
        guard !environmentVerified else { return }
        // bootstrapBackendIfNeeded() is no longer called here: start() now
        // calls it unconditionally before this function ever runs (see
        // start() above), so calling it again here would just be redundant.
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: pythonPath.path) {
            runSync("/usr/bin/python3", ["-m", "venv", venvDir.path])
        }
        // waitress fait partie du contrôle : sans lui, une machine déjà
        // bootstrappée (flask+qrcode présents) ne relancerait jamais pip et
        // resterait pour toujours sur le serveur de développement de Flask —
        // le repli d'app.py masquerait l'absence au lieu de la combler.
        if !runSyncSucceeds(pythonPath.path, ["-c", "import flask, qrcode, waitress"]) {
            runSync(pythonPath.path, ["-m", "pip", "install", "-q", "--upgrade", "pip"])
            runSync(pythonPath.path, ["-m", "pip", "install", "-q", "-r", appDir.appendingPathComponent("requirements.txt").path])
        }
        environmentVerified = true
    }

    /// Fichiers/dossiers "gérés" par l'app : exactement ce que contient
    /// Resources/backup-manager-src, ÉNUMÉRÉ plutôt que redit.
    ///
    /// C'était auparavant une liste écrite en dur, censée refléter celle de
    /// build-app.sh. Les deux ont divergé dès qu'un module a été ajouté au
    /// backend : le bundle l'embarquait, la synchronisation ne le recopiait
    /// pas, et app.py échouait à l'import sur les machines dont
    /// ~/backup-manager n'est pas un dépôt git — backend mort, app inerte.
    /// Énumérer le dossier embarqué supprime la classe de bug : ce que
    /// build-app.sh y met est synchronisé, sans qu'on ait à s'en souvenir.
    ///
    /// Tout le reste dans ~/backup-manager (jobs, venv, logs — qui vivent en
    /// fait ailleurs) n'est jamais touché par ce mécanisme.
    private static func managedBackendItems(in bundled: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bundled.path) else {
            // Repli sur l'ancienne liste : mieux vaut synchroniser
            // l'essentiel que rien du tout si l'énumération échoue.
            return ["app.py", "backup-engine.sh", "progress-parse.py",
                    "verify-parse.py", "requirements.txt", "static", "docs",
                    "bin", "lib", "THIRD-PARTY-NOTICES"]
        }
        // Les fichiers cachés (.DS_Store et compagnie) n'ont rien à faire là.
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

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
            for name in Self.managedBackendItems(in: bundled) {
                let src = bundled.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dest = appDir.appendingPathComponent(name)
                // Atomic swap instead of remove-then-copy: a crash/kill
                // mid-copy previously could leave `dest` missing entirely
                // (removed but not yet replaced) instead of either the old
                // or the new version. Stage into a temp path in the SAME
                // directory as `dest` (required for replaceItemAt to stay
                // on the same volume) and swap it in.
                let tmpDest = dest.deletingLastPathComponent()
                    .appendingPathComponent(".\(name)-tmp-\(UUID().uuidString)")
                try fm.copyItem(at: src, to: tmpDest)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: tmpDest)
                } else {
                    try fm.moveItem(at: tmpDest, to: dest)
                }
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
            beginCrashedRecovery(generation: gen)
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
            // answered. Previously this just returned silently, relying on
            // a health monitor that was never started (beginHealthMonitor()
            // only runs after a successful probe) — the UI stayed stuck on
            // "Démarrage du serveur…" forever. Surface the same .crashed
            // state used elsewhere (attemptLaunch's failure-count gate) so
            // AppDelegate shows the recovery screen and "Relancer le
            // serveur" becomes available.
            NSLog("FlaskSupervisor: app.py did not respond after \(attempt) attempts — giving up and surfacing failure")
            consecutiveFailures = maxConsecutiveFailures
            delegate?.flaskStatusChanged(.crashed)
            beginCrashedRecovery(generation: gen)
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

    /// Rafraîchissement PONCTUEL, déclenché par un événement (branchement ou
    /// débranchement d'un disque), pas par un minuteur. Passe par le même
    /// fetchJobs partagé et ne crée aucun second minuteur : la règle « une
    /// seule requête à la fois contre le serveur Flask mono-thread » reste
    /// tenue, puisque ces événements sont rares et non périodiques.
    func refreshJobsNow() {
        let gen = generation
        fetchJobs { [weak self] jobs in
            guard let self, gen == self.generation, let jobs else { return }
            self.delegate?.flaskJobsUpdated(jobs)
        }
    }

    // MARK: - Probe
    //
    // A single shared entry point for all "is Flask up" checks (fetchJobs),
    // so the app never runs more than one HTTP request against Flask's
    // single-threaded dev server at a time. Do not add a second, independent
    // polling timer elsewhere — route any additional periodic need through
    // FlaskSupervisorDelegate.flaskJobsUpdated instead.

    /// Sonde lente pendant l'état .crashed, jusqu'à ce que le serveur réponde.
    ///
    /// Sans elle, .crashed était DÉFINITIF : après quatre sondages ratés, l'app
    /// affichait « Le serveur local n'a pas pu démarrer » pour toujours, y
    /// compris quand le serveur tournait et répondait en 15 ms.
    ///
    /// Constaté sur le MacBook le 2026-07-30 : le backend et l'application
    /// avaient exactement le même âge — l'app l'avait donc bien lancé — mais le
    /// sondage de démarrage, avec ses 4 secondes de délai, n'avait pas tenu
    /// pendant que les disques externes se réveillaient. Le verdict s'était
    /// figé, et seul un redémarrage manuel en sortait.
    ///
    /// Une preuve vaut mieux qu'une conclusion antérieure : tant que l'app est
    /// dans cet état, elle redemande, et se ravise dès que le serveur répond.
    private func beginCrashedRecovery(generation gen: Int) {
        guard gen == generation else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + crashedRecoveryInterval) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.probe { vivant in
                guard gen == self.generation else { return }
                if vivant {
                    // Le serveur répond : on efface le verdict et on repart.
                    self.consecutiveFailures = 0
                    self.delegate?.flaskStatusChanged(.running)
                    self.beginHealthMonitor(generation: gen)
                } else {
                    self.beginCrashedRecovery(generation: gen)
                }
            }
        }
    }

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
