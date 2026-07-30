import Foundation

enum FlaskStatus {
    case starting
    case running
    case stoppedByUser
    case crashed
}

protocol FlaskSupervisorDelegate: AnyObject {
    func flaskStatusChanged(_ status: FlaskStatus)
    /// Émis au plus une fois par tour du moniteur de santé (~5 s), en
    /// s'appuyant sur l'UNIQUE requête /api/jobs que le superviseur fait déjà.
    ///
    /// Ne pas ajouter de second minuteur de scrutation indépendant : la raison
    /// n'est plus la fragilité du serveur de développement mono-thread de Flask
    /// (app.py est servi par waitress, 8 fils, depuis un moment — la contrainte
    /// technique a disparu), mais qu'un seul instantané partagé garde tous les
    /// consommateurs (badge du Dock, icône de la barre de menus, notifications,
    /// `hasRunningJob`) rigoureusement d'accord entre eux, et évite d'empiler
    /// des requêtes redondantes contre un backend qui shelle vers /sbin/mount.
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
/// against the backend (et, pire, deux `app.py` se disputant le port 8787).
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

    /// Vrai quand la resynchronisation depuis le bundle a RÉELLEMENT changé au
    /// moins un fichier de ~/backup-manager pendant ce lancement. C'est la
    /// poignée de main de version : un backend déjà vivant a forcément chargé
    /// son code AVANT cette resynchronisation, donc si quelque chose a changé,
    /// l'adopter tel quel revient à faire tourner l'ANCIEN code indéfiniment.
    /// (Voir bootstrapBackendIfNeeded et start.)
    private var bundledBackendChanged = false

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

    /// Termine le backend, qu'on en possède le handle OU NON — les deux bouts
    /// comptent, voir le commentaire dans le corps pour le second.
    ///
    /// Appelé depuis applicationWillTerminate — sans ça, le child process
    /// (lancé via Process(), pas dans le même groupe de process que l'app) devient
    /// orphelin et continue de tourner indéfiniment après que l'app ait
    /// quitté, gardant le port 8787 occupé pour la prochaine instance
    /// (constaté en usage réel : un process zombie datant d'un lancement
    /// précédent a survécu à plusieurs cycles quitter/relancer, y compris
    /// une désinstallation complète, et répondait toujours aux requêtes API
    /// à la place de la nouvelle instance).
    func stop() {
        if let p = process {
            p.terminationHandler = nil
            process = nil
            Self.terminate(p, raison: "fermeture de l'application")
            return
        }
        // `process == nil` ne signifie PAS « aucun backend ne tourne ».
        //
        // Après un redémarrage demandé depuis l'interface web, app.py se
        // relance lui-même DÉTACHÉ (subprocess.Popen(..., start_new_session=True),
        // voir api_restart) : le superviseur perd tout handle dessus et se
        // contente de le surveiller par HTTP — le moniteur de santé l'assume
        // explicitement. L'ancien `guard let p = process else { return }`
        // rendait donc stop() totalement inerte dans ce cas précis :
        // redémarrage depuis l'UI puis Cmd-Q laissait le backend vivant, tenant
        // le port 8787. L'instance suivante l'« adoptait » (la sonde de start()
        // le trouve vivant), si bien qu'après une mise à jour Sparkle le
        // processus adopté exécutait l'ANCIEN code alors que les fichiers
        // venaient d'être resynchronisés — et rien ne le redémarrait jamais.
        stopUnownedBackend()
    }

