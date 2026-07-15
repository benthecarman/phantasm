# Phantasm iOS Codebase Review

Correctness, lifecycle, performance, security, architecture, accessibility, and UX review of the `ios/` application and `PhantasmKit`.

Review date: July 14, 2026

## Review outcome

The iOS app has a strong foundation—good protocol seams, extensive `PhantasmKit` tests, buffer-then-commit persistence, bounded attachment processing, and generally modern SwiftUI—but several correctness, privacy, and performance issues deserve attention before the next release.

The most urgent findings are:

1. A cancelled turn can finish after a new turn starts and terminate the new turn.
2. Keychain replacement can delete a valid credential and silently fail to save its replacement.
3. “Delete All” races active streams and reports success even if deletion fails.
4. Maple encryption does not authenticate the enclave and can silently downgrade.
5. HealthKit-derived chat content is eligible for iCloud backup.
6. Dictation can continue across chats/background transitions and its privacy copy overpromises.
7. Several core controls are inaccessible to VoiceOver and other assistive technologies.

## Correctness and Swift-specific bugs

### High severity

- **A stale cancelled task can terminate a newer turn.** Turn tasks share `isStreaming`, pending IDs, and `task` without a turn identity. After stopping turn A and immediately starting B, A’s cancellation path can observe B’s state and call `finish()`. The same pattern affects tool continuations. Add a generation/turn UUID and require it to match before every mutation or completion. See [ChatViewModel.swift:416](../ios/ViewModels/ChatViewModel.swift#L416), [ChatViewModel.swift:846](../ios/ViewModels/ChatViewModel.swift#L846), and [ChatViewModel.swift:1135](../ios/ViewModels/ChatViewModel.swift#L1135).

- **Onboarding can accept credentials that were never tested.** The test request snapshots neither URL nor token, but success records whatever happens to be in the editable fields after the request completes. Snapshot inputs and discard stale results, or disable editing during validation. The profile editor checks URL changes but not token changes. See [OnboardingView.swift:263](../ios/Views/Settings/OnboardingView.swift#L263) and [ProfileEditView.swift:231](../ios/Views/Settings/ProfileEditView.swift#L231).

- **Keychain updates are destructive and errors disappear.** `setToken` deletes first and then adds; a failed add loses the valid old token. `AppEnvironment` ignores the error, persists the profile, and dismisses the form. Use `SecItemUpdate`, add only for item-not-found, and propagate failure before committing profile metadata. See [KeychainStore.swift:17](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Security/KeychainStore.swift#L17) and [AppEnvironment.swift:238](../ios/App/AppEnvironment.swift#L238).

- **“Delete All” is not coordinated with live turns.** Cached view models can continue network/tool work and recreate messages after deletion. Database errors are swallowed while the UI unconditionally starts a new chat. Stop and await every live turn and commit, then delete with visible failure handling. See [SettingsView.swift:137](../ios/Views/Settings/SettingsView.swift#L137) and [RootView.swift:317](../ios/Views/RootView.swift#L317).

### Medium severity

- **One-shot SSE consumers accept truncated streams.** `complete()` returns accumulated text without requiring `.done`; native Ollama also finishes on premature EOF. Broken connections can therefore produce truncated Siri answers or titles as successful responses. See [SSEStream.swift:243](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/SSEStream.swift#L243) and [OllamaNativeChatClient.swift:77](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/OllamaNativeChatClient.swift#L77).

- **A Calendar side effect can succeed while its durable result is lost.** After event creation, `updateMessage` uses `try?`, and the model continues with the placeholder “outcome pending.” Require the update before continuation and persist an idempotent side-effect state. See [ChatViewModel.swift:948](../ios/ViewModels/ChatViewModel.swift#L948).

- **Stale dictation startup tasks can overwrite a newer readiness state.** Generation checks happen after some `.ready`/`.failed` writes. Check the generation before every state mutation. See [DictationController.swift:55](../ios/App/Speech/DictationController.swift#L55).

- **Dictation engine lifecycle state can race recognition/audio callbacks.** Teardown mutates request, converter, and engine state while callbacks can still read it. Confine lifecycle state to an actor or serial executor. See [LegacySpeechDictationEngine.swift:45](../ios/App/Speech/Dictation/LegacySpeechDictationEngine.swift#L45) and [SpeechAnalyzerDictationEngine.swift:49](../ios/App/Speech/Dictation/SpeechAnalyzerDictationEngine.swift#L49).

- **EventKit crosses executors unsafely.** A main-actor-owned `EKEventStore` is captured by `Task.detached` while saves use the same instance elsewhere. Put EventKit access on one actor/serial executor. See [CalendarProvider.swift:36](../ios/App/CalendarProvider.swift#L36).

- **The Now Playing coordinator has unisolated global mutation.** Playback state and callbacks are accessed from UI and remote-command callbacks without actor isolation. Make it `@MainActor` and marshal remote callbacks explicitly. See [GeneratedAudioNowPlayingCoordinator.swift:8](../ios/Views/Chat/GeneratedAudioNowPlayingCoordinator.swift#L8).

- **Maple URLProtocol task cancellation is unsynchronized.** `startLoading` and `stopLoading` can race around `loadingTask`, despite the class being declared `@unchecked Sendable`. Protect it with a state machine or lock. See [MapleEncryptedTransport.swift:70](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/MapleEncryptedTransport.swift#L70).

- **Malformed Maple CBOR can drive excessive allocation or recursion.** Attacker-controlled collection counts reach `reserveCapacity` without input, count, or nesting limits. Add response-size, recursion-depth, and collection-count bounds. See [MapleEncryptedTransport.swift:422](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/MapleEncryptedTransport.swift#L422).

- **HealthKit query errors are converted to “no data.”** Operational failures become indistinguishable from genuine absence or privacy-preserving denial. Preserve the denial behavior, but surface other query failures to the tool result. See [HealthKitProvider.swift:268](../ios/App/HealthKitProvider.swift#L268).

- **Shared ISO8601 formatters are Swift 6 concurrency debt.** Replace static mutable `ISO8601DateFormatter` instances with `Date.ISO8601FormatStyle` or synchronize them. See [ChartSpec.swift:170](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Charts/ChartSpec.swift#L170).

### Lower-priority correctness work

- Tool/model settings launch independent `try?` persistence tasks that can complete out of order. Serialize or coalesce latest-wins writes. See [ChatViewModel.swift:281](../ios/ViewModels/ChatViewModel.swift#L281).

- Individual history deletion navigates away even if deletion fails, and scanner startup errors are swallowed. See [HistoryDrawer.swift:213](../ios/Views/Chat/HistoryDrawer.swift#L213) and [PairingScanSheet.swift:161](../ios/Views/Pairing/PairingScanSheet.swift#L161).

- Release builds emit unused-result warnings for conversation deletions. Explicitly discard or use the returned deletion count. See [AppDatabase.swift:316](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/AppDatabase.swift#L316).

No unsafe production force casts from network/user data were found. No definite closure retain cycle, strong delegate leak, unremoved observer, or leaked timer was found.

## Lifecycle and state

- **Global dictation is not owned by a conversation.** `DictationController` is process-global while each composer observes it. Changing chats during recording/finalization can place chat A’s transcript in chat B, and backgrounding does not stop capture. `cancel()` also cannot invalidate an already-finalizing session because it only operates while recording. Scope dictation to the composer/conversation, cancel on scene inactivity and ownership changes, and handle AVAudioSession interruptions. See [AppEnvironment.swift:29](../ios/App/AppEnvironment.swift#L29), [ChatView.swift:167](../ios/Views/Chat/ChatView.swift#L167), and [DictationController.swift:86](../ios/App/Speech/DictationController.swift#L86).

- **Unsent drafts and attachments do not survive navigation or termination.** They are view-local state, and `.id(selection.id)` destroys the subtree on chat changes. Add a bounded per-conversation draft store, optionally persisted, and clear it only after send acceptance. See [ChatView.swift:19](../ios/Views/Chat/ChatView.swift#L19) and [RootView.swift:164](../ios/Views/RootView.swift#L164).

- **Generated-media temporary directories can leak.** Sharing uses an unstructured task, and failure after creating the directory skips cleanup. Use `defer` for failure cleanup, store/cancel the preparation task on disappearance, and sweep stale directories at launch. See [MarkdownMessageView.swift:362](../ios/Views/Chat/MarkdownMessageView.swift#L362) and [MarkdownMessageView.swift:425](../ios/Views/Chat/MarkdownMessageView.swift#L425).

- **Notification routing has an ordering race.** Each pending ID launches an untracked task and unconditionally clears the shared ID. Two taps completing out of order can clear the newer route. Add a generation/current-ID check or cancel the prior routing task. See [RootView.swift:284](../ios/Views/RootView.swift#L284).

- **Background expiration behavior lacks a real test seam.** The fake background manager cannot trigger expiration, leaving recovery and pending-row behavior unverified. Add tests for expiration during initial persistence, streaming, tool continuation, and assistant commit. See [ChatViewModelTests.swift:908](../ios/Tests/ChatViewModelTests.swift#L908).

Existing scanner teardown, AVPlayer observer removal, notification delegate retention, pending-assistant recovery, and SwiftUI scene subscriptions appear sound.

## Performance

These are static findings; Instruments profiling was not performed.

### Highest impact

- **Streaming reparses the entire growing Markdown answer for every delta** and issues repeated tail scrolls. Coalesce observable snapshots and scrolling at roughly frame cadence; consider plain/completed-block rendering during streaming and one full parse at completion. See [ChatViewModel.swift:684](../ios/ViewModels/ChatViewModel.swift#L684), [MarkdownMessageView.swift:32](../ios/Views/Chat/MarkdownMessageView.swift#L32), and [ChatView.swift:528](../ios/Views/Chat/ChatView.swift#L528).

- **Image downloads iterate one byte at a time** for responses allowed up to 20 MB. Use `download(for:)` or chunked delegate callbacks with bounded size and concurrent-fetch limits. See [ImageClient.swift:19](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/ImageClient.swift#L19).

- **`attachment(messageId)` has no child-key index.** Conversation loads can scan the full attachment table. Add a migration for `attachment(messageId)`, potentially including ordering columns. See [AppDatabase.swift:101](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/AppDatabase.swift#L101).

- **Every transcript load eagerly materializes all attachment BLOBs.** The same full-detail path is used for normal rendering, notification routing, image cleanup, bulk deletion, and cache healing. Split metadata from BLOB access, load thumbnails/full bytes on demand, and paginate long transcripts. See [AppDatabase.swift:566](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/AppDatabase.swift#L566).

- **Full image decoding and JPEG preparation occur synchronously in main/UI paths.** Move decoding/downsampling to a worker, cache thumbnails by attachment ID with decoded-byte costs, and load full resolution only in the viewer. See [AttachmentViews.swift:115](../ios/Views/Chat/AttachmentViews.swift#L115), [ImageViewer.swift:102](../ios/Views/Chat/ImageViewer.swift#L102), and [ComposerOptionsSheet.swift:164](../ios/Views/Chat/ComposerOptionsSheet.swift#L164).

- **Remote image caching is unbudgeted and can decode twice.** The permitted pixel/frame budgets can retain hundreds of MB. Validate metadata without decoding, downsample once, set `NSCache.totalCostLimit`, and tighten animated-image limits. See [MarkdownMessageView.swift:703](../ios/Views/Chat/MarkdownMessageView.swift#L703).

- **Bubble rendering reconstructs large base64 data solely to test whether actions should appear.** Use raw stored content for menu visibility and reconstruct data URIs only when the user explicitly copies. See [MessageBubble.swift:31](../ios/Views/Chat/MessageBubble.swift#L31) and [InlineImageRef.swift:101](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Markdown/InlineImageRef.swift#L101).

- **Every send builds the complete wire history on `@MainActor`, including base64 images.** Build immutable wire snapshots off-main and consider deliberate context compaction for old binary content. See [ChatViewModel.swift:603](../ios/ViewModels/ChatViewModel.swift#L603) and [Models.swift:329](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/Models.swift#L329).

- **Automatic title generation re-encodes and re-uploads images.** Generate titles from a bounded text-only synopsis. See [ChatViewModel.swift:1400](../ios/ViewModels/ChatViewModel.swift#L1400).

### Scalability and polish

- Three nested `AsyncThrowingStream`s have unbounded buffering. Collapse layers or merge contiguous deltas before crossing to the UI. See [SSEStream.swift:74](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/SSEStream.swift#L74).

- Recent-history and FTS searches are unbounded and search runs on every keystroke. Add limits/pagination, debounce, and an index supporting `deletedAt` plus descending `updatedAt`. See [HistoryDrawer.swift:73](../ios/Views/Chat/HistoryDrawer.swift#L73) and [AppDatabase.swift:594](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/AppDatabase.swift#L594).

- Chart payload sizes are mostly unbounded and JSON/date parsing is repeated. Enforce point/series/string caps and memoize a decoded presentation model. See [RenderChartTool.swift:75](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Tools/RenderChartTool.swift#L75).

- Launch synchronously opens/migrates SQLite and reconciles preferences/Keychain. Measure with signposts; move to an asynchronous bootstrap only if cold-launch data shows a problem. See [AppEnvironment.swift:89](../ios/App/AppEnvironment.swift#L89).

- `MasksLogo.png` is much larger than its rendered sizes and only has a universal 1× representation. Supply appropriately sized variants or a vector asset. `Logo.png` is used by Now Playing and should not be removed. See [ChatView.swift:297](../ios/Views/Chat/ChatView.swift#L297) and [GeneratedAudioNowPlayingCoordinator.swift:15](../ios/Views/Chat/GeneratedAudioNowPlayingCoordinator.swift#L15).

## Security and privacy

### High severity

- **Maple encrypts traffic without authenticating the enclave.** The certificate chain, signature, freshness, and PCR measurements are deliberately not verified, so a substituted X25519 key can decrypt traffic. Implement full attestation validation and PCR policy; until then, label it “encrypted, enclave identity unverified.” See [MapleEncryptedTransport.swift:11](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/MapleEncryptedTransport.swift#L11).

- **Explicit Maple selection can silently downgrade.** Resolution falls through to ordinary transport and persists the result when Maple preparation fails. Explicit Maple profiles should fail closed; downgrade should require strongly worded confirmation. See [CapabilitiesClient.swift:224](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Networking/CapabilitiesClient.swift#L224).

- **Plain HTTP is supported for full chat history and bearer credentials.** Require HTTPS by default. If local HTTP remains necessary, require a conspicuous per-profile opt-in, validate scheme/host/query/fragment, and preferably prohibit tokens over HTTP. See [PairingURI.swift:57](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Config/PairingURI.swift#L57) and [project.yml:71](../ios/project.yml#L71).

- **Persisted HealthKit results are eligible for iCloud backup.** Tool results live in SQLite under Application Support. Exclude the entire database directory and sidecars from backup, or avoid persisting health payloads. Apple’s review rules prohibit storing personal health information in iCloud. See [AppDatabase.swift:20](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/AppDatabase.swift#L20), [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), and [Apple backup guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup).

- **Microphone copy makes an unconditional on-device promise that the implementation does not guarantee.** Legacy speech recognition permits Apple-hosted recognition when on-device recognition is unavailable, while the usage string says audio never leaves the phone. Either fail closed without on-device support or correct every disclosure. See [LegacySpeechDictationEngine.swift:35](../ios/App/Speech/Dictation/LegacySpeechDictationEngine.swift#L35) and [project.yml:67](../ios/project.yml#L67).

- **No accessible in-app privacy-policy link was found.** Add a hosted policy covering self-hosted/Maple providers, chats, device tools, retention, backups, deletion, and contact information. Apple requires the policy in metadata and within the app. See [PrivacyDataView.swift:3](../ios/Views/Settings/PrivacyDataView.swift#L3) and [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

### Medium severity and hardening

- Token-bearing `phantasm://` pairing links are hijackable and durable. Prefer a short-lived one-time pairing code over an authenticated channel; an HTTPS universal link is better than a custom scheme but should still not carry a permanent bearer token. See [PairingURI.swift:114](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Config/PairingURI.swift#L114).

- A scanned QR triggers model/network probing before confirmation. Wait for an explicit Test/Continue action and add extra confirmation for loopback, link-local, and private targets. See [ProfileEditView.swift:189](../ios/Views/Settings/ProfileEditView.swift#L189).

- Keychain accessibility is `AfterFirstUnlock`, and replacement is non-atomic. Consider `AfterFirstUnlockThisDeviceOnly` unless backup migration is intentional. See [KeychainStore.swift:25](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Security/KeychainStore.swift#L25).

- “Approximate location” does not match six-decimal latitude/longitude output. Round coordinates if approximation is intended, or disclose precise location. See [LocationProvider.swift:27](../ios/App/LocationProvider.swift#L27) and [LocationTool.swift:113](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Tools/LocationTool.swift#L113).

- Sensitive-tool disclosure and `NSPrivacyCollectedDataTypes` need reconciliation with actual provider retention/access. This is conditional on whether Phantasm, Maple, or another provider can retain or access request content. Add just-in-time recipient disclosure and align App Store Connect/privacy declarations. See [PrivacyInfo.xcprivacy](../ios/App/PrivacyInfo.xcprivacy) and [Apple’s app privacy guidance](https://developer.apple.com/app-store/app-privacy-details/).

- SQLite has no explicit file-protection class or deletion hardening. Add Data Protection, `secure_delete`, checkpoint/vacuum behavior, or recreate the database for a full wipe. See [AppDatabase.swift:20](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/AppDatabase.swift#L20).

- Re-evaluate `ITSAppUsesNonExemptEncryption=false` now that application-layer X25519/ChaChaPoly is implemented; using CryptoKit alone does not determine export classification. See [project.yml:52](../ios/project.yml#L52) and [Apple’s export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).

- Hide revealed QR credentials in app-switcher snapshots, sweep stale shared-media files, and consider local-only expiring pasteboard entries for sensitive copied content.

No hardcoded production keys, token storage in UserDefaults, TLS trust bypass, blanket ATS disable, chat/token logging, or notification-content leak was found. Permission usage strings and privacy manifests are present; the main issues are accuracy and disclosure alignment.

## Architecture and maintainability

- **Break up the 1,526-line `ChatViewModel`.** It is an implicit state machine covering persistence, streaming, recovery, tools, background tasks, images, speech, editing, and titles. Extract a `TurnCoordinator` actor with an explicit state enum, plus tool, image-cache, and title services. See [ChatViewModel.swift:14](../ios/ViewModels/ChatViewModel.swift#L14).

- **Split `AppEnvironment` into focused stores/services.** It currently serves as database bootstrap, service locator, profile/capability store, Keychain gateway, tool-provider container, speech controller, networking hub, and search manager. See [AppEnvironment.swift:10](../ios/App/AppEnvironment.swift#L10).

- **Replace the global mutable `AppToolRegistry`.** Locked static mutation avoids basic memory corruption but creates hidden dependencies and test-order pollution. Construct an immutable registry and inject it. See [AppTool.swift:158](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Tools/AppTool.swift#L158).

- **Plan the Swift 6 migration.** Both targets remain in Swift 5 mode, and complete concurrency checking emits actionable warnings around dictation, EventKit, Now Playing, Maple URLProtocol, gesture callbacks, global registry state, and shared formatters/caches. Add strict-concurrency warnings to CI, resolve them category by category, then enable Swift 6. See [project.yml:9](../ios/project.yml#L9) and [Package.swift:26](../ios/Packages/PhantasmKit/Package.swift#L26).

- **Split large view files by feature.** `ChatView` is 1,071 lines, `MarkdownMessageView` 805, and `ComposerOptionsSheet` 538. Media networking/caching, temporary sharing, player coordination, attachment loading, and UIKit bridges should not live beside view layout. See [ChatView.swift:6](../ios/Views/Chat/ChatView.swift#L6), [MarkdownMessageView.swift:12](../ios/Views/Chat/MarkdownMessageView.swift#L12), and [ComposerOptionsSheet.swift:11](../ios/Views/Chat/ComposerOptionsSheet.swift#L11).

- **Make tool configuration data-driven.** Adding one tool requires edits across persistence, the view model, environment protocols, new-chat defaults, request filtering, composer parameters, and settings rows. Introduce stable `ToolDescriptor`s and grouped composer configuration. See [Models.swift:23](../ios/Packages/PhantasmKit/Sources/PhantasmKit/Persistence/Models.swift#L23).

- **Consolidate duplicated backend setup and selection.** Onboarding and profile editing independently implement normalization, token handling, testing, transport resolution, model selection, and saving. Share a `BackendProfileDraft` and common validation service. See [OnboardingView.swift:60](../ios/Views/Settings/OnboardingView.swift#L60) and [ProfileEditView.swift:73](../ios/Views/Settings/ProfileEditView.swift#L73).

- **Clarify the storage abstraction.** `ChatStore` suggests storage independence, but domain records directly conform to GRDB and views use GRDBQuery. Either document GRDB as the deliberate architecture or separate domain types/read repositories fully.

- **Remove verified production-unused compatibility surface** if no external source-compatibility promise exists: `ConversationRequest`, `fetchOllamaVisionModels`, the untrusted `ImageClient.fetch` overload, `ServerImageRef.inlineCached`, and the redundant `AppTools` facade.

The pure `PhantasmKit` boundary and existing `ChatClienting`, `ChatStore`, and device-provider protocols are good foundations. The biggest test gaps are stale-turn generations, `AppEnvironment`, onboarding/profile forms, composer gestures, and media behavior.

## Accessibility and UX polish

### High severity

- **Hold-to-dictate is not assistive-technology operable.** It is an image plus transparent UIKit long-press recognizer, not an accessible button/action. Keep the touch gesture, but add a default accessible start/stop action, button trait, named finish/cancel actions, and state value. See [ChatView.swift:849](../ios/Views/Chat/ChatView.swift#L849).

- **History rows have no control semantics or accessible deletion path.** Selection is `.onTapGesture`; deletion is a custom pan. Provide an accessible button representation, selected trait, and destructive “Delete conversation” action. See [HistoryDrawer.swift:115](../ios/Views/Chat/HistoryDrawer.swift#L115).

- **Interactive model prompts are not announced or focused.** Choice selection and ranking are conveyed visually without selected/rank values. Move accessibility focus when prompts and steps appear, announce validation, and expose selected/priority state. See [ChoicePromptView.swift:104](../ios/Views/Chat/ChoicePromptView.swift#L104).

- **Chat authorship is visual only.** Add “You”/“Phantasm” semantics to each bubble while preserving links and media controls as children. See [MessageBubble.swift:31](../ios/Views/Chat/MessageBubble.swift#L31).

- **There are no owned localization resources.** Add an `.xcstrings` catalog and localized Info.plist resources; migrate runtime strings/errors to `LocalizedStringResource`, use plural-aware formatting, and avoid persisting an English “New Chat” title. See [project.yml:32](../ios/project.yml#L32).

### Medium severity and polish

- Frequent controls are below 44×44 points, including composer buttons, message actions, audio playback, viewer controls, attachment removal, and code copy. Enlarge hit regions without enlarging the visible glyphs. See [ChatView.swift:774](../ios/Views/Chat/ChatView.swift#L774) and [MessageBubble.swift:157](../ios/Views/Chat/MessageBubble.swift#L157).

- User images, gallery pages, and pending attachments need descriptive labels, button semantics, page position, and accessible zoom/reset actions. Preserve meaningful Markdown alt text through image extraction. See [AttachmentViews.swift:115](../ios/Views/Chat/AttachmentViews.swift#L115) and [ImageViewer.swift:153](../ios/Views/Chat/ImageViewer.swift#L153).

- Model/backend/research selections rely on visual checkmarks. Add current values and `.isSelected` traits. See [ComposerOptionsSheet.swift:280](../ios/Views/Chat/ComposerOptionsSheet.swift#L280).

- Attachment/import/decode/save failures are frequently silent. In particular, “Save to Photos” produces success haptics before completion. Surface real failures, support retry, and announce actionable inline errors. See [ComposerOptionsSheet.swift:422](../ios/Views/Chat/ComposerOptionsSheet.swift#L422) and [ImageViewer.swift:180](../ios/Views/Chat/ImageViewer.swift#L180).

- Reduce Motion is only partially honored. Apply it to drawer springs, prompt/composer transitions, dictation pulses, context animations, swipe animations, and animated GIF/WebP playback. See [RootView.swift:59](../ios/Views/RootView.swift#L59).

- Charts need deliberate `AXChartDescriptor` support and a textual/table alternative; differentiate series with symbols/patterns as well as color. See [ChartView.swift:53](../ios/Views/Chat/ChartView.swift#L53).

- Math, timestamps, and dictation hints contain fixed point sizes. Prefer semantic fonts or `@ScaledMetric` and test at AX5 sizes. See [MarkdownMessageView.swift:100](../ios/Views/Chat/MarkdownMessageView.swift#L100).

- Explicitly label code-copy, search-clear, and backend-info icon controls instead of relying on SF Symbol inference.

- Add accessibility regression coverage: `performAccessibilityAudit`, large-content-size tests, Reduce Motion, pseudo-localization, and assistive actions for mic/history/prompts. The current UI suite covers only drawer behavior.

Most ordinary SwiftUI forms, buttons, toggles, pickers, navigation links, adaptive colors, and semantic body text already inherit appropriate platform behavior.
