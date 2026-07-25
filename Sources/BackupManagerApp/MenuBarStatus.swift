import AppKit

/// État agrégé dérivé du même instantané /api/jobs déjà utilisé par
/// JobPoller — aucune requête HTTP supplémentaire.
enum MenuBarActivity {
    case idle
    case running
    case attention   // échec ou blocage (montage/permission) sur au moins un job
}

/// Un job en cours, tel qu'affiché dans le menu de la barre de menus.
/// `percent` est nil tant que le moteur n'a pas encore publié d'avancement
/// (phase de scan initiale) : on affiche alors le nom seul plutôt qu'un
/// « 0 % » trompeur, qui paraîtrait figé.
struct MenuBarJob {
    let name: String
    let percent: Int?
    let eta: String?
}

enum MenuBarStatus {
    static func activity(fromJobs jobs: [[String: Any]]) -> MenuBarActivity {
        var running = false
        var attention = false

        for job in jobs {
            guard let state = job["state"] as? [String: Any] else { continue }
            if (state["running"] as? Bool) == true { running = true }

            let lastResult = state["last_result"] as? [String: Any]
            let status = lastResult?["status"] as? String
            if status == "fail" { attention = true }

            // Même heuristique que updatePermAlert() côté web (static/app.js) :
            // un job monté des deux côtés mais "skipped" trahit un blocage de
            // permission, pas une simple absence de disque externe.
            let sourceMounted = (state["source_mounted"] as? Bool) ?? false
            let destMounted = (state["dest_mounted"] as? Bool) ?? false
            if status == "skipped", sourceMounted, destMounted { attention = true }
        }

        if attention { return .attention }
        if running { return .running }
        return .idle
    }

    /// Jobs en cours, avec leur avancement — extraits du MÊME instantané que
    /// tout le reste. Le backend ne publie `state.progress` que pendant un
    /// run, il n'y a donc rien de plus à filtrer ici.
    static func runningJobs(fromJobs jobs: [[String: Any]]) -> [MenuBarJob] {
        jobs.compactMap { job in
            guard let state = job["state"] as? [String: Any],
                  (state["running"] as? Bool) == true else { return nil }
            let name = (job["name"] as? String) ?? (job["id"] as? String) ?? "Sauvegarde"
            let progress = state["progress"] as? [String: Any]
            var percent = progress?["percent"] as? Int
            if percent == nil, let d = progress?["percent"] as? Double { percent = Int(d) }
            // Le parseur écrit une ETA VIDE tant que rsync n'en fournit pas :
            // la traiter comme absente, pas comme un texte à afficher.
            let rawEta = progress?["eta"] as? String
            let eta = (rawEta?.isEmpty ?? true) ? nil : rawEta
            return MenuBarJob(name: name, percent: percent, eta: eta)
        }
    }

    /// Pause globale telle que le backend la publie sur chaque job
    /// (state.pause) — même instantané que le reste, aucune requête de plus.
    /// Retourne l'heure de reprise, ou nil si aucune pause n'est active.
    static func pausedUntil(fromJobs jobs: [[String: Any]]) -> String? {
        for job in jobs {
            guard let pause = (job["state"] as? [String: Any])?["pause"] as? [String: Any],
                  (pause["active"] as? Bool) == true else { continue }
            return (pause["until_human"] as? String) ?? "?"
        }
        return nil
    }

    /// Libellé d'un job en cours, pour un élément de menu non cliquable.
    static func progressLine(for job: MenuBarJob) -> String {
        var line = job.name
        if let p = job.percent { line += " — \(p) %" }
        if let eta = job.eta { line += " · \(eta) restantes" }
        return line
    }

    static func tooltip(for activity: MenuBarActivity) -> String {
        switch activity {
        case .idle: return "Backup Manager"
        case .running: return "Backup Manager — sauvegarde en cours…"
        case .attention: return "Backup Manager — ⚠️ intervention requise (échec ou blocage)"
        }
    }

    /// Infobulle enrichie quand des jobs tournent : quel job, à quel
    /// pourcentage — lisible au simple survol de l'icône, sans ouvrir le menu.
    static func tooltip(for activity: MenuBarActivity, running: [MenuBarJob]) -> String {
        guard activity == .running, !running.isEmpty else { return tooltip(for: activity) }
        return "Backup Manager — " + running.map(progressLine(for:)).joined(separator: " · ")
    }

    /// StatusIcon est désormais le symbole officiel en couleurs réelles (voir
    /// Brand Board, panneau "BARRE DE MENUS" -- montré en couleur, jamais en
    /// silhouette). On ne le teint donc plus jamais d'une couleur unie (ça
    /// reviendrait à recolorer le symbole, explicitement interdit par la
    /// charte) : un petit badge rond se superpose en bas à droite à la
    /// place, sans jamais toucher aux pixels du symbole lui-même.
    static func icon(for activity: MenuBarActivity, base: NSImage) -> NSImage {
        switch activity {
        case .idle:
            let icon = (base.copy() as? NSImage) ?? base
            icon.isTemplate = false
            return icon
        case .running:
            return badged(base, color: .systemBlue)
        case .attention:
            return badged(base, color: .systemRed)
        }
    }

    private static func badged(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let badged = NSImage(size: size)
        badged.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        let d = min(size.width, size.height) * 0.5
        let badgeRect = NSRect(x: size.width - d * 0.92, y: 0, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        badged.unlockFocus()
        badged.isTemplate = false
        return badged
    }
}
