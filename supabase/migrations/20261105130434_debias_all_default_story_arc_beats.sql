-- Calibrate every built-in story arc: change only descriptions that accidentally
-- require unrelated investigations, procedural machinery, moral lessons, or tidy closure.
-- Preserve beat IDs/roles/order and leave explicitly genre-required operations alone.
-- Match original canonical wording, so customized or already-updated rows are untouched.
-- This updates only the template catalog, never user-authored story_arc customizations.
WITH beat_rewrites (template_id, beat_role, original_text, revised_text) AS (
  VALUES
    ('a0000001-0000-0000-0000-000000000001'::uuid, 'resolution', 'The new normal. Loose threads are tied. The world has changed.', 'Show the changed final situation, what is settled, and what meaningfully remains unresolved.'),
    ('a0000001-0000-0000-0000-000000000004'::uuid, 'theme_stated', 'Hint at the lesson or central question the protagonist must face.', 'Hint at the central question or tension the protagonist must face; no moral lesson is required.'),
    ('a0000001-0000-0000-0000-000000000004'::uuid, 'finale', 'The protagonist applies the lesson and resolves the central conflict.', 'The protagonist acts on changed understanding or commitment, bringing the central conflict to a consequential turning point.'),
    ('a0000001-0000-0000-0000-000000000005'::uuid, 'take', 'The character sacrifices or suffers to bring the prize home.', 'The character pays a consequential price for pursuing or possessing what they found.'),
    ('a0000001-0000-0000-0000-000000000005'::uuid, 'change', 'The character demonstrates what they learned and how they are different.', 'The character shows how the experience has changed their choices, for better or worse.'),
    ('a0000001-0000-0000-0000-000000000006'::uuid, 'denouement', 'The final situation settles and the meaning of the events becomes clear.', 'Show the changed final situation and what is resolved, uncertain, or unsettled.'),
    ('a0000001-0000-0000-0000-000000000007'::uuid, 'ketsu', 'Connect the elements and show the new understanding or harmony.', 'Connect the elements and reveal a new relationship or meaning between them, without requiring harmony.'),
    ('a0000001-0000-0000-0000-000000000010'::uuid, 'quest_and_bond', 'Escalate trials while trust, desire, and mutual dependence deepen.', 'Escalate fantasy-world pressures and consequential choices while trust, desire, and mutual dependence deepen.'),
    ('a0000001-0000-0000-0000-000000000010'::uuid, 'midpoint_revelation', 'Reveal a truth about the world, mission, power, or relationship that changes the trajectory.', 'Reveal a truth about the world, power, danger, or relationship that changes the trajectory.'),
    ('a0000001-0000-0000-0000-000000000010'::uuid, 'final_battle_and_choice', 'Resolve the primary external conflict through a climax inseparable from the central emotional choice.', 'Bring the defining fantasy stakes and romantic choice together in one consequential climax; a literal battle is not required.'),
    ('a0000001-0000-0000-0000-000000000011'::uuid, 'first_pursuit', 'Escalate pursuit, investigation, or evasion while proving the threat is active.', 'Escalate active danger through pursuit, evasion, discovery, or consequential failed attempts, whichever fits the story.'),
    ('a0000001-0000-0000-0000-000000000011'::uuid, 'final_lead', 'Reveal the actionable path that makes one last attempt possible.', 'Reveal an earned opening, hard choice, or opportunity that makes one last attempt possible.'),
    ('a0000001-0000-0000-0000-000000000016'::uuid, 'pinch_point_one', 'Apply direct pressure from the antagonistic force and demonstrate the cost of failure.', 'Apply direct pressure from a person, circumstance, or opposing force and demonstrate the cost of failure.'),
    ('a0000001-0000-0000-0000-000000000016'::uuid, 'resolution', 'Deliver the decisive confrontation and resolve the central story problem.', 'Deliver the decisive act or encounter and establish the central story''s consequential outcome.'),
    ('a0000001-0000-0000-0000-000000000017'::uuid, 'rules_discovered', 'Reveal enough about the threat''s nature or pattern to make resistance possible but costly.', 'Reveal or complicate the threat''s behavior and the cost of confronting it, without requiring a solvable rule.'),
    ('a0000001-0000-0000-0000-000000000019'::uuid, 'midpoint_reveal', 'Reveal a truth that changes both the investigation and the relationship.', 'Reveal a truth that changes both the danger and the relationship.'),
    ('a0000001-0000-0000-0000-000000000027'::uuid, 'buried_conflict', 'Deepen the secret, resentment, debt, or unresolved wrong carried across time.', 'Deepen a resentment, inherited pressure, unresolved wrong, or recurring choice carried across time; a buried secret is optional.'),
    ('a0000001-0000-0000-0000-000000000027'::uuid, 'inherited_truth_revealed', 'Expose the hidden history that explains the repeating conflict.', 'Reveal or reinterpret the inherited pattern through decisions, memory, or discovery; no hidden document is required.')
)
UPDATE public.story_arc_templates AS t
SET beats = (
  SELECT jsonb_agg(
    CASE WHEN r.revised_text IS NOT NULL
      THEN jsonb_set(b.beat, '{description}', to_jsonb(r.revised_text), false)
      ELSE b.beat
    END ORDER BY b.position
  )
  FROM jsonb_array_elements(t.beats) WITH ORDINALITY AS b(beat, position)
  LEFT JOIN beat_rewrites AS r
    ON r.template_id = t.id
   AND r.beat_role = b.beat->>'role'
   AND r.original_text = b.beat->>'description'
)
WHERE jsonb_typeof(t.beats) = 'array'
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(t.beats) AS beat
    JOIN beat_rewrites AS r
      ON r.template_id = t.id
     AND r.beat_role = beat->>'role'
     AND r.original_text = beat->>'description'
  );

