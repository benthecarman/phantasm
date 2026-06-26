import AVFoundation
import PhantasmKit
import SwiftUI

/// Voice (read-aloud + dictation) settings. Read-aloud uses the system
/// `AVSpeechSynthesizer`; the user can pick any installed voice here, audition
/// it, and jump to iOS Settings to install higher-quality ones.
struct VoiceSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    /// Installed-voice options for the current language, loaded off the main
    /// thread on appear (the list only changes when the user installs/removes
    /// voices in iOS Settings).
    @State private var voices: [SpeechSynthesizer.VoiceOption] = []

    /// The selected voice identifier (`nil` = Automatic). Mirrors the persisted
    /// preference, but lives in `@State` so the picker re-renders on selection —
    /// `VoicePreferenceStore` is a plain UserDefaults wrapper SwiftUI can't
    /// observe, so reading it directly in the binding wouldn't update the UI.
    @State private var selectedVoiceID: String?

    /// Status of the on-device dictation model. Read-aloud needs no download.
    private var dictationState: (statusText: String, needsDownload: Bool) {
        switch env.speechModels.sttStatus {
        case .ready: return ("Ready", false)
        case .failed: return ("Failed", true)
        case .preparing: return ("Preparing…", false)
        case .notLoaded: return ("Not downloaded", true)
        }
    }

    /// Selected-voice binding. The setter updates `@State` (so the picker
    /// reflects the choice), persists it, and auditions it — picking a voice
    /// plays a sample, without auto-previewing just from opening the screen.
    private var voiceSelection: Binding<String?> {
        Binding(
            get: { selectedVoiceID },
            set: { newValue in
                selectedVoiceID = newValue
                env.voicePreferenceStore.voiceIdentifier = newValue
                env.speechSynthesizer.preview(voiceIdentifier: newValue)
            }
        )
    }

    var body: some View {
        List {
            Section {
                Toggle("Auto-speak responses", isOn: Binding(
                    get: { env.voicePreferenceStore.autoSpeak },
                    set: { env.voicePreferenceStore.autoSpeak = $0 }
                ))
            } footer: {
                Text("Reads each assistant reply aloud automatically when it finishes.")
            }

            Section {
                Picker("Voice", selection: voiceSelection) {
                    Text("Automatic").tag(String?.none)
                    ForEach(voices) { voice in
                        Text(voice.label).tag(String?.some(voice.id))
                    }
                }
                Button {
                    env.speechSynthesizer.preview(voiceIdentifier: env.voicePreferenceStore.voiceIdentifier)
                } label: {
                    Label("Test Voice", systemImage: "play.circle")
                }
            } header: {
                Text("Read-aloud voice")
            } footer: {
                Text("“Automatic” picks the highest-quality installed voice for your language.")
            }

            Section {
                Button {
                    openSettings()
                } label: {
                    Label("Open iOS Settings", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("Get higher-quality voices")
            } footer: {
                // iOS gives apps no way to deep-link into a specific Settings
                // pane (the private prefs:/App-Prefs: schemes are blocked on
                // current iOS), so we open Settings and tell the user the path.
                Text("This opens iOS Settings. From there go to **Accessibility ▸ Read & Speak ▸ Voices** to download Enhanced and Premium voices — they appear in the list above once installed.")
            }

            Section {
                HStack {
                    Text("Dictation model")
                    Spacer()
                    Text(dictationState.statusText).foregroundStyle(.secondary)
                }
                if dictationState.needsDownload {
                    Button {
                        env.speechModels.prepareAll()
                    } label: {
                        Label("Download dictation model", systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Dictation (microphone) runs on-device and downloads its model once on first use, then works offline.")
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadVoices() }
    }

    /// Enumerate installed voices off the main thread and reconcile the saved
    /// selection. Both `voiceOptionsForCurrentLanguage()` and the
    /// installed-voice check touch AVFoundation, which can be slow enough to
    /// hitch the screen if run on the main actor.
    private func loadVoices() async {
        let savedID = env.voicePreferenceStore.voiceIdentifier
        let (options, savedInstalled) = await Task.detached { () -> ([SpeechSynthesizer.VoiceOption], Bool) in
            let options = SpeechSynthesizer.voiceOptionsForCurrentLanguage()
            let installed = savedID.flatMap { AVSpeechSynthesisVoice(identifier: $0) } != nil
            return (options, installed)
        }.value
        // If the saved voice was uninstalled, fall back to Automatic so the
        // picker reflects what will actually play.
        if !savedInstalled { env.voicePreferenceStore.voiceIdentifier = nil }
        voices = options
        selectedVoiceID = env.voicePreferenceStore.voiceIdentifier
    }

    /// Open iOS Settings.
    ///
    /// We deliberately do NOT attempt a deep link. iOS has no public API to open
    /// a specific Settings pane, and the private `prefs:` / `App-Prefs:` schemes
    /// (e.g. `prefs:root=ACCESSIBILITY&path=SPEECH_TITLE/QuickSpeakAccents`) are
    /// blocked on current iOS — `open` returns `false` for every variant on
    /// iOS 26, confirmed on-device. `LSApplicationQueriesSchemes` doesn't help:
    /// that key only gates `canOpenURL`, never `open`. So the only reliable,
    /// documented entry point is `openSettingsURLString`, which lands on this
    /// app's own Settings page; the footer tells the user the path from there.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
