import PhantasmKit
import SwiftUI

/// One sheet, two stages: every host presents pairing through a single
/// `.sheet(item:)` so the scanner → confirmation hand-off swaps content in
/// place and can't race a second presentation. Only one pairing can be in
/// flight at a time, so constant ids per stage suffice.
enum PairingSheetRoute: Identifiable {
    case scan
    case confirm(PairingPayload)

    var id: String {
        switch self {
        case .scan: return "scan"
        case .confirm: return "confirm"
        }
    }
}

/// The whole pairing flow as one sheet body. Hosts own only the route state
/// and an `onPaired` callback — the staging (and its no-dismiss invariant)
/// lives here, once, instead of being re-wired in every entry point.
///
/// A scanned payload lands in the standard backend editor, prefilled — same
/// screen as Add Backend, so Test Connection and the default-model picker
/// come for free, and nothing is stored until the user reviews and saves
/// (the confirmation step docs/qr-pairing.md requires). When the payload
/// matches a saved backend (canonical URL — host case and default ports
/// ignored), the editor opens *that* profile so re-pairing updates in place;
/// its Keychain prefill keeps the saved token when the code carries none.
struct PairingFlowSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var route: PairingSheetRoute?
    var onPaired: () -> Void = {}

    var body: some View {
        switch route {
        case .confirm(let payload):
            ProfileEditView(
                profile: payload.matchingProfile(in: env.profiles),
                pairing: payload,
                onSaved: onPaired
            )
        case .scan, nil:
            // nil only during the dismiss animation; keep the last stage up.
            PairingScanSheet { route = .confirm($0) }
        }
    }
}
