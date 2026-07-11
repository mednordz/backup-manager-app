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
