import AppKit

/// État agrégé dérivé du même instantané /api/jobs déjà utilisé par
/// JobPoller — aucune requête HTTP supplémentaire.
enum MenuBarActivity {
    case idle
    case running
    case attention   // échec ou blocage (montage/permission) sur au moins un job
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

    static func tooltip(for activity: MenuBarActivity) -> String {
        switch activity {
        case .idle: return "Backup Manager"
        case .running: return "Backup Manager — sauvegarde en cours…"
        case .attention: return "Backup Manager — ⚠️ intervention requise (échec ou blocage)"
        }
    }

    /// Teinte l'icône gabarit (StatusIcon, noire à canal alpha) d'une couleur
    /// unie plutôt que d'y superposer un badge : reste lisible aussi bien
    /// sur une barre de menu claire que sombre.
    static func icon(for activity: MenuBarActivity, base: NSImage) -> NSImage {
        switch activity {
        case .idle:
            let icon = (base.copy() as? NSImage) ?? base
            icon.isTemplate = true
            return icon
        case .running:
            return tinted(base, color: .systemBlue)
        case .attention:
            return tinted(base, color: .systemRed)
        }
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}
