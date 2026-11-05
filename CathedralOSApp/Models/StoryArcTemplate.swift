import Foundation

/// A story arc template seeded in Supabase (mirrored locally for Phase 0/1
/// before the fetch service ships). The 3 starter templates seeded by the
/// initial novel-building migration live here; the catalog is extended via
/// forward migrations while IDs stay mirrored locally.
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
    let relationshipFocus: StoryArcRelationshipFocus
    let intimacyMilestoneRoles: [String]

    init(
        id: UUID,
        name: String,
        description: String,
        beats: [StoryArcBeatTemplate],
        relationshipFocus: StoryArcRelationshipFocus = .none,
        intimacyMilestoneRoles: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.beats = beats
        self.relationshipFocus = relationshipFocus
        self.intimacyMilestoneRoles = intimacyMilestoneRoles
    }

    /// Deterministic UUIDs match the seed data in the initial novel-building
    /// migration. Do not edit without also updating the migration's INSERT.
    static let threeAct = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000001")!,
        name: "Three-Act",
        description: "A versatile three-act engine for vivid, escalating drama: an irresistible rupture, a middle that changes what the struggle means, and a decisive, unforgettable consequence. Let the author's genre choose the intensity and aftertaste, not a tidy default. Wild dust: Let the author's genre unleash reckless decisions, bizarre collisions, breathtaking reversals, and an ending no tidy formula could predict.",
        beats: [
            .init(role: "setup",              label: "Setup",              description: "Introduce the world, characters, and the ordinary life that will be disrupted. Creative progression: Begin with a volatile choice whose personal consequences make the old life unstable, not a neutral inventory of traits."),
            .init(role: "inciting_incident",  label: "Inciting Incident",  description: "The event that disrupts the ordinary world and sets the story in motion. Creative progression: An unmistakable, genre-specific disruption destroys one ordinary option and unleashes a new desire or danger."),
            .init(role: "first_plot_point",   label: "First Plot Point",   description: "The protagonist commits to the central conflict and the story tilts into Act II. Creative progression: Let an impulsive commitment sacrifice an escape route and create a problem the opening characters could not anticipate."),
            .init(role: "rising_action",      label: "Rising Action",      description: "Escalating complications, subplots, and stakes as the protagonist pursues the goal. Creative progression: Build radically different kinds of trouble through clashing appetites, escalating decisions, and independently acting people; each alters the next objective."),
            .init(role: "midpoint",           label: "Midpoint",           description: "Deliver a surprising, character-caused reversal that changes the conflict itself, not merely its difficulty. Creative progression: Spring an earned, astonishing reversal that changes who holds power, what the goal means, or whom to trust."),
            .init(role: "crisis",             label: "Crisis",             description: "The lowest point — what looks like defeat, the dark night of the soul. Creative progression: Make accumulated choices annihilate the strategy that has worked so far; no encore of an earlier humiliation or lesson."),
            .init(role: "climax",             label: "Climax",             description: "Force an extraordinary, irreversible, genre-faithful act that transforms the characters' world. Creative progression: Stage the one decisive, unforgettable outcome in a signature character-caused action; earlier scenes cannot pre-complete it."),
            .init(role: "resolution",         label: "Resolution",         description: "Show the changed final situation, what is settled, and what meaningfully remains unresolved. Creative progression: Show consequences in a newly altered world through action, loss, pleasure, or revelation; do not replay the climactic choice."),
        ]
    )

    static let herosJourney = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000002")!,
        name: "Hero's Journey",
        description: "An extraordinary journey through strange encounters, dangerous bonds, temptation, ordeal, and a changed return. The hero may emerge triumphant, haunted, compromised, or monstrous when the authored story warrants it. Wild dust: Let temptation, monstrous companions, absurd wagers, and disastrous desires transform the journey into something nobody planned.",
        beats: [
            .init(role: "ordinary_world",        label: "Ordinary World",           description: "The hero's normal life before the adventure begins. Creative progression: Start with a vivid dependency or private appetite that the adventure will make impossible to maintain."),
            .init(role: "call_to_adventure",    label: "Call to Adventure",        description: "The hero is presented with a problem, challenge, or opportunity. Creative progression: An irresistible or terrifying summons changes an actual relationship and immediately eliminates a familiar option."),
            .init(role: "refusal_of_call",      label: "Refusal of the Call",      description: "The hero hesitates or refuses the adventure, fearing the unknown. Creative progression: Let refusal trigger an unexpected loss, betrayal, temptation, or complication; mere second thoughts do not fill a beat."),
            .init(role: "meeting_mentor",       label: "Meeting the Mentor",       description: "The hero meets a guide who gives advice, training, or confidence. Creative progression: Give the guide an independent, flawed agenda and a consequential bargain, not an interchangeable motivational speech."),
            .init(role: "crossing_threshold",   label: "Crossing the Threshold",   description: "The hero commits to the adventure and enters the special world. Creative progression: Make crossing a point of no return cost a person, privilege, or belief the hero cannot simply recover."),
            .init(role: "tests_allies_enemies", label: "Tests, Allies, Enemies",   description: "The hero faces trials, makes friends, and identifies antagonists. Creative progression: Each encounter must introduce a different power, bizarre alliance, danger, or temptation that changes the objective."),
            .init(role: "approach_inmost_cave", label: "Approach to the Inmost Cave", description: "The hero nears the central ordeal, often facing a major fear. Creative progression: Use an intimate betrayal or unnerving discovery to make the anticipated ordeal more dangerous than previously understood."),
            .init(role: "ordeal",               label: "Ordeal",                   description: "The hero's greatest test — a life-or-death moment of transformation. Creative progression: Break the hero's existing strategy through an extraordinary physical or emotional event, reserving later final transformation."),
            .init(role: "reward",               label: "Reward",                   description: "The hero claims something of value after surviving the ordeal. Creative progression: Make the reward alter loyalties and tempt a disastrous new choice rather than functioning as a static prize."),
            .init(role: "road_back",            label: "The Road Back",            description: "The hero begins the return journey, often with new stakes. Creative progression: Let apparent progress unleash a consequence or pursuit that transforms the route home."),
            .init(role: "resurrection",         label: "Resurrection",             description: "Force a defining, extreme final test that proves what the journey has made the hero, for good or ill. Creative progression: Reserve the final defining choice or ordeal here; it must change who the hero has become, for better or worse."),
            .init(role: "return_with_elixir",   label: "Return with the Elixir",   description: "The hero returns to the ordinary world, changed, with something to share. Creative progression: Return to transformed relationships and a changed world where the result is enacted, not explained again."),
        ]
    )

    static let mystery = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000003")!,
        name: "Mystery",
        description: "An irresistible mystery of volatile people, seductive false answers, and revelations that keep changing whom readers trust. Deliver a surprising but fair truth with a personal cost far beyond closing the case. Wild dust: Suspects can be magnetic, outrageous, grotesque, or dangerous; let each fair clue threaten a bond and each revelation detonate an assumption.",
        beats: [
            .init(role: "the_crime",             label: "The Crime / Hook",         description: "Establish the crime, mystery, or question that drives the story. Creative progression: Give the opening wrong or impossible question an intimate, irresistible human consequence that creates immediate action."),
            .init(role: "investigation_begins",  label: "Investigation Begins",     description: "The detective/protagonist takes the case and starts gathering evidence. Creative progression: An early investigative move should cost access, safety, trust, or freedom, establishing why the search cannot be routine."),
            .init(role: "first_suspect",         label: "First Suspect / Red Herring", description: "An early suspect appears strong but is misdirection. Creative progression: Let a compelling suspect's independent desire produce a consequential misdirection, not just a misleading statement."),
            .init(role: "rising_tension",        label: "Rising Tension",           description: "Stakes escalate, more clues surface, complications mount. Creative progression: Escalate through varied dangerous encounters and changing relationships rather than another batch of interchangeable clues."),
            .init(role: "key_revelation",        label: "Key Witness / Revelation", description: "A pivotal clue reshapes the investigation. Creative progression: Use one hard-earned discovery to reverse whom the protagonist trusts or what the underlying question is."),
            .init(role: "false_solution",        label: "False Solution",           description: "The protagonist (or reader) is led to a wrong conclusion. Creative progression: Make the seductive false answer prompt an irreversible choice whose fallout creates the next mystery state."),
            .init(role: "real_clue",             label: "Real Clue Surfaces",       description: "The actual culprit or truth becomes visible. Creative progression: Reveal the crucial new evidence through human action or risk, distinct from the earlier false answer."),
            .init(role: "confrontation",         label: "Confrontation",            description: "Reveal the earned truth in a dangerous, character-specific confrontation that irreversibly changes loyalties or lives. Creative progression: Give the reserved revelation an explosive personal confrontation with one defensible solution; never solve it twice."),
            .init(role: "resolution",            label: "Resolution / Reveal",      description: "The case is closed and the world has changed. Creative progression: Force a concrete new life or relationship consequence from the truth; no evidence recap or explanatory victory lap."),
        ]
    )

    static let saveTheCat = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000004")!,
        name: "Save the Cat!",
        description: "A propulsive fifteen-beat story of bold choices, unpredictable encounters, major reversals, and the vivid pleasures or terrors of the authored premise. Its transformation may be exhilarating, grotesque, tragic, tender, or morally dark. Wild dust: Treat familiar beats as launchpads for audacious reversals, vivid chaos, and uniquely character-caused consequences.",
        beats: [
            .init(role: "opening_image", label: "Opening Image", description: "Show the protagonist and world before the story changes. Creative progression: Open on a surprising character action that vividly establishes a status quo already under strain."),
            .init(role: "theme_stated", label: "Theme Stated", description: "Hint at the central question or tension the protagonist must face; no moral lesson is required. Creative progression: Let an argument, desire, or incident expose an unresolved contradiction without handing down a moral lesson."),
            .init(role: "setup", label: "Setup", description: "Establish the cast, want, flaw, and stakes before the disruption. Creative progression: Make the ensemble pursue incompatible wants that are poised to collide rather than merely listing their backstories."),
            .init(role: "catalyst", label: "Catalyst", description: "An event makes the old status quo impossible to maintain. Creative progression: A genre-specific rupture irrevocably changes the options available to everyone who matters."),
            .init(role: "debate", label: "Debate", description: "The protagonist weighs the risks of responding to the new problem. Creative progression: Put a dangerous bargain or tempting alternative on the table with consequences, not pages of indecision."),
            .init(role: "break_into_two", label: "Break into Two", description: "The protagonist chooses an approach and enters a changed situation. Creative progression: A bold choice forecloses the earlier route and launches a new arena of action."),
            .init(role: "b_story", label: "B Story", description: "Introduce the relationship or secondary thread that carries the theme. Creative progression: Give a secondary relationship its own independent gamble that tangles causally with the main conflict."),
            .init(role: "fun_and_games", label: "Fun and Games", description: "Deliver imaginative, varied events that embody the unique promise of this premise rather than repeating one type of obstacle. Creative progression: Deliver startling and varied premise-specific set pieces; each must create a new opportunity, danger, or broken allegiance."),
            .init(role: "midpoint", label: "Midpoint", description: "A false victory or defeat raises the stakes and changes the game. Creative progression: Flip the apparent meaning of victory or failure through a spectacular, consequential change of power."),
            .init(role: "bad_guys_close_in", label: "Bad Guys Close In", description: "External pressure and internal flaws tighten around the protagonist. Creative progression: Allow previously made choices to provoke heterogeneous retaliation, betrayal, and escalating costs, not repeated obstacles."),
            .init(role: "all_is_lost", label: "All Is Lost", description: "The protagonist reaches a visible low point and loses a source of hope. Creative progression: Take away something genuinely irreplaceable through the character's own flawed action."),
            .init(role: "dark_night_of_the_soul", label: "Dark Night of the Soul", description: "The protagonist confronts what must change to move forward. Creative progression: Use loss to precipitate a surprising new desire or decision, not another speech about the same truth."),
            .init(role: "break_into_three", label: "Break into Three", description: "A realization combines the A and B stories into a new plan. Creative progression: Change the strategy through a costly collision of primary and secondary relationships, without completing the reserved finale."),
            .init(role: "finale", label: "Finale", description: "Deliver an exceptional, emotionally charged final action whose consequences cannot simply be tidied away. Creative progression: Pay off the central conflict only here in an inventive, emotionally seismic action whose consequences endure."),
            .init(role: "final_image", label: "Final Image", description: "Echo the opening image to show how the world or protagonist changed. Creative progression: Show the final transformed condition through a fresh concrete moment, never a replay of the climax.")
        ]
    )

    static let storyCircle = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000005")!,
        name: "Story Circle",
        description: "An eight-movement spiral from familiar desire into startling discovery, costly possession, and a return that cannot restore the old world. Transformation need not equal improvement. Wild dust: Desire may lead through delirious pleasures, impossible bargains, disastrous possession, and a wildly altered return.",
        beats: [
            .init(role: "you", label: "You", description: "Show the character in a zone of comfort and establish what they want. Creative progression: Make comfort vivid and compromised by one action that sets an unstable desire in motion."),
            .init(role: "need", label: "Need", description: "The character enters an unfamiliar situation to pursue a need. Creative progression: An urgent need forces a costly exit rather than a restatement of existing dissatisfaction."),
            .init(role: "go", label: "Go", description: "The character adapts while facing escalating obstacles. Creative progression: Introduce an unfamiliar, seductive complication that requires a genuinely new tactic or alliance."),
            .init(role: "search", label: "Search", description: "The character experiments, learns, and pays a price for progress. Creative progression: Make experimentation produce an unexpected cost or reversal that changes the search itself."),
            .init(role: "find", label: "Find", description: "The character gets what they sought, often with an unexpected cost. Creative progression: Obtaining the prize should reveal an astonishing new consequence, not conclude the entire arc prematurely."),
            .init(role: "take", label: "Take", description: "The character pays a consequential price for pursuing or possessing what they found. Creative progression: Extract a dangerous, irreversible price for possessing the prize, changing the character's relationships or power."),
            .init(role: "return", label: "Return", description: "The character returns to a familiar world carrying the consequences. Creative progression: Return to a changed social world where old habits cannot solve the new situation."),
            .init(role: "change", label: "Change", description: "Show the character transformed through a bold, specific choice or consequence, for better, worse, or stranger. Creative progression: Show transformation through a decisive new act—liberating, ruinous, absurd, or sublime—not a lesson restated.")
        ]
    )

    static let freytagsPyramid = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000006")!,
        name: "Freytag's Pyramid",
        description: "Five movements of rising pressure toward a breathtaking dramatic collision, followed by consequences that fracture or remake lives. The author's genre decides whether the climax is horrifying, ecstatic, intimate, or devastating. Wild dust: Escalate beyond polite complications into a volcanic collision whose consequences cannot be neatly cleaned up.",
        beats: [
            .init(role: "exposition", label: "Exposition", description: "Introduce the world, characters, conflict, and conditions of the story. Creative progression: Establish compelling people already making incompatible choices that threaten the existing order."),
            .init(role: "rising_action", label: "Rising Action", description: "Complications build as choices intensify the central conflict. Creative progression: Let different desires collide in increasingly surprising acts; every escalation must change stakes or alliances."),
            .init(role: "climax", label: "Climax", description: "Deliver an irreversible confrontation or choice at maximum intensity, surprising in its event and inevitable in hindsight. Creative progression: Reserve the breathtaking irreversible dramatic collision here; no preceding beat may resolve its defining event."),
            .init(role: "falling_action", label: "Falling Action", description: "Consequences unfold and remaining conflicts move toward resolution. Creative progression: Unleash distinct fallout, reversals of fortune, and new personal costs rather than a subdued replay of the collision."),
            .init(role: "denouement", label: "Denouement", description: "Show the changed final situation and what is resolved, uncertain, or unsettled. Creative progression: Pay off the changed world through a final consequential choice or image, without tidying away the story's darker implications.")
        ]
    )

    static let kishotenketsu = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000007")!,
        name: "Kishōtenketsu",
        description: "An inventive four-part architecture that builds fascination, then creates a radical change in meaning through juxtaposition rather than mandatory conflict. The turn can be funny, uncanny, devastating, exquisite, or sublime. Wild dust: Use the turn to make readers gasp, howl, ache, or see reality differently; inventive upheaval need not require a fight.",
        beats: [
            .init(role: "ki", label: "Ki — Introduction", description: "Establish the setting, characters, and initial idea. Creative progression: Introduce a vivid pattern or relationship whose beauty, strangeness, or tension promises further change."),
            .init(role: "sho", label: "Shō — Development", description: "Develop the situation and deepen the world without a major reversal. Creative progression: Deepen through inventive contrast and newly consequential encounters, not a second demonstration of the same motif."),
            .init(role: "ten", label: "Ten — Twist", description: "Introduce a daring new perspective or event that recasts everything established without manufacturing a villain. Creative progression: An extraordinary juxtaposition or event overturns what the earlier pattern meant without forcing a conventional villain."),
            .init(role: "ketsu", label: "Ketsu — Conclusion", description: "Connect the elements and reveal a new relationship or meaning between them, without requiring harmony. Creative progression: Create a changed understanding expressed through a new action or relationship, not a repeated explanation of the twist.")
        ]
    )

    static let romanceHEA = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000008")!,
        name: "Romance / HEA",
        description: "A passionate romance driven by combustible chemistry, clashing desires, revelatory intimacy, costly rupture, and a grand act of choosing love. Deliver the promised HEA/HFN with an exciting, personal route to it—not interchangeable relationship talks. Wild dust: Let lovers make outrageous, costly choices, risk everything for pleasure and attachment, and earn thrilling commitment rather than a sensible negotiation.",
        beats: [
            .init(role: "ordinary_life", label: "Ordinary Life", description: "Establish each lead's life, unmet need, and emotional defenses before the relationship changes them. Creative progression: Establish two combustible private lives through different risky choices that make their future collision consequential."),
            .init(role: "meet_attraction", label: "Meet / Attraction", description: "Bring the leads together and create a meaningful spark, friction, or pull between them. Creative progression: Give attraction an eccentric, difficult, highly specific encounter that changes both leads' immediate plans."),
            .init(role: "resistance", label: "Resistance", description: "Give the leads credible internal or external reasons not to pursue the relationship. Creative progression: Let conflicting desires provoke new action, temptation, or sacrifice rather than iterative talks about whether to date."),
            .init(role: "connection_deepens", label: "Connection Deepens", description: "Build trust, chemistry, shared experience, and vulnerability through consequential interaction. Creative progression: Deepen desire through surprising shared gambles and collisions with others' independent agendas, not interchangeable reassurances."),
            .init(role: "midpoint_intimacy", label: "Midpoint Intimacy", description: "Cross an emotional or physical threshold that makes the relationship harder to dismiss. Creative progression: Make intimacy trigger an irreversible shift in loyalty, power, exposure, or future options; the relationship cannot simply reset."),
            .init(role: "pressure_test", label: "Pressure Test", description: "Apply outside stakes and personal flaws that strain the growing bond. Creative progression: Apply a fresh, external consequence of loving this person that requires a different choice from earlier resistance."),
            .init(role: "rupture", label: "Rupture", description: "Break the relationship or its apparent future through a choice, revelation, fear, or betrayal. Creative progression: Break the bond through a character-caused, genuinely new betrayal or loss, not a replay of previous doubts."),
            .init(role: "realization", label: "Realization", description: "Force the central emotional truth into view and make avoidance impossible. Creative progression: Make the changed understanding compel risky action; realizing the same problem twice is not a separate development."),
            .init(role: "grand_choice", label: "Grand Choice", description: "Demand a daring, costly, unmistakably romantic action that transforms both lives and earns the promised future. Creative progression: Reserve a bold, costly, unmistakable romantic deed for this beat; it must create the promised relationship outcome once."),
            .init(role: "hea_hfn", label: "HEA / HFN", description: "Resolve the core romantic conflict with an earned committed future together. Creative progression: Show the earned HEA or HFN through a vivid changed-life action, not another negotiation of already agreed terms.")
        ],
        relationshipFocus: .primary,
        intimacyMilestoneRoles: ["connection_deepens", "midpoint_intimacy", "grand_choice", "hea_hfn"],
    )

    static let psychologicalThriller = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000009")!,
        name: "Psychological / Domestic Thriller",
        description: "A feverish thriller of obsession, intimate treachery, shifting guilt, and revelations that turn familiar people terrifying. Make the final truth shocking, earned, and emotionally destabilizing. Wild dust: Weaponize intimate knowledge, maddening ambiguity, shameful hunger, and impossible reversals until every familiar relationship feels explosive.",
        beats: [
            .init(role: "normal_surface", label: "Normal Surface", description: "Establish a believable domestic or psychological status quo with subtle fault lines underneath. Creative progression: Begin with a magnetic, plausible relationship already shaped by one disturbing, consequential contradiction."),
            .init(role: "destabilizing_incident", label: "Destabilizing Incident", description: "Introduce the event, discovery, or behavior that makes the protagonist question what is real or safe. Creative progression: An unsettling incident changes what the protagonist can safely believe or do, not just their level of anxiety."),
            .init(role: "suspicion_grows", label: "Suspicion Grows", description: "Accumulate contradictions, evasions, and threatening details without resolving them too early. Creative progression: Let specific evasions and an independently motivated person's actions produce escalating, different dangers."),
            .init(role: "first_reveal", label: "First Reveal", description: "Confirm that an important assumption was wrong and reframe the danger. Creative progression: Confirm a shocking misjudgment that makes the next threat fundamentally unlike the first."),
            .init(role: "isolation", label: "Isolation", description: "Reduce the protagonist's reliable support, credibility, options, or sense of control. Creative progression: Cut off real allies, credibility, or freedom through human decisions; avoid repeating the same suspicious conversation."),
            .init(role: "midpoint_truth_shift", label: "Midpoint Truth Shift", description: "Reveal a larger truth that changes who appears dangerous and what is at stake. Creative progression: Unmask a deeply personal truth that shifts guilt, leverage, or desire and drives a new action."),
            .init(role: "apparent_answer", label: "Apparent Answer", description: "Offer a convincing explanation or temporary solution that seems to settle the central suspicion. Creative progression: Make the persuasive false answer induce a costly, irreversible mistake rather than a temporary feeling of relief."),
            .init(role: "deeper_betrayal", label: "Deeper Betrayal", description: "Expose the hidden betrayal, manipulation, or threat beneath the apparent answer. Creative progression: Turn apparent safety into intimate betrayal through a different character's active agenda and unexpected choice."),
            .init(role: "final_confrontation", label: "Final Confrontation", description: "Force a genuinely unnerving clash with the true source of danger and a revelation that changes the protagonist's world. Creative progression: Reserve the one dreadful, explosive confrontation and central revelation for this beat; its outcome cannot occur earlier."),
            .init(role: "aftermath", label: "Aftermath", description: "Resolve the immediate threat and show the psychological or relational cost of what was uncovered. Creative progression: Leave a changed psychological and relational reality enacted through a final fresh consequence, not exposition.")
        ]
    )

    static let romantasy = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000010")!,
        name: "Romantasy",
        description: "A high-intensity collision of dangerous magic, wonder, forbidden or consuming desire, and loyalties that can remake a world. Fantasy conflict and romantic choices must transform one another spectacularly. Wild dust: Magic and desire should tempt people into reckless bargains, spectacular betrayal, and choices that can wreck a realm or a heart.",
        beats: [
            .init(role: "ordinary_world", label: "Ordinary World", description: "Establish the protagonist, the fantasy world, and the emotional conditions before disruption."),
            .init(role: "magical_disruption", label: "Magical Disruption", description: "Introduce the threat, power, mission, or revelation that overturns the status quo."),
            .init(role: "dangerous_attraction", label: "Dangerous Attraction", description: "Create a compelling romantic pull complicated by allegiance, danger, status, or mistrust."),
            .init(role: "binding_choice", label: "Binding Choice", description: "Force a commitment that ties the protagonist to both the external conflict and romantic counterpart."),
            .init(role: "quest_and_bond", label: "Fantasy Pressure and Bond", description: "Escalate fantasy-world pressures and consequential choices while trust, desire, and mutual dependence deepen."),
            .init(role: "midpoint_revelation", label: "Midpoint Revelation", description: "Reveal a truth about the world, power, danger, or relationship that changes the trajectory."),
            .init(role: "divided_loyalties", label: "Divided Loyalties", description: "Make romantic desire and external duty meaningfully conflict."),
            .init(role: "catastrophic_break", label: "Catastrophic Break", description: "Shatter the current plan or relationship and expose the cost of choosing wrongly."),
            .init(role: "united_choice", label: "United Choice", description: "Have the leads choose what they will stand for together despite the cost."),
            .init(role: "final_battle_and_choice", label: "Defining Stakes and Choice", description: "Deliver an astonishing fantasy consequence decided by a defining, costly romantic choice; no literal battle is required."),
            .init(role: "new_order_together", label: "New Order Together", description: "Establish the changed world and the earned state of the relationship.")
        ],
        relationshipFocus: .primary,
        intimacyMilestoneRoles: ["dangerous_attraction", "quest_and_bond", "united_choice", "new_order_together"],
    )

    static let suspenseCountdown = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000011")!,
        name: "Suspense / Countdown Thriller",
        description: "A relentless countdown of ingenious setbacks, desperation, betrayals, and surprising changes in what the threat demands. End in a nail-biting, earned collision at the clock's edge. Wild dust: Let the clock provoke deranged improvisation, moral collisions, and catastrophic personal costs, never an endless string of similar near-misses.",
        beats: [
            .init(role: "threat_appears", label: "Threat Appears", description: "Introduce a concrete danger with consequences the protagonist cannot ignore."),
            .init(role: "clock_starts", label: "Clock Starts", description: "Create a meaningful deadline and force the protagonist into action."),
            .init(role: "first_pursuit", label: "Threat Tightens", description: "Escalate active danger through pursuit, evasion, discovery, or consequential failed attempts, whichever fits the story."),
            .init(role: "narrowing_options", label: "Narrowing Options", description: "Close off easy solutions and make delay increasingly costly."),
            .init(role: "midpoint_reversal", label: "Midpoint Reversal", description: "Change the protagonist's understanding of the threat, target, or enemy."),
            .init(role: "major_loss", label: "Major Loss", description: "Inflict a serious failure or loss that makes the deadline feel nearly impossible."),
            .init(role: "final_lead", label: "Last Opening", description: "Reveal an earned opening, hard choice, or opportunity that makes one last attempt possible."),
            .init(role: "race_to_deadline", label: "Race to the Deadline", description: "Compress time and escalate obstacles as the protagonist commits everything to the final attempt."),
            .init(role: "showdown", label: "Showdown", description: "At the deadline, force an inventive, decisive sacrifice or gamble that produces the promised suspense payoff."),
            .init(role: "aftermath", label: "Aftermath", description: "Show the immediate consequences and the new state after the threat is resolved.")
        ]
    )

    static let scienceFictionSurvival = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000012")!,
        name: "Science-Fiction Problem / Survival",
        description: "A mind-bending survival story of impossible phenomena, terrifying implications, emotional collisions, and discoveries that redraw what is possible. The breakthrough must change people and their world, not merely fix a device. Wild dust: Let impossible discoveries corrupt desires, rupture relationships, and produce awe or existential terror beyond a routine technical fix.",
        beats: [
            .init(role: "baseline_world", label: "Baseline World", description: "Establish the system, environment, technology, and ordinary operating assumptions."),
            .init(role: "impossible_problem", label: "Impossible Problem", description: "Introduce the anomaly, disaster, discovery, or survival problem that breaks those assumptions."),
            .init(role: "first_hypothesis", label: "First Hypothesis", description: "Commit to an initial explanation or solution based on the best available evidence."),
            .init(role: "failed_solution", label: "Failed Solution", description: "Demonstrate that the first approach is insufficient and make the problem more dangerous or complex."),
            .init(role: "deeper_discovery", label: "Deeper Discovery", description: "Reveal a staggering new truth or rule that transforms the problem and demands a deeply personal response."),
            .init(role: "resource_collapse", label: "Resource Collapse", description: "Remove critical time, energy, safety, personnel, or technological capacity."),
            .init(role: "breakthrough", label: "Breakthrough", description: "Achieve the conceptual or technical insight that makes a real solution possible."),
            .init(role: "sacrifice_choice", label: "Sacrifice Choice", description: "Force a costly decision about what must be risked or surrendered for the solution to work."),
            .init(role: "final_solution", label: "Final Solution", description: "Execute the decisive solution under maximum pressure."),
            .init(role: "changed_world", label: "Changed World", description: "Resolve survival and show how the discovery permanently changes the characters or world.")
        ]
    )

    static let dystopianRebellion = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000013")!,
        name: "Dystopian Rebellion",
        description: "A fierce rebellion of seductive power, dangerous loyalty, treachery, desperate sacrifice, and upheaval. Resistance may liberate or corrupt; the new order need not be reassuring. Wild dust: Revolt can become beautiful, obscene, ecstatic, or monstrous as volatile characters invent dangerous forms of power and betrayal.",
        beats: [
            .init(role: "controlled_normal", label: "Controlled Normal", description: "Establish the rules, rewards, punishments, and normalized compromises of the oppressive system."),
            .init(role: "crack_in_system", label: "Crack in the System", description: "Expose a contradiction, injustice, or forbidden truth that the protagonist cannot unsee."),
            .init(role: "awakening", label: "Awakening", description: "Turn private doubt into a clearer understanding of the system and the protagonist's place in it."),
            .init(role: "first_defiance", label: "First Defiance", description: "Make an irreversible act of resistance that creates real consequences."),
            .init(role: "resistance_builds", label: "Resistance Builds", description: "Expand allies, tactics, and stakes while the regime becomes more aware of the threat."),
            .init(role: "regime_retaliates", label: "Regime Retaliates", description: "Demonstrate the system's power through punishment, repression, or targeted loss."),
            .init(role: "betrayal_or_loss", label: "Betrayal / Loss", description: "Break trust or remove a key source of hope, forcing a reassessment of the rebellion."),
            .init(role: "uprising_choice", label: "Uprising Choice", description: "Commit to the decisive action despite the personal and collective cost."),
            .init(role: "confrontation", label: "Confrontation", description: "Make the defining clash an irreversible rupture that exposes what gaining power really costs, not just a formal change of control."),
            .init(role: "new_order_cost", label: "New Order / Cost", description: "Show what changed, what did not, and what the victory or failure ultimately cost.")
        ]
    )

    static let darkRomance = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000014")!,
        name: "Dark Romance",
        description: "A transgressive romance of consuming desire, obsession, dangerous dependence, temptation, moral compromise, betrayal, and shifting power. Let passion cause shocking and intimate consequences. Development need not mean rehabilitation, and an earned romantic future need not be wholesome, domestic, or emotionally tidy. Wild dust: Embrace obsession, dangerous seduction, forbidden longing, irrational devotion, and shocking intimate consequences; do not automatically make the lovers well-adjusted.",
        beats: [
            .init(role: "dangerous_encounter", label: "Dangerous Encounter", description: "Introduce an attraction carrying credible emotional, social, moral, or physical risk."),
            .init(role: "boundary_drawn", label: "Boundary Drawn", description: "Expose a dangerous imbalance or forbidden limit that intensifies the attraction and provokes consequential choices; this is not a recurring discussion of relationship rules."),
            .init(role: "entanglement", label: "Entanglement", description: "Make desire, secrecy, dependence, and compromising choices collide until a new situation becomes inescapable."),
            .init(role: "power_shift", label: "Power Shift", description: "Change who holds leverage or what each character believes about the other."),
            .init(role: "vulnerability_revealed", label: "Vulnerability Revealed", description: "Expose a truth or wound that complicates the apparent power dynamic."),
            .init(role: "moral_pressure", label: "Moral Pressure", description: "Force the relationship against a meaningful ethical, emotional, or external limit."),
            .init(role: "betrayal_or_rupture", label: "Betrayal / Rupture", description: "Break trust or make continuation of the relationship appear unacceptable or impossible."),
            .init(role: "reckoning", label: "Reckoning", description: "Force an emotionally explosive encounter with the relationship's real price; it may intensify devotion, ruin it, corrupt it, or change it, not automatically redeem anyone."),
            .init(role: "chosen_terms", label: "Chosen Terms", description: "Deliver a bold, costly, defining choice about the bond through decisive action rather than a list of healthy boundaries."),
            .init(role: "earned_resolution", label: "Earned Resolution", description: "Resolve the central romance through a memorable, earned choice with lasting consequences; the future may remain obsessive, precarious, dangerous, or morally unsettling.")
        ],
        relationshipFocus: .primary,
        intimacyMilestoneRoles: ["entanglement", "vulnerability_revealed", "chosen_terms", "earned_resolution"],
    )

    static let epicFantasyQuest = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000015")!,
        name: "Epic Fantasy Quest",
        description: "A vast, perilous adventure of strange civilizations, impossible bargains, magical terrors, fractured fellowship, and sacrifices capable of remaking the world. Each revelation should change the quest itself. Wild dust: Invent frightening wonders, outrageous companions, soul-shaking reversals, and choices that make the original quest unrecognizable.",
        beats: [
            .init(role: "threatened_home", label: "Threatened Home", description: "Establish the world and the danger that makes remaining unchanged impossible."),
            .init(role: "call_or_mission", label: "Call / Mission", description: "Define the quest, objective, or burden that must be undertaken."),
            .init(role: "fellowship_forms", label: "Fellowship Forms", description: "Assemble the companions, alliances, or obligations needed for the journey."),
            .init(role: "first_threshold", label: "First Threshold", description: "Leave safety behind and enter the true arena of the quest."),
            .init(role: "trials_and_world", label: "Trials and Wider World", description: "Escalate obstacles while revealing the scale, cultures, powers, and costs of the conflict."),
            .init(role: "midpoint_revelation", label: "Midpoint Revelation", description: "Reveal a truth about the enemy, artifact, prophecy, mission, or protagonist that changes the quest."),
            .init(role: "catastrophic_setback", label: "Catastrophic Setback", description: "Break the plan, fellowship, or hope through a major defeat or loss."),
            .init(role: "regroup_and_sacrifice", label: "Regroup and Sacrifice", description: "Recommit through a costly choice informed by what the journey has taught."),
            .init(role: "final_objective", label: "Final Objective", description: "Deliver a breathtaking and causally earned event that transforms the world's future at a profound personal price."),
            .init(role: "return_or_new_age", label: "Return / New Age", description: "Show the transformed world, surviving relationships, and consequences of the quest.")
        ]
    )

    static let sevenPoint = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000016")!,
        name: "Seven-Point Story Structure",
        description: "A sharp seven-turn architecture of irresistible contrast, disruptive choices, severe pressure, and a startling consequential payoff. Let the selected genre—not a generic plotting formula—determine the spectacle or intimacy. Wild dust: Each structural turn may unleash a daring, genre-specific reversal instead of another safe step in a universal formula.",
        beats: [
            .init(role: "hook", label: "Hook", description: "Establish the protagonist, central lack, and starting conditions in direct contrast with the eventual ending."),
            .init(role: "plot_turn_one", label: "Plot Turn One", description: "Introduce the event that commits the protagonist to the central story problem."),
            .init(role: "pinch_point_one", label: "Pinch Point One", description: "Apply direct pressure from a person, circumstance, or opposing force and demonstrate the cost of failure."),
            .init(role: "midpoint", label: "Midpoint", description: "Shift the protagonist from reaction toward active pursuit through a major realization or reversal."),
            .init(role: "pinch_point_two", label: "Pinch Point Two", description: "Deliver the strongest pressure or loss before the endgame and strip away an important support."),
            .init(role: "plot_turn_two", label: "Plot Turn Two", description: "Reveal or earn the final information, capacity, or decision needed to face the ending."),
            .init(role: "resolution", label: "Resolution", description: "Pay off the core contrast through a decisive, genre-faithful transformation, never a routine wrap-up.")
        ]
    )

    static let horrorDread = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000017")!,
        name: "Horror / Escalating Dread",
        description: "A nightmare engine of encroaching wrongness, bizarre revelations, collapsing safety, and a genuinely terrifying manifestation. Leave unforgettable images and consequences that disturb the reader long after the ending. Wild dust: Pursue uncanny images, monstrous intimacy, grotesque surprises, and terror that changes the rules of the nightmare itself.",
        beats: [
            .init(role: "normal_with_crack", label: "Normal with a Crack", description: "Establish ordinary life while planting a specific detail that feels wrong before its meaning is known."),
            .init(role: "first_intrusion", label: "First Intrusion", description: "Let the threat cross into the protagonist's world in a way that can no longer be fully ignored."),
            .init(role: "denial_or_misread", label: "Denial / Misread", description: "Allow a plausible explanation or wrong interpretation to delay full understanding."),
            .init(role: "confirmation", label: "Confirmation", description: "Prove that the threat is real and more dangerous than initially believed."),
            .init(role: "isolation", label: "Isolation", description: "Cut off safety, help, escape, credibility, or familiar rules."),
            .init(role: "rules_discovered", label: "Threat Pattern", description: "Reveal or complicate the threat's behavior and the cost of confronting it, without requiring a solvable rule."),
            .init(role: "false_safety", label: "False Safety", description: "Offer a temporary escape or solution that fails to end the threat."),
            .init(role: "full_manifestation", label: "Full Manifestation", description: "Bring the horror into an unmistakably nightmarish form that destroys safety or meaning, not a generic threatening encounter."),
            .init(role: "survival_confrontation", label: "Survival Confrontation", description: "Force the protagonist into the decisive encounter with the threat."),
            .init(role: "final_image", label: "Final Image", description: "Leave a haunting, specifically horrific aftershock whether anyone survives, escapes, or becomes part of the horror.")
        ]
    )

    static let sportsRomance = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000018")!,
        name: "Sports Romance",
        description: "An exhilarating collision of competitive ambition, fierce rivalry, obsessive drive, public pressure, and romantic chemistry. Make both the athletic climax and love choice thrilling and costly, with an earned romantic future. Wild dust: Fierce chemistry, reckless ambition, outrageous rivalries, public humiliation, and a truly shocking contest can upend the lovers' world.",
        beats: [
            .init(role: "season_setup", label: "Season Setup", description: "Establish the athletic stakes, team or competitive environment, and each lead's current priorities."),
            .init(role: "meet_or_rivalry", label: "Meet / Rivalry", description: "Create the relationship spark through competition, collision, recruitment, or a shared sports context."),
            .init(role: "forced_proximity", label: "Forced Proximity", description: "Give the leads a credible reason to spend meaningful time together despite resistance."),
            .init(role: "chemistry_builds", label: "Chemistry Builds", description: "Deepen attraction and trust while training, competition, or team pressures escalate."),
            .init(role: "first_commitment", label: "First Commitment", description: "Cross a relationship threshold that makes the connection real and consequential."),
            .init(role: "public_private_pressure", label: "Public / Private Pressure", description: "Bring career, team, reputation, family, or media pressures against the relationship."),
            .init(role: "athletic_setback", label: "Athletic Setback", description: "Create a meaningful competitive loss, injury, failure, or career threat that changes priorities."),
            .init(role: "relationship_rupture", label: "Relationship Rupture", description: "Break the couple's apparent future at the moment both sport and relationship stakes peak."),
            .init(role: "game_day_choice", label: "Game-Day Choice", description: "Make the defining athletic moment and romantic decision collide in one emotionally charged, unforgettable payoff."),
            .init(role: "hea_hfn", label: "HEA / HFN", description: "Deliver the earned relationship future and show how it fits with the characters' athletic lives.")
        ],
        relationshipFocus: .primary,
        intimacyMilestoneRoles: ["chemistry_builds", "first_commitment", "game_day_choice", "hea_hfn"],
    )

    static let romanticSuspense = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000019")!,
        name: "Romantic Suspense",
        description: "A combustible romance under mounting peril, where chemistry, secrets, betrayal, and risky trust reshape the danger itself. Deliver a thrilling, earned joint climax that makes the relationship essential to survival. Wild dust: Desire must provoke dangerous gambles, electric reversals, startling betrayals, and a climax where love transforms survival.",
        beats: [
            .init(role: "danger_hook", label: "Danger Hook", description: "Introduce the threat that forces the leads into the same problem."),
            .init(role: "forced_alliance", label: "Forced Alliance", description: "Make cooperation necessary even though trust is incomplete."),
            .init(role: "distrust", label: "Distrust", description: "Expose reasons the leads cannot yet fully rely on one another."),
            .init(role: "intimacy_under_pressure", label: "Intimacy Under Pressure", description: "Deepen attraction and vulnerability while danger keeps increasing."),
            .init(role: "threat_escalates", label: "Threat Escalates", description: "Make the antagonist or danger more immediate, capable, and personal."),
            .init(role: "midpoint_reveal", label: "Midpoint Reveal", description: "Reveal a truth that changes both the danger and the relationship."),
            .init(role: "betrayal_or_misread", label: "Betrayal / Misread", description: "Break trust or make one lead appear complicit with the threat."),
            .init(role: "trust_choice", label: "Trust Choice", description: "Make an active, risky decision to trust based on earned knowledge rather than convenience."),
            .init(role: "joint_showdown", label: "Joint Showdown", description: "Resolve the danger through surprising coordinated action driven by an emotionally costly romantic decision, not just exposure or outside rescue."),
            .init(role: "safety_and_commitment", label: "Safety and Commitment", description: "Resolve the threat and establish the earned romantic future.")
        ],
        relationshipFocus: .primary,
        intimacyMilestoneRoles: ["intimacy_under_pressure", "trust_choice", "joint_showdown", "safety_and_commitment"],
    )

    static let conspiracyArtifactThriller = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000020")!,
        name: "Conspiracy / Artifact Thriller",
        description: "A thrilling rabbit hole of dangerous discoveries, hidden power, treacherous allies, astonishing connections, and revelations that redraw reality. Clues must unleash human danger and consequential action, not paperwork. Wild dust: Make rabbit-hole revelations bizarre, perilous, personally devastating, and reality-shattering, not an audit of documents and procedures.",
        beats: [
            .init(role: "discovery", label: "Discovery", description: "Uncover the object, document, secret, or anomaly that opens the larger mystery."),
            .init(role: "pursuit_begins", label: "Pursuit Begins", description: "Make possession of the discovery dangerous and force the protagonist to act."),
            .init(role: "first_clue", label: "First Clue", description: "Resolve the first layer while pointing toward a larger hidden system."),
            .init(role: "conspiracy_expands", label: "Conspiracy Expands", description: "Reveal that the opposition is broader, older, or more powerful than expected."),
            .init(role: "ally_or_betrayal", label: "Ally / Betrayal", description: "Complicate the pursuit by changing who can be trusted."),
            .init(role: "hidden_history_reveal", label: "Hidden History Reveal", description: "Expose the deeper origin or meaning of the artifact, conspiracy, or secret."),
            .init(role: "apparent_defeat", label: "Apparent Defeat", description: "Put the antagonist in control and remove the protagonist's obvious path forward."),
            .init(role: "final_decoding", label: "Final Decoding", description: "Complete the insight that reveals what must happen next and why."),
            .init(role: "race_to_prevent", label: "Race to Prevent", description: "Escalate toward the irreversible consequence the conspiracy is trying to cause."),
            .init(role: "confrontation_and_truth", label: "Confrontation and Truth", description: "Turn the astonishing but earned truth into irreversible upheaval through a high-stakes confrontation, not revelation alone."),
            .init(role: "aftermath", label: "Aftermath", description: "Resolve the immediate conspiracy and show what the revealed truth changes.")
        ]
    )

    static let progressionFantasy = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000021")!,
        name: "Progression Fantasy / LitRPG",
        description: "An electrifying climb through imaginative power systems, spectacular trials, fierce rivals, and costly breakthroughs. Each tier unlocks different dangers and freedoms, not merely bigger numbers. Wild dust: Each new power should open exhilarating, terrifying, and morally dangerous possibilities nobody could foresee from the previous tier.",
        beats: [
            .init(role: "weak_start", label: "Weak Start", description: "Establish the protagonist's limitations, status, and the hierarchy they cannot yet overcome."),
            .init(role: "system_discovered", label: "System Discovered", description: "Reveal the rules, power system, progression path, or game-like structure that makes advancement possible."),
            .init(role: "first_gain", label: "First Gain", description: "Earn the first meaningful improvement and commit to progression."),
            .init(role: "training_and_trials", label: "Training and Trials", description: "Build competence through increasingly costly practice, quests, tests, or fights."),
            .init(role: "first_boss", label: "First Major Test", description: "Measure progress against an opponent or challenge that exposes remaining weaknesses."),
            .init(role: "new_tier", label: "New Tier", description: "Achieve a breakthrough that changes the protagonist's options and status."),
            .init(role: "stronger_rival", label: "Stronger Rival", description: "Introduce an opponent, faction, or challenge that makes the new level insufficient."),
            .init(role: "major_defeat", label: "Major Defeat", description: "Inflict a loss that exposes a fundamental weakness in the current path."),
            .init(role: "breakthrough", label: "Breakthrough", description: "Earn a new understanding, technique, alliance, or evolution through the consequences of defeat."),
            .init(role: "tier_climax", label: "Tier Climax", description: "Pay off hard-won powers and relationships in a spectacular, inventive trial with lasting consequences beyond a level increase."),
            .init(role: "next_horizon", label: "Next Horizon", description: "Resolve the current progression arc while revealing the larger level still ahead.")
        ]
    )

    static let historicalWarSurvival = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000022")!,
        name: "Historical War / Survival",
        description: "A raw historical survival saga of desperation, fragile loyalty, savage irony, heartbreaking courage, and irreversible choices. Let lived history collide with unpredictable human decisions rather than procedural campaign summaries. Wild dust: Give period-credible people ferocious appetites, savage luck, outrageous survival gambles, and choices that remake their private history.",
        beats: [
            .init(role: "life_before", label: "Life Before", description: "Establish the social world, relationships, duties, and historical conditions before open rupture."),
            .init(role: "war_arrives", label: "War Arrives", description: "Bring the historical conflict directly into the protagonist's life."),
            .init(role: "adaptation", label: "Adaptation", description: "Force new roles, routines, allegiances, or survival strategies."),
            .init(role: "first_loss", label: "First Loss", description: "Make the cost of the conflict personal and irreversible."),
            .init(role: "deepening_conflict", label: "Deepening Conflict", description: "Escalate scarcity, danger, displacement, duty, or divided loyalties."),
            .init(role: "impossible_choice", label: "Impossible Choice", description: "Force a decision in which every available option carries serious moral or personal cost."),
            .init(role: "major_loss_or_betrayal", label: "Major Loss / Betrayal", description: "Destroy a major source of safety, trust, or hope."),
            .init(role: "final_endurance", label: "Final Endurance", description: "Commit to the final course of action under the harshest conditions."),
            .init(role: "decisive_event", label: "Decisive Event", description: "Deliver a historically grounded, extraordinary decisive event whose survival, betrayal, or loss changes everything."),
            .init(role: "aftermath_and_memory", label: "Aftermath and Memory", description: "Show survival, grief, change, and what the historical experience leaves behind.")
        ]
    )

    static let comingOfAge = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000023")!,
        name: "Coming-of-Age / Bildungsroman",
        description: "An unruly journey of intoxicating discovery, humiliation, dangerous belonging, fierce attachments, and irreversible self-definition. Growing up may be ecstatic, ugly, strange, or morally compromised rather than wholesome. Wild dust: Build identity through reckless belonging, astonishing mistakes, sudden ecstasy, humiliating reversals, and irreversible personal consequences.",
        beats: [
            .init(role: "sheltered_identity", label: "Sheltered Identity", description: "Establish the protagonist's inherited identity, assumptions, and limited understanding of the world."),
            .init(role: "first_disruption", label: "First Disruption", description: "Introduce an experience that makes the old identity insufficient."),
            .init(role: "experimentation", label: "Experimentation", description: "Let the protagonist test new roles, freedoms, relationships, or beliefs."),
            .init(role: "belonging_and_conflict", label: "Belonging and Conflict", description: "Offer meaningful belonging while exposing the compromises it demands."),
            .init(role: "first_consequence", label: "First Consequence", description: "Make a choice produce an irreversible emotional, social, or practical cost."),
            .init(role: "disillusionment", label: "Disillusionment", description: "Break an important idealization of a person, institution, relationship, or self-image."),
            .init(role: "self_recognition", label: "Self-Recognition", description: "Bring the protagonist to a clearer understanding of who they are and what they value."),
            .init(role: "adult_choice", label: "Adult Choice", description: "Make a consequential decision based on the emerging self rather than inherited expectations."),
            .init(role: "leaving_or_returning", label: "Leaving / Returning", description: "Show the immediate consequence of the adult choice in relation to the old world."),
            .init(role: "integrated_identity", label: "Integrated Identity", description: "Reveal the emerging self through a startling, costly choice, whether admirable, damaged, or unsettling.")
        ]
    )

    static let revenge = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000024")!,
        name: "Revenge",
        description: "A savage vengeance tale of obsession, inventive retaliation, treacherous alliances, escalating counterstrikes, and a victory that may taste monstrous. Revenge must change its pursuer and the world they injure. Wild dust: Let the avenger's most ingenious move create a stranger monster, temptation, or betrayal, with consequences beyond settling accounts.",
        beats: [
            .init(role: "injury", label: "Injury", description: "Inflict the wrong, loss, humiliation, or betrayal that creates the desire for revenge."),
            .init(role: "vow", label: "Vow", description: "Turn pain into a concrete commitment to retaliate."),
            .init(role: "preparation", label: "Preparation", description: "Acquire knowledge, access, allies, skills, or leverage needed to act."),
            .init(role: "first_retribution", label: "First Retribution", description: "Deliver an early success that proves revenge is possible and raises the stakes."),
            .init(role: "cost_revealed", label: "Cost Revealed", description: "Show collateral damage or personal corruption caused by the pursuit."),
            .init(role: "counterstrike", label: "Counterstrike", description: "Let the target or system retaliate effectively and put the avenger in danger."),
            .init(role: "moral_crossroads", label: "Moral Crossroads", description: "Force recognition of what revenge is demanding and whether the original goal still justifies it."),
            .init(role: "final_hunt", label: "Final Hunt", description: "Commit to the last pursuit with no illusion about its cost."),
            .init(role: "reckoning", label: "Reckoning", description: "Force a fierce, unforgettable final confrontation; mercy, ruin, violence, or reversal must carry irrevocable costs."),
            .init(role: "consequence", label: "Consequence", description: "Resolve what revenge achieved, destroyed, or failed to repair.")
        ]
    )

    static let heist = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000025")!,
        name: "Heist / Caper",
        description: "An audacious caper of impossible ambition, eccentric specialists, clashing loyalties, outrageous complications, clever improvisation, and double-crosses that change the job itself. The story must thrill, not read like a logistics plan. Wild dust: Unleash eccentric accomplices, outrageous gambles, seductive double-crosses, improvisational catastrophes, and a twist that transforms the score.",
        beats: [
            .init(role: "target", label: "The Target", description: "Establish the prize, obstacle, and why taking it matters."),
            .init(role: "motive", label: "The Motive", description: "Create the pressure or opportunity that makes the heist worth attempting."),
            .init(role: "crew_assembled", label: "Crew Assembled", description: "Recruit the specialized people and define the tensions inside the team."),
            .init(role: "plan_and_prep", label: "Plan and Prep", description: "Build the operation, gather tools and intelligence, and expose likely failure points."),
            .init(role: "first_complication", label: "First Complication", description: "Introduce a change that invalidates part of the plan before or during execution."),
            .init(role: "execution_begins", label: "Execution Begins", description: "Cross the point of no return and put the plan into motion."),
            .init(role: "plan_breaks", label: "The Plan Breaks", description: "Destroy the expected path to success and force live improvisation."),
            .init(role: "betrayal_or_twist", label: "Betrayal / Twist", description: "Reveal hidden motives, double-crosses, or a truth about the target that changes the job."),
            .init(role: "improvisation", label: "Improvisation", description: "Use the crew's earned skills and relationships to create a new route through the failure."),
            .init(role: "escape_or_capture", label: "Escape / Capture", description: "Pay off the heist through a daring, earned final gambit that transforms who gets the prize and whom the crew can trust."),
            .init(role: "division_and_aftermath", label: "Division and Aftermath", description: "Settle the prize, loyalties, consequences, and what remains of the crew.")
        ]
    )

    static let redemption = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000026")!,
        name: "Redemption / Rebirth",
        description: "A dangerous, hard-fought rebirth where a compromised person faces temptation, catastrophic relapse, and the ultimate cost of acting against their old self. Redemption must be proven through stunning action, not declarations. Wild dust: Let temptation be feral and transformation costly, startling, and spectacular; a neat confession is never the whole change.",
        beats: [
            .init(role: "broken_state", label: "Broken State", description: "Establish the protagonist's damaged pattern, moral failure, or self-defeating way of living."),
            .init(role: "chance_to_change", label: "Chance to Change", description: "Introduce the person, event, responsibility, or consequence that makes another path possible."),
            .init(role: "refusal_or_old_pattern", label: "Refusal / Old Pattern", description: "Show the protagonist retreating into the familiar behavior that created the problem."),
            .init(role: "first_good_choice", label: "First Good Choice", description: "Make a meaningful but incomplete choice toward change."),
            .init(role: "progress", label: "Progress", description: "Build evidence of change through repeated costly choices rather than declarations."),
            .init(role: "relapse", label: "Relapse", description: "Return the protagonist to the old pattern at serious cost."),
            .init(role: "truth_faced", label: "Truth Faced", description: "Force full recognition of the harm, lie, or fear beneath the old identity."),
            .init(role: "sacrifice", label: "Sacrifice", description: "Give up something genuinely valued in order to act according to the new truth."),
            .init(role: "redemptive_act", label: "Redemptive Act", description: "Demand an extraordinary, costly deed that proves genuine change under maximum temptation; confession alone is insufficient."),
            .init(role: "changed_life", label: "Changed Life", description: "Resolve with the consequences of the redemptive choice and a demonstrably different way of living.")
        ]
    )

    static let familySaga = StoryArcTemplate(
        id: UUID(uuidString: "A0000001-0000-0000-0000-000000000027")!,
        name: "Family Saga / Generational",
        description: "An unruly generational epic of consuming love, inherited shame, fierce ambition, rivalries, secrets, and choices that echo catastrophically through time. Legacy may be triumph, curse, or a startling mixture. Wild dust: Encourage extravagant passions, absurd feuds, inherited appetites, betrayals across eras, and revelations that recast the family myth.",
        beats: [
            .init(role: "founding_choice", label: "Founding Choice", description: "Establish the consequential decision, relationship, wound, or ambition that shapes the family system."),
            .init(role: "first_inheritance", label: "First Inheritance", description: "Show how the founding generation's choices become conditions imposed on the next."),
            .init(role: "family_expands", label: "Family Expands", description: "Develop alliances, marriages, rivalries, resources, and competing visions across the family."),
            .init(role: "buried_conflict", label: "Inherited Pressure", description: "Deepen a resentment, inherited pressure, unresolved wrong, or recurring choice carried across time; a buried secret is optional."),
            .init(role: "generational_turn", label: "Generational Turn", description: "Shift power or perspective to a new generation that interprets the inheritance differently."),
            .init(role: "fracture", label: "Fracture", description: "Break the family system through a death, betrayal, succession fight, revelation, or separation."),
            .init(role: "inherited_truth_revealed", label: "Inheritance Reframed", description: "Reveal or reinterpret the inherited pattern through decisions, memory, or discovery; no hidden document is required."),
            .init(role: "reckoning_across_generations", label: "Reckoning Across Generations", description: "Force living generations to confront the inherited pattern and one another."),
            .init(role: "reconciliation_or_repeat", label: "Reconciliation / Repeat", description: "Show whether the family transforms the pattern or consciously repeats it."),
            .init(role: "legacy", label: "Legacy", description: "Show an unforgettable inheritance or rupture that transforms how the reader understands every generation's choices.")
        ]
    )

    static let allTemplates: [StoryArcTemplate] = [
        .threeAct, .herosJourney, .mystery, .saveTheCat,
        .storyCircle, .freytagsPyramid, .kishotenketsu, .romanceHEA,
        .psychologicalThriller, .romantasy, .suspenseCountdown, .scienceFictionSurvival,
        .dystopianRebellion, .darkRomance, .epicFantasyQuest, .sevenPoint,
        .horrorDread, .sportsRomance, .romanticSuspense, .conspiracyArtifactThriller,
        .progressionFantasy, .historicalWarSurvival, .comingOfAge, .revenge,
        .heist, .redemption, .familySaga
    ]
}

enum StoryArcRelationshipFocus: String, Codable, Hashable {
    case none
    case supporting
    case primary
}

/// A single beat definition inside a `StoryArcTemplate`.
struct StoryArcBeatTemplate: Identifiable, Hashable {
    let role: String
    let label: String
    let description: String
    var id: String { role }
}