UPDATE public.story_arc_templates
SET description = 'A dual-engine fantasy arc in which external fantasy stakes and central romance escalate together and become inseparable at the climax.'
WHERE id = 'a0000001-0000-0000-0000-000000000010'::uuid
  AND description = 'A dual-engine fantasy arc in which the external quest and central romance escalate together and become inseparable at the climax.';

-- Keep displayed beat labels aligned with the same non-prescriptive contracts.
-- Roles and UUIDs are stable so existing arc assignments remain compatible.
WITH label_rewrites (template_id, beat_role, original_label, revised_label) AS (
  VALUES
    ('a0000001-0000-0000-0000-000000000010'::uuid, 'quest_and_bond', 'Quest and Bond', 'Fantasy Pressure and Bond'),
    ('a0000001-0000-0000-0000-000000000010'::uuid, 'final_battle_and_choice', 'Final Battle and Choice', 'Defining Stakes and Choice'),
    ('a0000001-0000-0000-0000-000000000011'::uuid, 'first_pursuit', 'First Pursuit', 'Threat Tightens'),
    ('a0000001-0000-0000-0000-000000000011'::uuid, 'final_lead', 'Final Lead', 'Last Opening'),
    ('a0000001-0000-0000-0000-000000000017'::uuid, 'rules_discovered', 'Rules Discovered', 'Threat Pattern'),
    ('a0000001-0000-0000-0000-000000000027'::uuid, 'buried_conflict', 'Buried Conflict', 'Inherited Pressure'),
    ('a0000001-0000-0000-0000-000000000027'::uuid, 'inherited_truth_revealed', 'Inherited Truth Revealed', 'Inheritance Reframed')
)
UPDATE public.story_arc_templates AS t
SET beats = (
  SELECT jsonb_agg(
    CASE WHEN r.revised_label IS NOT NULL
      THEN jsonb_set(b.beat, '{label}', to_jsonb(r.revised_label), false)
      ELSE b.beat
    END ORDER BY b.position
  )
  FROM jsonb_array_elements(t.beats) WITH ORDINALITY AS b(beat, position)
  LEFT JOIN label_rewrites AS r
    ON r.template_id = t.id
   AND r.beat_role = b.beat->>'role'
   AND r.original_label = b.beat->>'label'
)
WHERE jsonb_typeof(t.beats) = 'array'
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(t.beats) AS beat
    JOIN label_rewrites AS r
      ON r.template_id = t.id
     AND r.beat_role = beat->>'role'
     AND r.original_label = beat->>'label'
  );
