import Foundation

// bmengine — lanceur signé du moteur de backup.
//
// Pourquoi ce binaire existe : macOS TCC attribue l'« Accès complet au disque »
// au « responsible process » d'un arbre de processus. Quand launchd lançait
// directement `/bin/bash backup-engine.sh`, c'était bash (puis rsync) qui
// devenaient responsables -> deux entrées distinctes (bash + rsync) dans la
// liste « Accès complet au disque ».
//
// En interposant ce petit binaire SIGNÉ (identité stable via certificat
// auto-signé), launchd le lance comme racine de l'arbre : bmengine devient le
// seul « responsible process », et bash + rsync héritent de SON autorisation.
// Résultat : une seule entrée à autoriser, stable à travers les recompilations.
//
// Il se contente de lancer le moteur en process ENFANT (et non execv, ce qui
// remplacerait l'image par bash et re-exposerait bash à TCC) puis propage le
// code de sortie.

let engine = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("backup-manager/backup-engine.sh").path

guard FileManager.default.isReadableFile(atPath: engine) else {
    FileHandle.standardError.write(Data("bmengine: moteur introuvable: \(engine)\n".utf8))
    exit(127)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/bin/bash")
proc.arguments = [engine] + Array(CommandLine.arguments.dropFirst())

// Transmet l'environnement tel quel (PATH fourni par le plist launchd).
proc.environment = ProcessInfo.processInfo.environment

do {
    try proc.run()
} catch {
    FileHandle.standardError.write(Data("bmengine: échec du lancement: \(error)\n".utf8))
    exit(126)
}

// Relaie SIGTERM/SIGINT à l'enfant : sans ça, arrêter bmengine (launchd,
// `kill`) laissait bash+rsync orphelins continuer de tourner. Le handler
// tourne sur une queue dédiée (pas .main) car ce lanceur est bloqué plus
// bas dans un appel synchrone (waitUntilExit), sans run loop qui tourne
// pour dépiler .main.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalQueue = DispatchQueue(label: "bmengine.signals")
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
sigterm.setEventHandler { proc.terminate() }
sigterm.resume()
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
sigint.setEventHandler { proc.terminate() }
sigint.resume()

proc.waitUntilExit()
exit(proc.terminationStatus)
