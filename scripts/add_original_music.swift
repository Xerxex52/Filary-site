import AVFoundation
import Foundation

// Musique originale de la vidéo DotChroma : synthétisée ici, note par note.
// Aucun morceau sous licence — le fichier n'existe qu'à partir de ce code.
//
// Usage : swift AppStore/video/ajouter-musique.swift <video.mp4> <musique.wav> <sortie.mp4>
//
// Deux règles tiennent toute la propreté du rendu :
//
//   1. La phase de chaque oscillateur est *accumulée*, jamais recalculée depuis le
//      temps absolu. Une phase dérivée du temps saute à chaque changement de note —
//      c'est ce saut qu'on entend comme un clic.
//   2. Toute note qui redémarre part d'une amplitude nulle et monte sur quelques
//      millisecondes. Une enveloppe qui commence à pleine amplitude claque.
//
// Aucune hauteur ne glisse. Basse et mélodie changent de note quand leur enveloppe
// vaut zéro, donc sans clic ; la nappe croise deux jeux d'oscillateurs en fondu
// plutôt que de faire varier ses fréquences. Un portamento, même de 12 ms, est un
// balayage : il ne produit ni saut ni aigu, donc aucune mesure d'onde ne le voit,
// mais il s'entend.

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage : swift ajouter-musique.swift <video.mp4> <musique.wav> <sortie.mp4>")
}

let entree = URL(fileURLWithPath: CommandLine.arguments[1])
let musiqueURL = URL(fileURLWithPath: CommandLine.arguments[2])
let sortie = URL(fileURLWithPath: CommandLine.arguments[3])
let asset = AVURLAsset(url: entree)
let duree = CMTimeGetSeconds(asset.duration)

let frequenceEchantillonnage = 44_100.0
let periode = 1.0 / frequenceEchantillonnage
let canaux: AVAudioChannelCount = 2
let nombreImages = AVAudioFrameCount(ceil(duree * frequenceEchantillonnage))
guard let format = AVAudioFormat(standardFormatWithSampleRate: frequenceEchantillonnage, channels: canaux),
      let tampon = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: nombreImages) else {
    fatalError("Impossible de créer le tampon audio")
}
tampon.frameLength = nombreImages

// MARK: - Matériau musical

let tempo = 92.0
let battement = 60.0 / tempo
let deuxPi = Double.pi * 2

// Voicings largement espacés, sans aucune seconde mineure : deux notes distantes
// d'un demi-ton et tenues ensemble battent, et c'est ce battement qu'on entend
// grincer. La version précédente en produisait sur deux accords sur quatre, par
// le doublement à l'octave d'accords de septième majeure. Ici plus de doublement,
// et l'écart minimal de chaque voicing est vérifié plus bas.
let accords = [
    [45, 52, 57, 64], // La mineur 11, ouvert
    [41, 48, 53, 60], // Fa majeur 9
    [48, 55, 60, 67], // Do majeur 9
    [43, 50, 55, 62], // Sol sus
]
let basses = [33, 29, 36, 31]
// Mélodie pentatonique de la mineur : aucune note ne peut tomber à un demi-ton
// d'une note tenue de l'accord.
let melodie = [69, 72, 76, 72, 69, 67, 64, 67, 69, 72, 74, 72, 67, 64, 62, 64]

// Garde-fous : les grincements successifs sont tous venus d'un intervalle, jamais
// d'un réglage. On vérifie donc tout ce qui peut sonner en même temps.

// 1. À l'intérieur d'un accord.
for (rang, accord) in accords.enumerated() {
    let notes = accord.sorted()
    for (a, b) in zip(notes, notes.dropFirst()) where b - a < 2 {
        fatalError("Accord \(rang) : \(a) et \(b) sont à un demi-ton, ils battront")
    }
}

// 2. Entre la mélodie et l'accord tenu sous elle. La mélodie boucle sur seize
// croches, soit deux mesures ; la grille sur quatre. Il faut donc parcourir le
// plus petit commun multiple, quatre mesures.
for mesure in 0..<4 {
    let accord = accords[mesure % accords.count]
    for croche in (mesure * 8)..<((mesure + 1) * 8) {
        let note = melodie[croche % melodie.count]
        for tenue in accord where abs(note - tenue) == 1 {
            fatalError("Mesure \(mesure) : la mélodie \(note) frotte contre \(tenue)")
        }
    }
}

func frequence(_ midi: Int) -> Double { 440.0 * pow(2.0, Double(midi - 69) / 12.0) }

/// Enveloppe attaque-déclin. L'attaque part réellement de zéro : c'est elle qui
/// empêche le claquement au redémarrage d'une note.
func enveloppe(_ position: Double, attaque: Double, declin: Double) -> Double {
    guard position >= 0 else { return 0 }
    if position < attaque { return position / attaque }
    return exp(-(position - attaque) * declin)
}

