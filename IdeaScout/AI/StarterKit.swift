// StarterKit.swift
// The starter kit for one killer idea: a plan for the first version (spec, screens, data, a cheap stack, what to
// leave out, the first slice and rules for the AI coding tool). Made by one cloud AI call on demand, checked and
// clamped here, and saved on the idea as JSON. The wording for each coding tool is in StarterKitPrompts.swift.

import Foundation

/// A first-version plan for one idea. Saved on `KillerIdea.starterKitJSON`, so these property names are stored on
/// users' phones: never rename them, and make any new property optional.
struct StarterKit: Codable, Equatable, Sendable {
    /// One screen of the first version.
    struct Screen: Codable, Equatable, Sendable {
        var name: String
        var purpose: String
    }

    /// One kind of thing the product stores.
    struct Entity: Codable, Equatable, Sendable {
        var name: String
        var fields: [String]
        var notes: String
    }

    /// One part of the tech stack and the choice for it.
    struct StackPart: Codable, Equatable, Sendable {
        var part: String
        var choice: String
        var why: String
    }

    /// One paragraph: who it's for, the job it does, what the customer gets.
    var spec: String
    var screens: [Screen]
    var dataModel: [Entity]
    var stack: [StackPart]
    /// Rough monthly running cost for the first customers.
    var monthlyCost: String
    /// Features to leave out of the first version.
    var leaveOut: [String]
    /// The first thin piece to build end to end.
    var firstSlice: String
    /// Checks that show the first slice works.
    var doneWhen: [String]
    /// Rules for the AI coding tool to follow throughout the build.
    var projectRules: [String]

    // MARK: - Limits (AI output is untrusted, so every list and text is capped)

    static let maxScreens = 8
    static let maxEntities = 8
    static let maxFields = 12
    static let maxStackParts = 8
    static let maxListItems = 10
    static let maxDoneWhen = 6

    // MARK: - Schema and parsing

    /// JSON Schema for the reply. Keep in sync with `parse` and `StarterKitPrompts.instructions`.
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "spec": ["type": "string"],
            "screens": ["type": "array", "items": object(["name", "purpose"])],
            "data_model": ["type": "array", "items": [
                "type": "object",
                "properties": ["entity": ["type": "string"], "fields": ["type": "array", "items": ["type": "string"]],
                               "notes": ["type": "string"]],
                "required": ["entity", "fields", "notes"],
                "additionalProperties": false,
            ] as [String: Any]],
            "stack": ["type": "array", "items": object(["part", "choice", "why"])],
            "monthly_cost": ["type": "string"],
            "leave_out": ["type": "array", "items": ["type": "string"]],
            "first_slice": ["type": "string"],
            "done_when": ["type": "array", "items": ["type": "string"]],
            "project_rules": ["type": "array", "items": ["type": "string"]],
        ] as [String: Any],
        "required": requiredFields,
        "additionalProperties": false,
    ]

    /// The top-level fields the reply must have (also checked by the tests against the instructions).
    static let requiredFields = ["spec", "screens", "data_model", "stack", "monthly_cost", "leave_out", "first_slice",
                                 "done_when", "project_rules"]

    /// A schema object whose properties are all strings.
    private static func object(_ names: [String]) -> [String: Any] {
        ["type": "object", "properties": Dictionary(uniqueKeysWithValues: names.map { ($0, ["type": "string"]) }),
         "required": names, "additionalProperties": false]
    }

    /// Decodes and cleans the AI's reply.
    /// - Parameter data: The reply in Claude's message format.
    /// - Returns: The kit, clamped and with links removed (see `sanitised()`).
    /// - Throws: `SummarizerError` if the reply was refused, cut off or has no spec or screens; `DecodingError`
    ///   if it doesn't match `schema`.
    static func parse(_ data: Data) throws -> StarterKit {
        /// The reply's JSON shape (field names match the schema).
        struct Wire: Decodable {
            struct S: Decodable { let name, purpose: String }
            struct E: Decodable { let entity: String; let fields: [String]; let notes: String }
            struct P: Decodable { let part, choice, why: String }
            let spec, monthly_cost, first_slice: String
            let screens: [S]
            let data_model: [E]
            let stack: [P]
            let leave_out, done_when, project_rules: [String]
        }
        let w = try JSONDecoder().decode(Wire.self, from: try LLMSummarizer.extractJSON(data))
        let kit = StarterKit(
            spec: w.spec, screens: w.screens.map { Screen(name: $0.name, purpose: $0.purpose) },
            dataModel: w.data_model.map { Entity(name: $0.entity, fields: $0.fields, notes: $0.notes) },
            stack: w.stack.map { StackPart(part: $0.part, choice: $0.choice, why: $0.why) },
            monthlyCost: w.monthly_cost, leaveOut: w.leave_out, firstSlice: w.first_slice, doneWhen: w.done_when,
            projectRules: w.project_rules).sanitised()
        guard !kit.spec.isEmpty, !kit.screens.isEmpty else { throw SummarizerError.badResponse("the starter kit was empty") }
        return kit
    }

    /// The kit with every text trimmed, links removed and lengths and counts capped, and empty entries dropped.
    /// - Returns: The cleaned kit.
    func sanitised() -> StarterKit {
        let c = Self.clean
        return StarterKit(
            spec: c(spec, 900),
            screens: Array(screens.map { Screen(name: c($0.name, 60), purpose: c($0.purpose, 240)) }
                .filter { !$0.name.isEmpty }.prefix(Self.maxScreens)),
            dataModel: Array(dataModel.map {
                Entity(name: c($0.name, 60), fields: Self.list($0.fields, max: Self.maxFields, length: 80), notes: c($0.notes, 200))
            }.filter { !$0.name.isEmpty }.prefix(Self.maxEntities)),
            stack: Array(stack.map { StackPart(part: c($0.part, 40), choice: c($0.choice, 80), why: c($0.why, 200)) }
                .filter { !$0.part.isEmpty && !$0.choice.isEmpty }.prefix(Self.maxStackParts)),
            monthlyCost: c(monthlyCost, 160),
            leaveOut: Self.list(leaveOut, max: Self.maxListItems, length: 160),
            firstSlice: c(firstSlice, 500),
            doneWhen: Self.list(doneWhen, max: Self.maxDoneWhen, length: 160),
            projectRules: Self.list(projectRules, max: Self.maxListItems, length: 200))
    }

    /// Security: the kit is shared into AI coding tools that can open links, so links are removed rather than
    /// passed on. Also collapses whitespace and caps the length.
    /// - Parameters:
    ///   - text: AI-written text.
    ///   - max: Most characters kept.
    /// - Returns: The cleaned text.
    static func clean(_ text: String, _ max: Int) -> String {
        let noLinks = text.replacing(#/(?i)\b(?:[a-z][a-z0-9+.\-]*:\/\/|www\.)\S+/#, with: "")
        let words = noLinks.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(max))
    }

    /// Cleans each entry, drops empty ones and keeps at most `max`.
    private static func list(_ items: [String], max: Int, length: Int) -> [String] {
        Array(items.map { clean($0, length) }.filter { !$0.isEmpty }.prefix(max))
    }
}

extension KillerIdea {
    /// The saved starter kit, or `nil` when none has been made (or the saved text can't be read).
    var starterKit: StarterKit? {
        get {
            guard !starterKitJSON.isEmpty else { return nil }
            return try? JSONDecoder().decode(StarterKit.self, from: Data(starterKitJSON.utf8))
        }
        set {
            starterKitJSON = newValue.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}
