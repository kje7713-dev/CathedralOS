-- Add additional story arc structures to the versioned template catalog.
-- IDs mirror StoryArcTemplate.swift so locally-created arcs remain FK-valid.

insert into public.story_arc_templates (id, name, description, beats) values
  (
    'a0000001-0000-0000-0000-000000000004',
    'Save the Cat!',
    'A practical fifteen-beat structure for commercial, character-driven stories with a clear emotional arc.',
    $$[
      {"role":"opening_image","label":"Opening Image","description":"Show the protagonist and world before the story changes."},
      {"role":"theme_stated","label":"Theme Stated","description":"Hint at the lesson or central question the protagonist must face."},
      {"role":"setup","label":"Setup","description":"Establish the cast, want, flaw, and stakes before the disruption."},
      {"role":"catalyst","label":"Catalyst","description":"An event makes the old status quo impossible to maintain."},
      {"role":"debate","label":"Debate","description":"The protagonist weighs the risks of responding to the new problem."},
      {"role":"break_into_two","label":"Break into Two","description":"The protagonist chooses an approach and enters a changed situation."},
      {"role":"b_story","label":"B Story","description":"Introduce the relationship or secondary thread that carries the theme."},
      {"role":"fun_and_games","label":"Fun and Games","description":"Deliver the central promise of the premise as complications grow."},
      {"role":"midpoint","label":"Midpoint","description":"A false victory or defeat raises the stakes and changes the game."},
      {"role":"bad_guys_close_in","label":"Bad Guys Close In","description":"External pressure and internal flaws tighten around the protagonist."},
      {"role":"all_is_lost","label":"All Is Lost","description":"The protagonist reaches a visible low point and loses a source of hope."},
      {"role":"dark_night_of_the_soul","label":"Dark Night of the Soul","description":"The protagonist confronts what must change to move forward."},
      {"role":"break_into_three","label":"Break into Three","description":"A realization combines the A and B stories into a new plan."},
      {"role":"finale","label":"Finale","description":"The protagonist applies the lesson and resolves the central conflict."},
      {"role":"final_image","label":"Final Image","description":"Echo the opening image to show how the world or protagonist changed."}
    ]$$::jsonb
  ),
  (
    'a0000001-0000-0000-0000-000000000005',
    'Story Circle',
    'Dan Harmons eight-step cycle: a character leaves comfort, adapts through conflict, and returns changed.',
    $$[
      {"role":"you","label":"You","description":"Show the character in a zone of comfort and establish what they want."},
      {"role":"need","label":"Need","description":"The character enters an unfamiliar situation to pursue a need."},
      {"role":"go","label":"Go","description":"The character adapts while facing escalating obstacles."},
      {"role":"search","label":"Search","description":"The character experiments, learns, and pays a price for progress."},
      {"role":"find","label":"Find","description":"The character gets what they sought, often with an unexpected cost."},
      {"role":"take","label":"Take","description":"The character sacrifices or suffers to bring the prize home."},
      {"role":"return","label":"Return","description":"The character returns to a familiar world carrying the consequences."},
      {"role":"change","label":"Change","description":"The character demonstrates what they learned and how they are different."}
    ]$$::jsonb
  ),
  (
    'a0000001-0000-0000-0000-000000000006',
    'Freytag''s Pyramid',
    'A five-part dramatic arc built around rising action, a climax, and falling consequences.',
    $$[
      {"role":"exposition","label":"Exposition","description":"Introduce the world, characters, conflict, and conditions of the story."},
      {"role":"rising_action","label":"Rising Action","description":"Complications build as choices intensify the central conflict."},
      {"role":"climax","label":"Climax","description":"The decisive turning point where the conflict reaches maximum intensity."},
      {"role":"falling_action","label":"Falling Action","description":"Consequences unfold and remaining conflicts move toward resolution."},
      {"role":"denouement","label":"Denouement","description":"The final situation settles and the meaning of the events becomes clear."}
    ]$$::jsonb
  ),
  (
    'a0000001-0000-0000-0000-000000000007',
    'Kishōtenketsu',
    'A four-part structure that develops an idea, introduces a turn, and creates meaning through juxtaposition rather than a central conflict.',
    $$[
      {"role":"ki","label":"Ki — Introduction","description":"Establish the setting, characters, and initial idea."},
      {"role":"sho","label":"Shō — Development","description":"Develop the situation and deepen the world without a major reversal."},
      {"role":"ten","label":"Ten — Twist","description":"Introduce a surprising new element or perspective that reframes what came before."},
      {"role":"ketsu","label":"Ketsu — Conclusion","description":"Connect the elements and show the new understanding or harmony."}
    ]$$::jsonb
  )
on conflict (id) do update set
  name        = excluded.name,
  description = excluded.description,
  beats       = excluded.beats,
  updated_at  = now();
