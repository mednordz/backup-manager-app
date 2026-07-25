import AppKit
import WebKit

/// See LocalNetwork.swift: a pf loopback-NAT side effect on this machine
/// makes 127.0.0.1:8787 unreliable, so the panel loads over the LAN IP.
/// Computed (not a stored `let`) so a DHCP lease change mid-session is
/// picked up on the next access, same as FlaskSupervisor.baseURL — a fixed
/// `let` here previously meant only baseURL re-resolved, leaving the panel
/// stuck on whatever IP was active at launch.
var panelURL: URL { URL(string: "http://\(LocalNetwork.currentLANAddress() ?? "127.0.0.1"):8787")! }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKUIDelegate, FlaskSupervisorDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var restartMenuItem: NSMenuItem?
    private var loginItemMenuItem: NSMenuItem?
    /// Éléments de menu réservés à l'affichage des jobs en cours (titre de
    /// section + une ligne par job + séparateur). Ils sont retirés et
    /// reconstruits à chaque instantané, toujours en tête du menu.
    private var progressMenuItems: [NSMenuItem] = []
    private var hasLoadedPanelOnce = false
    /// True while the WKWebView is showing crashedHTML instead of the real
    /// panel — lets flaskStatusChanged(.running) tell a genuine recovery
    /// apart from an ordinary background refresh (see case .running below).
    private var isShowingErrorScreen = false
    /// Latest /api/jobs snapshot (same one already used for the Dock badge
    /// and menu-bar icon) — kept around so quit() can check for a running
    /// job without issuing its own HTTP request.
    private var lastJobsSnapshot: [[String: Any]] = []

    private let supervisor = FlaskSupervisor()
    private let jobPoller = JobPoller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        showPanel()
        NotificationsManager.shared.appDelegate = self
        NotificationsManager.shared.configure()
        AppUpdater.shared.appDelegate = self
        AppUpdater.shared.checkSilently()
        supervisor.delegate = self
        supervisor.start()
        observeVolumeMounts()
    }

    /// Branchement/débranchement d'un disque : macOS nous le dit tout de
    /// suite. Sans ça, il faut attendre le prochain cycle de scrutation du
    /// backend pour que le panneau s'en aperçoive — jusqu'à plusieurs
    /// secondes après avoir branché le disque, ce qui donne l'impression que
    /// l'app n'a rien vu. Le rattrapage automatique d'un backup en retard en
    /// profite aussi : il redevient quasi immédiat au branchement.
    private func observeVolumeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshAfterVolumeChange()
            }
        }
    }

    private func refreshAfterVolumeChange() {
        // Petit délai : au moment où la notification arrive, le volume peut
        // ne pas être ENCORE visible dans /sbin/mount côté backend — le
        // rafraîchir dans la seconde donnerait l'état d'avant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.supervisor.refreshJobsNow()
            // Le panneau web a son propre poll de 5 s : on le pousse à
            // recharger sa liste tout de suite plutôt que de l'attendre.
            self.webView?.evaluateJavaScript(
                "window.loadJobs && window.loadJobs(); window.loadCoverage && window.loadCoverage();",
                completionHandler: nil)
        }
    }

    func bringPanelToFront() {
        showPanel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisor.stop()
    }

    /// Sans menu d'application (NSApp.mainMenu), AUCUN raccourci clavier standard
    /// n'existe (⌘R, ⌘W, ⌘Q, ⌘,, copier/coller…) : le menu du status item ne compte
    /// pas, il ne s'applique qu'à lui-même quand il est ouvert depuis la barre de menu.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Menu applicatif toujours visible en haut à gauche quand l'app est au
        // premier plan — contrairement à l'icône de la barre de menu, qui peut
        // être poussée hors champ si la barre système est chargée (beaucoup
        // d'icônes d'autres apps).
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        // Panneau standard macOS (nom, version, icône) -- fourni tout seul par AppKit,
        // aucune UI custom à maintenir. Convention Mac : toujours en premier dans le
        // menu applicatif, suivi d'un séparateur.
        let aboutItem = NSMenuItem(title: "À propos de Backup Manager", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        let openItem = NSMenuItem(title: "Ouvrir le panneau", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        appMenu.addItem(openItem)
        let updateItem = NSMenuItem(title: "Rechercher les mises à jour…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quitter Backup Manager", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        mainMenu.addItem(appMenuItem)

        let editMenu = NSMenu(title: "Édition")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editMenuItem)

        let viewMenu = NSMenu(title: "Présentation")
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        let reloadItem = NSMenuItem(title: "Recharger", action: #selector(reloadPanel), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        mainMenu.addItem(viewMenuItem)

        let windowMenu = NSMenu(title: "Fenêtre")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Menu Aide : contenu réellement utile (pas qu'un lien vide) --
        // guide d'utilisation embarqué (fonctionne hors ligne), accès direct
        // au réglage système le plus souvent nécessaire (Accès complet au
        // disque), et un raccourci vers les logs pour le dépannage.
        // NSApp.helpMenu active en prime le champ de recherche standard
        // macOS dans ce menu (recherche jusque dans les menus de l'app).
        let helpMenu = NSMenu(title: "Aide")
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        let guideItem = NSMenuItem(title: "Guide d'utilisation Backup Manager", action: #selector(openHelpGuide), keyEquivalent: "?")
        guideItem.target = self
        helpMenu.addItem(guideItem)
        helpMenu.addItem(NSMenuItem.separator())
        let fullDiskItem = NSMenuItem(title: "Autoriser l'accès complet au disque…", action: #selector(openFullDiskSettings), keyEquivalent: "")
        fullDiskItem.target = self
        helpMenu.addItem(fullDiskItem)
        let logsItem = NSMenuItem(title: "Voir les journaux…", action: #selector(openLogsFolder), keyEquivalent: "")
        logsItem.target = self
        helpMenu.addItem(logsItem)
        helpMenu.addItem(NSMenuItem.separator())
        let issueItem = NSMenuItem(title: "Signaler un problème…", action: #selector(openIssueTracker), keyEquivalent: "")
        issueItem.target = self
        helpMenu.addItem(issueItem)
        helpMenu.addItem(NSMenuItem.separator())
        let uninstallItem = NSMenuItem(title: "Désinstaller complètement…", action: #selector(uninstallCompletely), keyEquivalent: "")
        uninstallItem.target = self
        helpMenu.addItem(uninstallItem)
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Aide

    @objc private func openHelpGuide() {
        guard let url = Bundle.main.url(forResource: "help", withExtension: "html") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openFullDiskSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLogsFolder() {
        // Le vrai log utile est le stdout/stderr du process Flask (voir
        // FlaskSupervisor.logPath) -- ~/Library/Logs générique n'y menait pas.
        let path = NSHomeDirectory() + "/Library/Logs/BackupManager/backup-manager.out"
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openIssueTracker() {
        guard let url = URL(string: "https://github.com/mednordz/backup-manager-app/issues/new") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copie uninstall.sh vers un .command temporaire puis l'ouvre (= Terminal
    /// l'exécute), avant de quitter l'app — le script attend lui-même que le
    /// process ait bien disparu avant de toucher aux fichiers. Même script que
    /// celui embarqué à la racine du DMG (voir make-dmg.sh) : un seul chemin de
    /// code testé, deux points d'entrée.
    @objc private func uninstallCompletely() {
        let alert = NSAlert()
        alert.messageText = "Désinstaller complètement Backup Manager ?"
        alert.informativeText = "Ceci arrête tous les backups planifiés et supprime l'app, sa configuration, ses journaux, son cache et ses préférences de ce Mac. Vos configurations de job seront sauvegardées sur le Bureau avant suppression.\n\nVos fichiers déjà sauvegardés sur vos disques de destination (miroirs et corbeilles) ne sont jamais touchés.\n\nCette action est irréversible."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Annuler")
        alert.addButton(withTitle: "Continuer…")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        guard let scriptURL = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
            NSLog("uninstallCompletely: uninstall.sh introuvable dans le bundle")
            return
        }
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Désinstaller BackupManager.command")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: scriptURL, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {
            NSLog("uninstallCompletely: échec de préparation du script: \(error)")
            let failAlert = NSAlert()
            failAlert.messageText = "Impossible de préparer la désinstallation"
            failAlert.informativeText = error.localizedDescription
            failAlert.runModal()
            return
        }
        NSWorkspace.shared.open(dest)
        NSApp.terminate(nil)
    }

    @objc private func reloadPanel() {
        webView?.reload()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // Symbole officiel en couleurs réelles (encre + dégradé menthe) --
            // PAS un template monochrome : la charte montre explicitement le
            // symbole en couleur dans la barre de menus (voir Brand Board,
            // panneau "BARRE DE MENUS"), jamais recoloré ni aplati en silhouette.
            // isTemplate DOIT être positionné AVANT l'affectation à
            // button.image : NSStatusBarButton fige son mode de rendu au
            // moment de l'affectation, le repositionner après est trop tard
            // et l'image reste rendue en gabarit noir/blanc (constaté en
            // conditions réelles).
            let icon = NSImage(named: "StatusIcon")
            icon?.isTemplate = false
            button.image = icon
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Ouvrir le panneau", action: #selector(openPanel), keyEquivalent: "o"))
        let restartItem = NSMenuItem(title: "Relancer le serveur", action: #selector(restartServer), keyEquivalent: "r")
        restartItem.isHidden = true
        menu.addItem(restartItem)
        restartMenuItem = restartItem
        menu.addItem(NSMenuItem(title: "Tester la notification", action: #selector(testNotification), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Rechercher les mises à jour…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let loginItem = NSMenuItem(title: "Ouvrir au démarrage", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)
        loginItemMenuItem = loginItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Exporter les jobs…", action: #selector(exportJobs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restaurer les jobs…", action: #selector(restoreJobs), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() {
        showPanel()
    }

    @objc private func restartServer() {
        supervisor.manualRestart()
    }

    @objc private func exportJobs() {
        JobsBackup.exportJobs()
    }

    @objc private func restoreJobs() {
        JobsBackup.restoreJobs()
    }

    @objc private func toggleLoginItem() {
        let wantsEnabled = !LoginItem.isEnabled
        do {
            try LoginItem.setEnabled(wantsEnabled)
            loginItemMenuItem?.state = wantsEnabled ? .on : .off
        } catch {
            NSLog("LoginItem: failed to \(wantsEnabled ? "register" : "unregister"): \(error)")
            let alert = NSAlert()
            alert.messageText = "Impossible de modifier le démarrage automatique"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates()
    }

    @objc private func testNotification() {
        NotificationsManager.shared.postJobFinished(
            title: "Test — Backup Manager",
            body: "Ceci est une notification de test.",
            logPath: nil
        )
    }

    @objc private func quit() {
        if hasRunningJob {
            let alert = NSAlert()
            alert.messageText = "Un backup est en cours"
            alert.informativeText = "Quitter Backup Manager maintenant interrompra le backup en cours. Voulez-vous continuer ?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Quitter quand même")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    /// Dérivé du dernier instantané /api/jobs (voir flaskJobsUpdated) --
    /// utilisé pour avertir avant de quitter l'app ou d'installer une mise à
    /// jour Sparkle pendant qu'un backup tourne. Non privé : AppUpdater s'en
    /// sert via sa référence faible à ce delegate.
    var hasRunningJob: Bool {
        lastJobsSnapshot.contains { job in
            ((job["state"] as? [String: Any])?["running"] as? Bool) ?? false
        }
    }

    private func showPanel() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentController = WKUserContentController()
        contentController.add(self, name: "supervisor")
        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self   // sans ça, window.confirm()/alert() de app.js ne font rien
        webView.loadHTMLString(Self.startingHTML, baseURL: nil)
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Backup Manager"
        window.center()
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let startingHTML = """
    <html><body style="background:#1e1e1e;color:#ccc;font-family:-apple-system;\
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
    <p>Démarrage du serveur…</p></body></html>
    """

    /// Affiché quand FlaskSupervisor abandonne (.crashed) après plusieurs
    /// tentatives — avant ce fix, l'écran "Démarrage du serveur…" restait
    /// affiché indéfiniment sans aucune indication qu'il fallait agir.
    private static let crashedHTML = """
    <html><body style="background:#1e1e1e;color:#ccc;font-family:-apple-system;\
    display:flex;flex-direction:column;align-items:center;justify-content:center;\
    height:100vh;margin:0;text-align:center;padding:0 40px">
    <p style="font-size:15px;margin-bottom:10px">⚠️ Le serveur local n'a pas pu démarrer.</p>
    <p style="font-size:13px;color:#888;max-width:420px">Vérifie ta connexion internet (la première \
    installation télécharge des dépendances Python), puis choisis « Relancer le serveur » dans le \
    menu de l'icône dans la barre de menu.</p>
    </body></html>
    """

    // MARK: - WKUIDelegate (window.confirm()/alert() de app.js -> NSAlert native)

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        alert.alertStyle = .warning
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    // MARK: - WKScriptMessageHandler (bridge from app.js's quitApp()/restartApp())

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "supervisor", let body = message.body as? String else { return }
        if body == "quit" {
            supervisor.markIntentionalQuit()
        } else if body == "install-update" {
            AppUpdater.shared.installPendingUpdate()
        }
    }

    /// Pousse la disponibilité d'une mise à jour à la page web (bannière
    /// jaune) — voir static/app.js pour window.onUpdateAvailable.
    func notifyUpdateAvailable(version: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [version]),
              let arrayLiteral = String(data: data, encoding: .utf8) else { return }
        let versionLiteral = arrayLiteral.dropFirst().dropLast()  // "[\"1.2.3\"]" -> "\"1.2.3\""
        webView?.evaluateJavaScript("window.onUpdateAvailable && window.onUpdateAvailable(\(versionLiteral))")
    }

    // MARK: - FlaskSupervisorDelegate

    func flaskStatusChanged(_ status: FlaskStatus) {
        switch status {
        case .starting:
            restartMenuItem?.isHidden = true
        case .running:
            restartMenuItem?.isHidden = true
            if !hasLoadedPanelOnce || isShowingErrorScreen {
                // Recovering from crashedHTML: reload() would just re-fetch
                // the static error HTML string already loaded (no real URL
                // behind it), leaving the UI stuck. A real navigation to
                // panelURL is required to actually reach the panel again.
                hasLoadedPanelOnce = true
                isShowingErrorScreen = false
                webView?.load(URLRequest(url: panelURL))
            } else {
                webView?.reload()
            }
        case .stoppedByUser:
            // Flask a été arrêté suite à un clic sur « Quitter » (app.js -> postMessage
            // "quit" -> markIntentionalQuit()) : ça ne signifiait jusqu'ici que l'arrêt
            // du serveur, pas de l'app elle-même — Dock/barre de menu restaient actifs
            // indéfiniment. On termine maintenant vraiment l'application.
            NSApp.terminate(nil)
        case .crashed:
            restartMenuItem?.isHidden = false
            isShowingErrorScreen = true
            webView?.loadHTMLString(Self.crashedHTML, baseURL: nil)
        }
    }

    func flaskJobsUpdated(_ jobs: [[String: Any]]) {
        lastJobsSnapshot = jobs
        jobPoller.process(jobs: jobs)
        updateDockBadge(jobs: jobs)
        updateStatusIcon(jobs: jobs)
    }

    /// Fait vivre l'icône de la barre de menu : symbole officiel en couleurs
    /// réelles par défaut (idle), avec un petit badge bleu pendant une
    /// sauvegarde ou rouge dès qu'un job a échoué ou est bloqué par un
    /// montage/permission — plus besoin d'ouvrir le panneau pour repérer un
    /// problème. Le badge se superpose au symbole, il ne le recolore jamais.
    private func updateStatusIcon(jobs: [[String: Any]]) {
        guard let button = statusItem?.button, let base = NSImage(named: "StatusIcon") else { return }
        base.isTemplate = false
        let activity = MenuBarStatus.activity(fromJobs: jobs)
        let running = MenuBarStatus.runningJobs(fromJobs: jobs)
        button.image = MenuBarStatus.icon(for: activity, base: base)
        button.toolTip = MenuBarStatus.tooltip(for: activity, running: running)
        updateProgressMenuItems(running: running)
    }

    /// Progression en direct EN TÊTE du menu de la barre de menus, reconstruite
    /// à chaque instantané /api/jobs déjà reçu — aucune requête HTTP de plus.
    /// Les lignes sont non cliquables (elles informent, elles n'agissent pas)
    /// et disparaissent entièrement dès qu'aucun job ne tourne, pour ne pas
    /// laisser un menu encombré au repos.
    private func updateProgressMenuItems(running: [MenuBarJob]) {
        guard let menu = statusItem?.menu else { return }
        for item in progressMenuItems where menu.items.contains(item) {
            menu.removeItem(item)
        }
        progressMenuItems = []
        guard !running.isEmpty else { return }

        var fresh: [NSMenuItem] = []
        let header = NSMenuItem(title: running.count > 1 ? "En cours (\(running.count))" : "En cours",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        fresh.append(header)
        for job in running {
            let line = NSMenuItem(title: MenuBarStatus.progressLine(for: job), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.indentationLevel = 1
            fresh.append(line)
        }
        fresh.append(NSMenuItem.separator())

        for (offset, item) in fresh.enumerated() {
            menu.insertItem(item, at: offset)
        }
        progressMenuItems = fresh
    }

    /// Reflects the same job-poll snapshot already used for notifications:
    /// number of jobs currently running, or nothing when idle.
    private func updateDockBadge(jobs: [[String: Any]]) {
        let runningCount = jobs.reduce(0) { count, job in
            let running = (job["state"] as? [String: Any])?["running"] as? Bool ?? false
            return count + (running ? 1 : 0)
        }
        NSApp.dockTile.badgeLabel = runningCount > 0 ? "\(runningCount)" : nil
    }
}
