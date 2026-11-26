import AppKit
import Testing
@testable import Smack

@Suite @MainActor struct SmackSoundTests {
    @Test func silentPlaybackWhenConfiguredToNone() {
        let player = SmackSound()
        let played = player.play(sound: .none)
        #expect(played == false)
    }

    @Test func playsSynthesizedWavForSmack() {
        let player = SmackSound()
        let played = player.play(sound: .smack)
        #expect(played == true)
    }

    @Test func playsNamedSystemAlertSound() {
        let player = SmackSound()
        let played = player.play(sound: .pop)
        #expect(played == true)
    }

    @Test func everyPanelSoundCasePlaysOrSilencesCorrectly() {
        let player = SmackSound()
        for sound in PanelSound.allCases {
            let played = player.play(sound: sound)
            if sound == .none {
                #expect(!played, "Expected .none to be silent")
            } else {
                #expect(played, "Expected \(sound.rawValue) to be playable by NSSound")
            }
            #expect(player.lastPlayedSound == sound)
        }
    }

    @Test func rapidPlaybackDoesNotCrash() {
        let player = SmackSound()
        for _ in 0..<10 {
            _ = player.play(sound: .smack)
            _ = player.play(sound: .tink)
            _ = player.play(sound: .none)
        }
    }
}