    /// SIGTERM, attente BORNÉE, puis SIGKILL.
    ///
    /// Extrait ici parce que deux appelants en ont besoin — stop() à la
    /// fermeture, et le moniteur de santé quand le process qu'on possède est
    /// vivant mais figé. Une seule implémentation : c'est exactement le patron
    /// de bug historique de ce projet (deux copies de la même idée qui
    /// divergent) qu'on refuse de recréer.
    ///
    /// L'attente est bornée parce que p.waitUntilExit() seul peut bloquer le
    /// fil appelant (applicationWillTerminate, fil principal) indéfiniment si
    /// app.py ignore SIGTERM ou est figé.
    private static func terminate(_ p: Process, raison: String) {
        guard p.isRunning else { return }
        p.terminate()
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            p.waitUntilExit()
            sema.signal()
        }
        if sema.wait(timeout: .now() + 5) == .timedOut {
            NSLog("FlaskSupervisor: app.py toujours vivant 5 s après SIGTERM (\(raison)) — envoi de SIGKILL")
            kill(p.processIdentifier, SIGKILL)
        }
    }

    /// Arrête un backend vivant dont on n'a AUCUN handle (respawn détaché
    /// d'app.py, ou reliquat d'une session précédente).
    ///
    /// Appelé depuis applicationWillTerminate, sur le fil principal : chaque
    /// étape est bornée dans le temps (~4 s au pire au total), pour ne pas se
    /// faire tuer par le chien de garde de macOS pendant la fermeture.
    ///
    /// Deux étapes, la seconde seulement si la première n'a pas suffi :
    ///  1. POST /api/quit — c'est app.py lui-même qui s'arrête, exactement le
    ///     chemin qu'emprunte déjà le bouton « Quitter » de l'interface, et il
    ///     n'affecte PAS les sauvegardes en cours (le moteur tourne détaché via
    ///     launchd). Aucune supposition sur le PID ni sur la ligne de commande :
    ///     celle-ci ne contient d'ailleurs PAS le chemin du venv, macOS résolvant
    ///     le lien .venv/bin/python vers le Python du système — un pgrep dessus
    ///     ne trouverait rien (vérifié sur le backend en production).
    ///  2. si le port répond toujours, on tue le process qui l'écoute, retrouvé
    ///     par lsof. On n'en arrive là QUE si l'étape 1 a reçu un 200 : c'est la
    ///     preuve que ce qui tient le port implémente bien notre API, et non
    ///     qu'un programme tiers a pris 8787 — sans cette condition, tuer par
    ///     numéro de port serait un tir à l'aveugle.
    private func stopUnownedBackend() {
        var accepte = false
        var request = URLRequest(url: baseURL.appendingPathComponent("api/quit"))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            accepte = ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200
            sema.signal()
        }.resume()
        guard sema.wait(timeout: .now() + 3) == .success, accepte else { return }
        NSLog("FlaskSupervisor: backend non possédé (respawn détaché) — /api/quit accepté")

        // api_quit laisse d'abord partir sa réponse HTTP (temporisation de
        // 0,4 s côté app.py) puis appelle os._exit : on lui laisse le temps de
        // libérer le port avant de conclure quoi que ce soit.
        usleep(1_000_000)
        var pids = listeningBackendPIDs()
        guard !pids.isEmpty else { return }
        NSLog("FlaskSupervisor: le port \(port) est toujours tenu après /api/quit — SIGTERM sur \(pids)")
        for pid in pids { kill(pid, SIGTERM) }
        usleep(500_000)
        pids = listeningBackendPIDs()
        for pid in pids {
            NSLog("FlaskSupervisor: pid \(pid) tient encore le port \(port) — SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    /// PID(s) qui écoutent le port du backend. Restreint à l'utilisateur
    /// courant : sur un Mac partagé, on ne touche jamais au process d'un autre
    /// compte. lsof sort en 1 quand il ne trouve rien, ce n'est pas une panne —
    /// d'où logFailure: false.
    private func listeningBackendPIDs() -> [pid_t] {
        let (code, sortie) = runCapturing(
            "/usr/sbin/lsof",
            ["-nP", "-a", "-u", String(getuid()), "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
            logFailure: false)
        guard code == 0 else { return [] }
        return sortie.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    func manualRestart() {
        generation += 1
        healthTimer?.cancel()
        healthTimer = nil
        consecutiveFailures = 0
        // prepareThenLaunch, et non attemptLaunch directement : ensureEnvironment()
        // ne mémorise plus un succès qui n'a pas eu lieu (voir plus bas), donc ce
        // bouton RETENTE réellement la création du venv et l'installation pip.
        // C'est précisément ce que l'utilisateur attend de « Relancer le serveur »
        // après une toute première installation faite hors ligne.
        prepareThenLaunch(generation: generation)
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
                    if alive && self.bundledBackendChanged {
                        // POIGNÉE DE MAIN DE VERSION, la plus simple qui ferme
                        // vraiment le trou : le backend qui répond a chargé son
                        // code AVANT la resynchronisation qu'on vient de faire,
                        // et celle-ci a changé au moins un fichier. L'adopter
                        // reviendrait à laisser tourner l'ancien code pour
                        // toujours après une mise à jour Sparkle — le cas exact
                        // du backend orphelin décrit dans stop(). On le remplace.
                        //
                        // Pourquoi comparer les FICHIERS plutôt que demander sa
                        // version au backend : app.py n'expose aucun numéro de
                        // version, et l'ajouter demanderait de modifier l'autre
                        // dépôt PUIS d'attendre qu'il soit déployé partout — un
                        // backend ancien, justement, ne saurait pas répondre. La
                        // comparaison de contenu, elle, marche dès cette version
                        // et ne redémarre QUE quand quelque chose a réellement
                        // changé (pas à chaque lancement).
                        NSLog("FlaskSupervisor: un backend répond mais il est antérieur au backend embarqué (fichiers resynchronisés) — remplacement")
                        self.replaceRunningBackend(generation: gen)
                    } else if alive {
                        self.delegate?.flaskStatusChanged(.running)
                        self.beginHealthMonitor(generation: gen)
                    } else {
                        self.prepareThenLaunch(generation: gen)
                    }
                }
            }
        }
    }

    // MARK: - Environment bootstrap (mirrors start-headless.sh)

    /// Prépare l'environnement Python HORS du fil principal puis lance.
    /// ensureEnvironment() shelle de façon synchrone (création du venv,
    /// installation pip) : au tout premier lancement ça peut prendre de vraies
    /// secondes sur le réseau, et le faire sur le fil principal figerait toute
    /// l'app pendant ce temps.
    private func prepareThenLaunch(generation gen: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.ensureEnvironment()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.attemptLaunch(generation: gen)
            }
        }
    }

    /// Remplace un backend vivant qu'on ne possède pas par un neuf. Tout se
    /// passe hors du fil principal : stopUnownedBackend() attend jusqu'à ~4 s.
    private func replaceRunningBackend(generation gen: Int) {
        delegate?.flaskStatusChanged(.starting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.stopUnownedBackend()
            self.ensureEnvironment()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.attemptLaunch(generation: gen)
            }
        }
    }

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
        let controleImports = ["-c", "import flask, qrcode, waitress"]
        if !runSyncSucceeds(pythonPath.path, controleImports) {
            runSync(pythonPath.path, ["-m", "pip", "install", "-q", "--upgrade", "pip"])
            runSync(pythonPath.path, ["-m", "pip", "install", "-q", "-r", appDir.appendingPathComponent("requirements.txt").path])
        }
        // On ne mémorise QUE ce qui a réellement eu lieu.
        //
        // `environmentVerified = true` était posé inconditionnellement, même
        // quand venv ou pip venaient d'échouer : un succès imaginaire, gravé
        // pour toute la session. Une première installation hors ligne ne
        // retentait donc plus jamais rien — l'utilisateur voyait .crashed, et
        // le journal ne disait pas un mot (voir runCapturing plus bas, qui
        // envoyait tout vers nullDevice). Ici on REVÉRIFIE, et un échec laisse
        // le drapeau à false pour que « Relancer le serveur » puisse retenter.
        let (code, sortie) = runCapturing(pythonPath.path, controleImports, logFailure: false)
        environmentVerified = code == 0
        if !environmentVerified {
            let extrait = sortie.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
            NSLog("FlaskSupervisor: environnement Python toujours incomplet après bootstrap (flask/qrcode/waitress non importables) : \(extrait) — sera retenté au prochain essai de lancement")
        }
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
    ///
    /// La liste de repli qui vivait ici a été SUPPRIMÉE, pas complétée. Elle
    /// avait re-divergé de la liste blanche de build-app.sh (backup-config.py
    /// et les cinq modules relay-* y manquaient), et surtout elle ne pouvait
    /// rien sauver : si `contentsOfDirectory` échoue sur ce dossier, c'est
    /// qu'il est illisible, et le `copyItem` qui suit échouerait sur CHACUN de
    /// ces noms de toute façon. Recopier les six noms manquants n'aurait fait
    /// que réarmer la divergence pour le prochain module ajouté. Il n'y a
    /// désormais qu'une seule source de vérité — ce que build-app.sh a
    /// réellement mis dans le bundle — et un échec se voit dans le journal au
    /// lieu de se déguiser en synchronisation partielle.
    private static func managedBackendItems(in bundled: URL) -> [String] {
        let fm = FileManager.default
        do {
            let names = try fm.contentsOfDirectory(atPath: bundled.path)
            // Les fichiers cachés (.DS_Store et compagnie) n'ont rien à faire là.
            return names.filter { !$0.hasPrefix(".") }.sorted()
        } catch {
            NSLog("FlaskSupervisor: impossible d'énumérer le backend embarqué (\(bundled.path)) : \(error) — aucune synchronisation de ~/backup-manager possible")
            return []
        }
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
        var modifies: [String] = []
        do {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            for name in Self.managedBackendItems(in: bundled) {
                let src = bundled.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dest = appDir.appendingPathComponent(name)
                // Comparaison de contenu AVANT la copie. Elle sert deux fois :
                // elle évite de réécrire chaque lancement des fichiers
                // identiques, et surtout c'est ELLE qui répond à la question
                // « le backend déjà vivant exécute-t-il encore l'ancien code ? »
                // (voir bundledBackendChanged / start()). contentsEqual compare
                // récursivement le contenu des dossiers, pas seulement leur nom.
                if fm.contentsEqual(atPath: src.path, andPath: dest.path) { continue }
                modifies.append(name)
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
            bundledBackendChanged = !modifies.isEmpty
            if modifies.isEmpty {
                NSLog("FlaskSupervisor: ~/backup-manager déjà identique au backend embarqué — rien à synchroniser")
            } else {
                NSLog("FlaskSupervisor: \(firstInstall ? "bootstrapped" : "synced") ~/backup-manager from bundled resources — \(modifies.count) élément(s) mis à jour : \(modifies.joined(separator: ", "))")
            }
        } catch {
            // Une synchronisation interrompue en cours de route a pu changer
            // une PARTIE des fichiers : on le signale quand même, sinon un
            // backend vivant serait adopté alors qu'il mélange deux versions.
            bundledBackendChanged = bundledBackendChanged || !modifies.isEmpty
            NSLog("FlaskSupervisor: \(firstInstall ? "bootstrap" : "sync") of ~/backup-manager failed: \(error)")
        }
    }

    /// Exécute une commande et REND sa sortie, en la journalisant quand elle
    /// échoue.
    ///
    /// Avant, stdout et stderr partaient tous les deux vers nullDevice et une
    /// exception de lancement se réduisait à un -1 muet. Autrement dit, la
    /// cause d'un échec de venv ou de pip n'était écrite NULLE PART : une
    /// première installation hors ligne échouait en silence, l'utilisateur
    /// voyait « Le serveur local n'a pas pu démarrer » sans le moindre indice
    /// dans le journal, et rien ne permettait de distinguer « pas de réseau »
    /// de « python3 absent » ou « disque plein ».
    private func runCapturing(_ launchPath: String, _ arguments: [String],
                              logFailure: Bool = true) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let tube = Pipe()
        p.standardOutput = tube
        p.standardError = tube
        do {
            try p.run()
        } catch {
            if logFailure {
                NSLog("FlaskSupervisor: impossible de lancer \(launchPath) : \(error)")
            }
            return (-1, "\(error)")
        }
        // Lire JUSQU'À EOF AVANT waitUntilExit. Dans l'autre ordre, une sortie
        // qui dépasse le tampon du tube (64 Ko — pip y arrive vite en cas
        // d'erreur) bloque l'enfant qui écrit pendant qu'on attend qu'il se
        // termine : interblocage franc, et l'app figée avec.
        let sortie = String(data: tube.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        p.waitUntilExit()
        let status = p.terminationStatus
        if status != 0 && logFailure {
            let extrait = sortie.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
            NSLog("FlaskSupervisor: échec de \(launchPath) \(arguments.joined(separator: " ")) (code \(status)) : \(extrait)")
        }
        return (status, sortie)
    }

    @discardableResult
    private func runSync(_ launchPath: String, _ arguments: [String]) -> Int32 {
        runCapturing(launchPath, arguments).status
    }

    /// Sans journalisation : ici un code non nul est une RÉPONSE attendue
    /// (« ce module n'est pas installé »), pas une panne à signaler.
    private func runSyncSucceeds(_ launchPath: String, _ arguments: [String]) -> Bool {
        runCapturing(launchPath, arguments, logFailure: false).status == 0
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
        // over the port before assuming this was a crash. Le backend peut
        // légitimement rester muet plusieurs secondes — son gestionnaire
        // /api/jobs shelle vers /sbin/mount, qui bloque si un volume réseau
        // est brièvement injoignable. (Ce n'est plus une histoire de serveur
        // de développement mono-thread : waitress sert avec 8 fils. Le délai
        // vient du travail lui-même, pas du nombre de fils.) Une seule sonde
        // rapide lirait ça comme « mort » et déclencherait un lancement
        // dupliqué inutile, d'où ces réessais généreux avant de conclure.
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
                        if let fige = self.process {
                            // Le process qu'on POSSÈDE est toujours vivant mais
                            // ne répond plus : il est figé.
                            //
                            // Il n'y avait aucune branche pour ce cas. Le
                            // minuteur venait d'être annulé juste au-dessus et
                            // la relance était conditionnée à `process == nil` :
                            // donc plus aucun minuteur, jamais d'état .crashed,
                            // et « Relancer le serveur » restait masqué puisqu'il
                            // n'apparaît qu'en .crashed. L'app affichait « en
                            // marche » avec des données gelées, pour toujours.
                            //
                            // On le remplace. terminationHandler est débranché
                            // AVANT : c'est nous qui décidons de la suite, pas
                            // handleTermination, sinon deux chaînes de décision
                            // relanceraient chacune la leur.
                            NSLog("FlaskSupervisor: app.py est vivant mais ne répond plus depuis \(self.healthMissCount) sondages — on le remplace")
                            self.process = nil
                            fige.terminationHandler = nil
                            self.consecutiveFailures += 1
                            DispatchQueue.global(qos: .utility).async {
                                Self.terminate(fige, raison: "backend figé")
                                DispatchQueue.main.async {
                                    guard gen == self.generation else { return }
                                    self.attemptLaunch(generation: gen)
                                }
                            }
                        } else {
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
    /// seule source de scrutation » reste tenue, puisque ces événements sont
    /// rares et non périodiques.
    func refreshJobsNow() {
        let gen = generation
        fetchJobs { [weak self] jobs in
            guard let self, gen == self.generation, let jobs else { return }
            self.delegate?.flaskJobsUpdated(jobs)
        }
    }

    // MARK: - Probe
    //
    // Un seul point d'entrée partagé pour toutes les questions « le backend
    // répond-il ? » (fetchJobs). La justification n'est plus la fragilité du
    // serveur de développement mono-thread de Flask — app.py est servi par
    // waitress avec 8 fils, il encaisse sans peine des requêtes parallèles —
    // mais qu'un seul instantané partagé garde tous les consommateurs d'accord
    // et évite d'empiler des requêtes redondantes. Ne pas ajouter de second
    // minuteur de scrutation ailleurs : faire passer tout besoin périodique
    // supplémentaire par FlaskSupervisorDelegate.flaskJobsUpdated.

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
