import Foundation

/// Detects running -> finished transitions across successive /api/jobs
/// snapshots and fires a native notification. Purely passive: it does NOT
/// poll on its own. It is fed snapshots by FlaskSupervisor's single shared
/// health-monitor request (via FlaskSupervisorDelegate.flaskJobsUpdated) so
/// the app only ever has one HTTP request in flight against Flask's
/// single-threaded dev server at a time — a second independent poller
/// previously caused overlapping requests that stalled its listen backlog.
final class JobPoller {
    private var previous: [String: (running: Bool, status: String)] = [:]
    private var hasBaseline = false
    /// Dernière réussite déjà annoncée comme venant d'une AUTRE machine, par
    /// job. Sert à ne prévenir qu'une fois par sauvegarde distante, pas à
    /// chaque instantané reçu (toutes les 5 s).
    private var announcedElsewhere: [String: String] = [:]

    func process(jobs: [[String: Any]]) {
        var current: [String: (running: Bool, status: String)] = [:]

        for job in jobs {
            guard let id = job["id"] as? String,
                  let state = job["state"] as? [String: Any] else { continue }
            let running = (state["running"] as? Bool) ?? false
            let lastResult = state["last_result"] as? [String: Any]
            let status = (lastResult?["status"] as? String) ?? "unknown"
            current[id] = (running, status)

            if hasBaseline, let prior = previous[id], prior.running, !running {
                let name = (job["name"] as? String) ?? id
                let derived = job["derived"] as? [String: Any]
                let logPath = derived?["log"] as? String
                notifyFinished(jobName: name, status: status, logPath: logPath)
            }

            // Sauvegarde faite sur un AUTRE Mac du groupe : sans ça,
            // l'utilisateur qui déplace ses SSD ne saurait jamais si la
            // sauvegarde a bien eu lieu là-bas -- il verrait seulement que ce
            // Mac-ci n'a rien fait. Le backend a déjà déterminé où et quand
            // (job_health), on ne fait que relayer.
            //
            // La toute première observation ne déclenche RIEN : au lancement de
            // l'app, toutes les sauvegardes distantes passées paraîtraient
            // nouvelles et partiraient en rafale. On enregistre, puis on
            // n'annonce que les changements.
            if let health = state["health"] as? [String: Any],
               let onMachine = health["last_success_on"] as? String,
               let at = health["last_success"] as? String {
                if let known = announcedElsewhere[id], known != at {
                    let name = (job["name"] as? String) ?? id
                    NotificationsManager.shared.postJobFinished(
                        title: name,
                        body: "Sauvegardé sur \(onMachine).",
                        logPath: nil)
                }
                announcedElsewhere[id] = at
            }
        }

        previous = current
        hasBaseline = true
    }

    private func notifyFinished(jobName: String, status: String, logPath: String?) {
        let label: String
        switch status {
        case "ok": label = "Backup terminé avec succès"
        case "fail": label = "Échec du backup"
        case "dryrun": label = "Simulation terminée"
        default: label = "Backup terminé (\(status))"
        }
        NotificationsManager.shared.postJobFinished(title: jobName, body: label, logPath: logPath)
    }
}
