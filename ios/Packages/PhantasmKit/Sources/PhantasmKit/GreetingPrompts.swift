import Foundation

/// The greeting shown on the empty-chat home screen. A phrase is picked at
/// random each time a new chat opens, in the spirit of "What can I help with?".
public enum GreetingPrompts {
    /// Fallback used only if `all` is ever emptied.
    public static let fallback = "What can I help with?"

    public static let all: [String] = [
        "What can I help with?",
        "What's on your mind?",
        "Where should we start?",
        "What are you working on?",
        "Ready when you are.",
        "What's the task?",
        "What do you need?",
        "Got something to think through?",
        "What's next on your list?",
        "Need a hand with anything?",
        "What's the idea?",
        "What's the goal?",
        "Stuck on something?",
        "Tell me what you need.",
        "What's the plan?",
        "What's the project?",
        "Curious about something?",
        "What can I draft for you?",
        "What can I help you write?",
        "What should we tackle first?",
        "What are we solving?",
        "Want me to look into something?",
        "What do you want to know?",
        "What do you want to make?",
        "What's the problem?",
        "What do you want to learn?",
        "Where are we headed?",
        "Something not working?",
        "What are you trying to do?",
        "What's the first step?",
        "What do you want to figure out?",
        "Anything I can take off your plate?",
        "Walk me through it.",
        "What are you up to?",
        "What do you want to get done?",
    ]

    /// A random greeting, using the system generator.
    public static func random() -> String {
        all.randomElement() ?? fallback
    }

    /// A random greeting using a caller-supplied generator (for deterministic
    /// tests).
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        all.randomElement(using: &generator) ?? fallback
    }
}