var generateur: UInt64 = 0xD0_7C_47_0A
func bruit() -> Double {
    generateur = generateur &* 6_364_136_223_846_793_005 &+ 1
    return Double((generateur >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF) * 2 - 1
}

guard let gauche = tampon.floatChannelData?[0], let droite = tampon.floatChannelData?[1] else {
    fatalError("Canaux audio indisponibles")
}

// MARK: - Oscillateurs à phase continue

// La nappe s'éteint brièvement sur chaque barre de mesure, change d'accord pendant
// ce silence, puis revient. Deux approches ont été essayées avant, toutes deux
// fautives :
//
//   — glisser les hauteurs d'un accord à l'autre : un balayage de 12 ms sur huit
//     oscillateurs, sans saut ni aigu, donc invisible pour une analyse d'onde ;
//   — croiser deux jeux d'oscillateurs en fondu : les deux accords sonnent alors
//     ensemble, et l'union de La mineur 11 et Fa majeur 9 contient un demi-ton
//     (52 et 53) — soit exactement le battement qu'on cherchait à supprimer.
//
// Un creux d'amplitude n'a aucun de ces défauts : au moment où la fréquence change,
// le gain vaut zéro. Rien à masquer, rien à croiser.
//
// Seconde voix légèrement désaccordée au lieu d'un doublement à l'octave : elle
// élargit le son sans introduire d'intervalle susceptible de battre.
var phaseNappe = [Double](repeating: 0, count: 4)
var phaseNappeLarge = [Double](repeating: 0, count: 4)
let longueurMesure = 4 * battement
let creuxNappe = 0.14
// Filtres à un pôle : l'un adoucit le bruit du rythme, l'autre arrondit le mixage.
var bruitFiltre = 0.0
var mixageFiltre = 0.0
var phaseBasse = 0.0, hauteurBasse = 0.0
var phaseMelodie = 0.0, phaseMelodieHarmonique = 0.0, hauteurMelodie = 0.0
var phaseKick = 0.0

var maximum = 0.0
for index in 0..<Int(nombreImages) {
    let temps = Double(index) / frequenceEchantillonnage
    let numeroBattement = temps / battement
    let positionBattement = numeroBattement - floor(numeroBattement)
    let tempsDansBattement = positionBattement * battement
    let numeroMesure = Int(floor(numeroBattement / 4.0))
    let accord = accords[numeroMesure % accords.count]
    let basse = basses[numeroMesure % basses.count]

    var valeur = 0.0

    // Nappe : un seul accord à la fois. Le gain retombe à zéro sur la barre de
    // mesure, exactement là où la fréquence change.
    let positionMesure = temps - Double(numeroMesure) * longueurMesure
    let gainNappe: Double
    if positionMesure < creuxNappe {
        gainNappe = 0.5 - 0.5 * cos(Double.pi * positionMesure / creuxNappe)
    } else if positionMesure > longueurMesure - creuxNappe {
        gainNappe = 0.5 - 0.5 * cos(Double.pi * (longueurMesure - positionMesure) / creuxNappe)
    } else {
        gainNappe = 1.0
    }
    let respirationBase = 0.94 + 0.06 * sin(deuxPi * 0.06 * temps)

    for rang in 0..<4 {
        let hauteur = frequence(accord[rang])
        phaseNappe[rang] += deuxPi * hauteur * periode
        // +0,18 Hz : le battement lent qui en résulte élargit, il ne grince pas.
        phaseNappeLarge[rang] += deuxPi * (hauteur + 0.18) * periode
        let respiration = respirationBase + 0.02 * sin(deuxPi * 0.013 * Double(rang) * temps)
        valeur += (sin(phaseNappe[rang]) + sin(phaseNappeLarge[rang]))
            * 0.030 * respiration * gainNappe
    }

    // Basse : une note par temps, attaque courte, déclin doux. La hauteur change
    // sur une frontière de mesure, donc au moment où l'enveloppe vaut zéro : elle
    // peut sauter sans produire le moindre clic, et sans balayage.
    hauteurBasse = frequence(basse)
    phaseBasse += deuxPi * hauteurBasse * periode
    valeur += sin(phaseBasse) * 0.14 * enveloppe(tempsDansBattement, attaque: 0.008, declin: 3.4)

    // Mélodie en croches. Le déclin reste lent : les notes se rejoignent au lieu
    // de laisser un trou entre elles, ce qui donnait un rendu haché.
    let numeroCroche = Int(floor(numeroBattement * 2.0))
    let positionCroche = (numeroBattement * 2.0 - floor(numeroBattement * 2.0)) * battement / 2.0
    // Même raison que pour la basse : la note change quand l'enveloppe est à zéro.
    hauteurMelodie = frequence(melodie[numeroCroche % melodie.count])
    phaseMelodie += deuxPi * hauteurMelodie * periode
    phaseMelodieHarmonique += deuxPi * hauteurMelodie * 2 * periode
    // Timbre volontairement doux : la quinte au lieu de l'octave harmonique, qui
    // sonnait plus dure sur les notes aiguës.
    let enveloppeMelodie = enveloppe(positionCroche, attaque: 0.012, declin: 3.6)
    valeur += (sin(phaseMelodie) + 0.12 * sin(phaseMelodieHarmonique)) * 0.062 * enveloppeMelodie

    // Rythme feutré. Le bruit passe par un filtre à un pôle : brut, il siffle.
    if Int(floor(numeroBattement)) % 2 == 0 {
        let enveloppeKick = enveloppe(tempsDansBattement, attaque: 0.004, declin: 14.0)
        phaseKick += deuxPi * (48.0 + 40.0 * enveloppeKick) * periode
        valeur += sin(phaseKick) * 0.17 * enveloppeKick
    }
    bruitFiltre += (bruit() - bruitFiltre) * 0.16
    let mesureBattement = Int(floor(numeroBattement)) % 4
    if mesureBattement == 2 {
        valeur += bruitFiltre * 0.085 * enveloppe(tempsDansBattement, attaque: 0.003, declin: 18.0)
    }
    valeur += bruitFiltre * 0.016 * enveloppe(positionCroche, attaque: 0.002, declin: 30.0)

    // Passe-bas d'ensemble : arrondit ce qui reste d'aigu sans ternir la nappe.
    mixageFiltre += (valeur - mixageFiltre) * 0.55
    valeur = mixageFiltre

    // Entrée et sortie progressives.
    valeur *= min(1.0, temps / 2.0) * min(1.0, max(0.0, duree - temps) / 2.6)

    let panoramique = 0.035 * sin(deuxPi * 0.08 * temps)
    let echantillonGauche = valeur * (1.0 - panoramique)
    let echantillonDroit = valeur * (1.0 + panoramique)
    gauche[index] = Float(echantillonGauche)
    droite[index] = Float(echantillonDroit)
    maximum = max(maximum, abs(echantillonGauche), abs(echantillonDroit))
}

let gain = maximum > 0 ? 0.78 / maximum : 1.0
for index in 0..<Int(nombreImages) {
    gauche[index] *= Float(gain)
    droite[index] *= Float(gain)
}

// Mesure de contrôle : un saut d'un échantillon à l'autre trahit un clic résiduel.
var sautMaximum = 0.0
for index in 1..<Int(nombreImages) {
    sautMaximum = max(sautMaximum, abs(Double(gauche[index] - gauche[index - 1])))
}
print(String(format: "saut maximal entre deux échantillons : %.4f", sautMaximum))

try? FileManager.default.removeItem(at: musiqueURL)
func enregistrerMusique() throws {
    // Garder le fichier dans une portée courte force la finalisation de son
    // en-tête avant qu'AVFoundation ne le relise pour le mixage vidéo.
    let fichierAudio = try AVAudioFile(forWriting: musiqueURL, settings: format.settings)
    try fichierAudio.write(from: tampon)
}
try enregistrerMusique()

// MARK: - Mixage dans la vidéo

let composition = AVMutableComposition()
guard let videoSource = asset.tracks(withMediaType: .video).first,
      let videoDestination = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    fatalError("Piste vidéo indisponible")
}
try videoDestination.insertTimeRange(
    CMTimeRange(start: .zero, duration: asset.duration), of: videoSource, at: .zero)
