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

    static let saveTheCat = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000004")!,
        name: "Save the Cat!",
        description: "A practical fifteen-beat structure for commercial, character-driven stories with a clear emotional arc.",
        beats: [
            .init(role: "opening_image", label: "Opening Image", description: "Show the protagonist and world before the story changes."),
            .init(role: "theme_stated", label: "Theme Stated", description: "Hint at the lesson or central question the protagonist must face."),
            .init(role: "setup", label: "Setup", description: "Establish the cast, want, flaw, and stakes before the disruption."),
            .init(role: "catalyst", label: "Catalyst", description: "An event makes the old status quo impossible to maintain."),
            .init(role: "debate", label: "Debate", description: "The protagonist weighs the risks of responding to the new problem."),
            .init(role: "break_into_two", label: "Break into Two", description: "The protagonist chooses an approach and enters a changed situation."),
            .init(role: "b_story", label: "B Story", description: "Introduce the relationship or secondary thread that carries the theme."),
            .init(role: "fun_and_games", label: "Fun and Games", description: "Deliver the central promise of the premise as complications grow."),
            .init(role: "midpoint", label: "Midpoint", description: "A false victory or defeat raises the stakes and changes the game."),
            .init(role: "bad_guys_close_in", label: "Bad Guys Close In", description: "External pressure and internal flaws tighten around the protagonist."),
            .init(role: "all_is_lost", label: "All Is Lost", description: "The protagonist reaches a visible low point and loses a source of hope."),
            .init(role: "dark_night_of_the_soul", label: "Dark Night of the Soul", description: "The protagonist confronts what must change to move forward."),
            .init(role: "break_into_three", label: "Break into Three", description: "A realization combines the A and B stories into a new plan."),
            .init(role: "finale", label: "Finale", description: "The protagonist applies the lesson and resolves the central conflict."),
            .init(role: "final_image", label: "Final Image", description: "Echo the opening image to show how the world or protagonist changed.")
        ]
    )

    static let storyCircle = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000005")!,
        name: "Story Circle",
        description: "Dan Harmon's eight-step cycle: a character leaves comfort, adapts through conflict, and returns changed.",
        beats: [
            .init(role: "you", label: "You", description: "Show the character in a zone of comfort and establish what they want."),
            .init(role: "need", label: "Need", description: "The character enters an unfamiliar situation to pursue a need."),
            .init(role: "go", label: "Go", description: "The character adapts while facing escalating obstacles."),
            .init(role: "search", label: "Search", description: "The character experiments, learns, and pays a price for progress."),
            .init(role: "find", label: "Find", description: "The character gets what they sought, often with an unexpected cost."),
            .init(role: "take", label: "Take", description: "The character sacrifices or suffers to bring the prize home."),
            .init(role: "return", label: "Return", description: "The character returns to a familiar world carrying the consequences."),
            .init(role: "change", label: "Change", description: "The character demonstrates what they learned and how they are different.")
        ]
    )

    static let freytagsPyramid = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000006")!,
        name: "Freytag's Pyramid",
        description: "A five-part dramatic arc built around rising action, a climax, and falling consequences.",
        beats: [
            .init(role: "exposition", label: "Exposition", description: "Introduce the world, characters, conflict, and conditions of the story."),
            .init(role: "rising_action", label: "Rising Action", description: "Complications build as choices intensify the central conflict."),
            .init(role: "climax", label: "Climax", description: "The decisive turning point where the conflict reaches maximum intensity."),
            .init(role: "falling_action", label: "Falling Action", description: "Consequences unfold and remaining conflicts move toward resolution."),
            .init(role: "denouement", label: "Denouement", description: "The final situation settles and the meaning of the events becomes clear.")
        ]
    )

    static let kishotenketsu = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000007")!,
        name: "Kishōtenketsu",
        description: "A four-part structure that develops an idea, introduces a turn, and creates meaning through juxtaposition rather than a central conflict.",
        beats: [
            .init(role: "ki", label: "Ki — Introduction", description: "Establish the setting, characters, and initial idea."),
            .init(role: "sho", label: "Shō — Development", description: "Develop the situation and deepen the world without a major reversal."),
            .init(role: "ten", label: "Ten — Twist", description: "Introduce a surprising new element or perspective that reframes what came before."),
            .init(role: "ketsu", label: "Ketsu — Conclusion", description: "Connect the elements and show the new understanding or harmony.")
        ]
    )

    static let allTemplates: [StoryArcTemplate] = [
        .threeAct, .herosJourney, .mystery, .saveTheCat, .storyCircle,
        .freytagsPyramid, .kishotenketsu
    ]
}

/// A single beat definition inside a `StoryArcTemplate`.
struct StoryArcBeatTemplate: Identifiable, Hashable {
    let role: String
    let label: String
    let description: String
    var id: String { role }
}
