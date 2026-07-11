import AppKit

/// Exporte/restaure les configurations de job (pas les données sauvegardées
/// elles-mêmes, qui vivent sur les disques de destination). L'export est une
/// simple copie de fichiers (~/.config/backup-manager/{jobs,settings.json}) :
/// chaque fichier job JSON contient déjà tout — planification, déclenchement
/// au branchement, vérification d'intégrité — donc aucune perte d'info.
///
/// La restauration ne se contente PAS de recopier les fichiers : un job créé
/// directement sur disque n'aurait aucune tâche launchd associée (le serveur
/// Flask est la seule source de vérité pour ça, voir enable_schedule/
/// enable_onmount/enable_verify_schedule dans app.py). On repasse donc par
/// l'API locale, dans l'ordre où l'interface web le ferait elle-même :
/// créer le job, puis ré-activer séparément planif / au-branchement / vérif.
enum JobsBackup {
    private static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/backup-manager")
    }

    // MARK: - Export

    static func exportJobs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Choisissez où enregistrer la sauvegarde des jobs"
        guard panel.runModal() == .OK, let destDir = panel.url else { return }

        let jobsDir = configDir.appendingPathComponent("jobs")
        let settingsFile = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: jobsDir.path) else {
            presentAlert(title: "Rien à exporter", message: "Aucun job configuré pour l'instant.", style: .informational)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let outDir = destDir.appendingPathComponent("BackupManager-jobs-\(formatter.string(from: Date()))")

        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: jobsDir, to: outDir.appendingPathComponent("jobs"))
            if FileManager.default.fileExists(atPath: settingsFile.path) {
                try FileManager.default.copyItem(at: settingsFile, to: outDir.appendingPathComponent("settings.json"))
            }
            NSWorkspace.shared.activateFileViewerSelecting([outDir])
        } catch {
            presentAlert(title: "Échec de l'export", message: error.localizedDescription, style: .warning)
        }
    }

    // MARK: - Restauration

    static func restoreJobs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Restaurer"
        panel.message = "Choisissez le dossier exporté précédemment (contenant jobs/)"
        guard panel.runModal() == .OK, let pickedDir = panel.url else { return }

        // Accepte qu'on pointe soit sur le dossier exporté (contenant jobs/),
        // soit directement sur le dossier jobs/.
        let jobsDir: URL
        if FileManager.default.fileExists(atPath: pickedDir.appendingPathComponent("jobs").path) {
            jobsDir = pickedDir.appendingPathComponent("jobs")
        } else {
            jobsDir = pickedDir
        }
        let settingsFile = pickedDir.appendingPathComponent("settings.json")

        guard let files = try? FileManager.default.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }), !files.isEmpty else {
            presentAlert(title: "Rien à restaurer", message: "Aucun fichier de job (.json) trouvé à cet emplacement.", style: .warning)
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Restaurer \(files.count) job(s) ?"
        confirm.informativeText = "Les jobs dont l'identifiant existe déjà ne seront pas écrasés. Les autres seront créés avec leur planification d'origine (planifié, au branchement, vérification)."
        confirm.addButton(withTitle: "Annuler")
        confirm.addButton(withTitle: "Restaurer")
        guard confirm.runModal() == .alertSecondButtonReturn else { return }

        Task {
            var restored: [String] = []
            var skipped: [String] = []
            var failed: [String] = []

            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let job = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let jid = job["id"] as? String else { continue }
                do {
                    let created = try await restoreOneJob(jid: jid, job: job)
                    if created { restored.append(jid) } else { skipped.append(jid) }
                } catch {
                    failed.append("\(jid) (\(error.localizedDescription))")
                }
            }

            if let settingsData = try? Data(contentsOf: settingsFile),
               let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any] {
                _ = try? await apiCall(path: "/api/settings", method: "PUT", body: settings)
            }

            var lines: [String] = []
            if !restored.isEmpty { lines.append("Restaurés : \(restored.joined(separator: ", "))") }
            if !skipped.isEmpty { lines.append("Déjà présents, ignorés : \(skipped.joined(separator: ", "))") }
            if !failed.isEmpty { lines.append("Échecs : \(failed.joined(separator: ", "))") }
            let title = restored.isEmpty && failed.isEmpty ? "Rien de nouveau à restaurer" : "Restauration terminée"
            let message = lines.isEmpty ? "Aucun job traité." : lines.joined(separator: "\n")
            let style: NSAlert.Style = failed.isEmpty ? .informational : .warning

            await MainActor.run {
                presentAlert(title: title, message: message, style: style)
            }
        }
    }

    /// Recrée un job puis réapplique son état d'automatisation d'origine.
    /// Retourne false si le job existait déjà (ignoré, jamais écrasé).
    private static func restoreOneJob(jid: String, job: [String: Any]) async throws -> Bool {
        do {
            _ = try await apiCall(path: "/api/jobs", method: "POST", body: job)
        } catch ApiError.httpStatus(409, _) {
            return false   // un job avec cet id existe déjà : on ne touche à rien
        }

        if (job["enabled"] as? Bool) == true {
            _ = try? await apiCall(path: "/api/jobs/\(jid)/schedule", method: "POST", body: ["enabled": true])
        }
        if (job["trigger_on_mount"] as? Bool) == true {
            _ = try? await apiCall(path: "/api/jobs/\(jid)/onmount", method: "POST", body: ["enabled": true])
        }
        if let vs = job["verify_schedule"] as? [String: Any], (vs["enabled"] as? Bool) == true {
            _ = try? await apiCall(path: "/api/jobs/\(jid)/verify-schedule", method: "POST", body: vs)
        }
        return true
    }

    // MARK: - Appel API locale

    private enum ApiError: Error, LocalizedError {
        case httpStatus(Int, String)
        var errorDescription: String? {
            if case .httpStatus(let code, let body) = self { return "HTTP \(code): \(body)" }
            return nil
        }
    }

    @discardableResult
    private static func apiCall(path: String, method: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://\(panelURL.host ?? "127.0.0.1"):\(panelURL.port ?? 8787)\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ApiError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
