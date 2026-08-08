import Foundation

struct PromptLibrary {
    struct PromptPreset: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    static let customPresetID = "custom"
    static let presets: [PromptPreset] = [
        .init(
            id: "default",
            title: "Clear + preserved intent",
            text: "Rewrite the text with clearer grammar and tone while preserving the author's intent. Return only the revised text."
        ),
        .init(
            id: "professional",
            title: "Professional tone",
            text: "Rewrite the text in a concise, professional tone suitable for business communication. Keep the original meaning. Return only the revised text."
        ),
        .init(
            id: "friendly",
            title: "Friendly + concise",
            text: "Rewrite the text so it sounds friendly, concise, and approachable while preserving the meaning. Return only the revised text."
        ),
        .init(
            id: "shorten",
            title: "Shorten",
            text: "Reduce the length of the text while keeping the key information and clarity. Return only the revised text."
        ),
        .init(
            id: "expand",
            title: "Expand/explain",
            text: "Expand the text with more context and clarity while keeping the same intent and voice. Return only the revised text."
        )
    ]

    static func title(for instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = presets.first(where: { $0.text == trimmed }) {
            return match.title
        }
        return "Custom"
    }

    static func presetID(for instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = presets.first(where: { $0.text == trimmed }) {
            return match.id
        }
        return customPresetID
    }
}
