import Foundation

/// User-facing elapsed-time labels for completed model reasoning.
public enum ReasoningDuration {
    public static func format(_ duration: TimeInterval) -> String {
        let totalSeconds = max(1, Int(duration.rounded()))
        guard totalSeconds >= 60 else {
            return "\(totalSeconds) \(totalSeconds == 1 ? "second" : "seconds")"
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let minuteLabel = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        guard seconds > 0 else { return minuteLabel }
        return "\(minuteLabel) \(seconds) \(seconds == 1 ? "second" : "seconds")"
    }
}
