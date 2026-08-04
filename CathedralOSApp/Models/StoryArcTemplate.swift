import Foundation

/// A story arc template seeded in Supabase (mirrored locally for Phase 0/1
/// before the fetch service ships). The 3 starter templates seeded by the
/// initial novel-building migration live here; future templates added via
/// new migrations will be added here too.
///
/// UUIDs match the seed data in
/// `supabase/migrations/20260804210000_add_novel_building_schema.sql` so
/// the iOS-created `StoryArc` rows point at the same template identity the
/// cloud knows about.
struct StoryArcTemplate: Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String
    let beats: [StoryArcBeatTemplate]

    /// Deterministic UUIDs match the seed data in the initial novel-building
    /// migration. Do not edit without also updating the migration's INSERT.
    static let threeAct = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000001")!,
        name: "Three-Act",
        description: "Classical three-act structure: setup, confrontation, resolution. Universal across most fiction genres.",
        beats: [
            .init(role: "setup",              label: "Setup",              description: "Introduce the world, characters, and the ordinary life that will be disrupted."),
            .init(role: "inciting_incident",  label: "Inciting Incident",  description: "The event that disrupts the ordinary world and sets the story in motion."),
            .init(role: "first_plot_point",   label: "First Plot Point",   description: "The protagonist commits to the central conflict and the story tilts into Act II."),
            .init(role: "rising_action",      label: "Rising Action",      description: "Escalating complications, subplots, and stakes as the protagonist pursues the goal."),
            .init(role: "midpoint",           label: "Midpoint",           description: "A reversal or revelation that doubles the stakes and reframes the conflict."),
            .init(role: "crisis",             label: "Crisis",             description: "The lowest point — what looks like defeat, the dark night of the soul."),
            .init(role: "climax",             label: "Climax",             description: "The decisive confrontation where the protagonist's arc turns."),
            .init(role: "resolution",         label: "Resolution",         description: "The new normal. Loose threads are tied. The world has changed."),
        ]
    )

    static let herosJourney = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000002")!,
        name: "Hero's Journey",
        description: "Joseph Campbell's monomyth: separation, initiation, return. Best for hero-driven adventure and coming-of-age stories.",
        beats: [
            .init(role: "ordinary_world",        label: "Ordinary World",           description: "The hero's normal life before the adventure begins."),
            .init(role: "call_to_adventure",    label: "Call to Adventure",        description: "The hero is presented with a problem, challenge, or opportunity."),
            .init(role: "refusal_of_call",      label: "Refusal of the Call",      description: "The hero hesitates or refuses the adventure, fearing the unknown."),
            .init(role: "meeting_mentor",       label: "Meeting the Mentor",       description: "The hero meets a guide who gives advice, training, or confidence."),
            .init(role: "crossing_threshold",   label: "Crossing the Threshold",   description: "The hero commits to the adventure and enters the special world."),
            .init(role: "tests_allies_enemies", label: "Tests, Allies, Enemies",   description: "The hero faces trials, makes friends, and identifies antagonists."),
            .init(role: "approach_inmost_cave", label: "Approach to the Inmost Cave", description: "The hero nears the central ordeal, often facing a major fear."),
            .init(role: "ordeal",               label: "Ordeal",                   description: "The hero's greatest test — a life-or-death moment of transformation."),
            .init(role: "reward",               label: "Reward",                   description: "The hero claims something of value after surviving the ordeal."),
            .init(role: "road_back",            label: "The Road Back",            description: "The hero begins the return journey, often with new stakes."),
            .init(role: "resurrection",         label: "Resurrection",             description: "A final climactic test where the hero is transformed."),
            .init(role: "return_with_elixir",   label: "Return with the Elixir",   description: "The hero returns to the ordinary world, changed, with something to share."),
        ]
    )

    static let mystery = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000003")!,
        name: "Mystery",
        description: "Crime-driven structure: hook, investigation, false leads, reveal. Engineered for detective stories, thrillers, and puzzles.",
        beats: [
            .init(role: "the_crime",             label: "The Crime / Hook",         description: "Establish the crime, mystery, or question that drives the story."),
            .init(role: "investigation_begins",  label: "Investigation Begins",     description: "The detective/protagonist takes the case and starts gathering evidence."),
            .init(role: "first_suspect",         label: "First Suspect / Red Herring", description: "An early suspect appears strong but is misdirection."),
            .init(role: "rising_tension",        label: "Rising Tension",           description: "Stakes escalate, more clues surface, complications mount."),
            .init(role: "key_revelation",        label: "Key Witness / Revelation", description: "A pivotal clue reshapes the investigation."),
            .init(role: "false_solution",        label: "False Solution",           description: "The protagonist (or reader) is led to a wrong conclusion."),
            .init(role: "real_clue",             label: "Real Clue Surfaces",       description: "The actual culprit or truth becomes visible."),
            .init(role: "confrontation",         label: "Confrontation",            description: "The protagonist confronts the antagonist with the truth."),
            .init(role: "resolution",            label: "Resolution / Reveal",      description: "The case is closed and the world has changed."),
        ]
    )

    static let allTemplates: [StoryArcTemplate] = [.threeAct, .herosJourney, .mystery]
}

/// A single beat definition inside a `StoryArcTemplate`.
struct StoryArcBeatTemplate: Identifiable, Hashable {
    let role: String
    let label: String
    let description: String
    var id: String { role }
}
