-- A previously installed iOS build can re-upload old template defaults after
-- the creative-progression migration. Reapply only exact, unchanged defaults.
-- Custom author text, renamed beats, deleted beats, and selected arc order
-- are not touched. The sync function now also prevents future reversion.
UPDATE public.story_arc_beats AS b
SET details = current_beat.beat->>'description',
    updated_at = now()
FROM public.story_arcs AS a
JOIN public.story_arc_templates AS t ON t.id = a.template_id
CROSS JOIN LATERAL jsonb_array_elements(t.beats) AS current_beat(beat)
WHERE b.story_arc_id = a.id
  AND b.role = current_beat.beat->>'role'
  AND b.label = current_beat.beat->>'label'
  AND current_beat.beat->>'description' LIKE '% Creative progression: %'
  AND b.details = split_part(current_beat.beat->>'description', ' Creative progression: ', 1);