videoDestination.preferredTransform = videoSource.preferredTransform

var parametresAudio: [AVMutableAudioMixInputParameters] = []
if let audioSource = asset.tracks(withMediaType: .audio).first,
   let audioDestination = composition.addMutableTrack(
    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
    try audioDestination.insertTimeRange(
        CMTimeRange(start: .zero, duration: asset.duration), of: audioSource, at: .zero)
    let parametres = AVMutableAudioMixInputParameters(track: audioDestination)
    parametres.setVolume(1.0, at: .zero)
    parametresAudio.append(parametres)
}

let musiqueAsset = AVURLAsset(url: musiqueURL)
guard let pisteMusique = musiqueAsset.tracks(withMediaType: .audio).first,
      let musiqueDestination = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    fatalError("Piste musicale indisponible")
}
try musiqueDestination.insertTimeRange(
    CMTimeRange(start: .zero, duration: asset.duration), of: pisteMusique, at: .zero)
let parametresMusique = AVMutableAudioMixInputParameters(track: musiqueDestination)
parametresMusique.setVolume(0.38, at: .zero)
parametresAudio.append(parametresMusique)

let mixage = AVMutableAudioMix()
mixage.inputParameters = parametresAudio

try? FileManager.default.removeItem(at: sortie)
guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
    fatalError("Impossible de préparer l'export")
}
export.outputURL = sortie
export.outputFileType = .mp4
export.audioMix = mixage
export.shouldOptimizeForNetworkUse = true

let attente = DispatchSemaphore(value: 0)
export.exportAsynchronously { attente.signal() }
attente.wait()
guard export.status == .completed else {
    fatalError("Échec de l'export : \(export.error?.localizedDescription ?? "inconnu")")
}

print("Musique originale créée : \(musiqueURL.path)")
print("Vidéo musicale créée : \(sortie.path)")
print(String(format: "Durée : %.2f s", duree))
