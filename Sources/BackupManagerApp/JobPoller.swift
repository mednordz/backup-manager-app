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
