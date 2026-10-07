// Shared scene-memory contract used by generation and embedding paths.
// Keeping the schema in one module prevents the producer and consumer from
// drifting apart.

export const SCENE_MEMORY_GENERATION_INSTRUCTIONS =
  `Scene memory is a factual record of what happened in the returned scene.
Derive every memory field only from the prose in the \`scene\` field that you write in this response. Do not copy or promote facts from the Section Contract, recipe, Project State, story arc, outline summary, or planned events unless the returned prose actually establishes them. Do not record an intended action as completed unless it occurs on the page.
The extracted_summary must be a concise factual distillation of this scene. character_deltas and plot_thread_deltas describe changes caused or established by this scene. continuity_facts are semantic operations: establish, preserve, or supersede durable facts. Treat stable character identity attributes established by prose—especially names, pronouns, identity terms, kinship, species, and fixed physical traits—as durable continuity_facts rather than ordinary character_deltas. Reserve the character identity namespace exclusively for those stable identity attributes. The canonical form is a category-only reference such as \`character:sava:identity:pronouns\` with fact \`Sava uses he/him pronouns.\` The attribute portion identifies the category, not its value; never encode the value in the reference. GOOD: reference \`character:sava:identity:pronouns\`, fact \`Sava uses he/him pronouns.\` BAD: \`character:sava:identity:pronouns-he/him\`. When a named character is referred to with a consistent pronoun set in the scene, record that pronoun set as a continuity_fact. Use stable semantic references in the form character:<normalized-name>:identity:<attribute> for names, pronouns, gender or identity terms, kinship, and species. Fixed physical traits use the canonical form character:<normalized-name>:identity:physical:<attribute>, where physical is the stable identity category and the final segment identifies the physical attribute, not its value. Put values in fact, not in the reference, and do not encode descriptive prose directly into the reference. GOOD: reference character:anika-reedrunner:identity:physical:hair with fact Anika has dark hair bound with blue cloth; reference character:sava:identity:physical:sign-mark with fact Sava's sign-mark is a thumbprint-like hollow; reference character:senior-clerk:identity:physical:beard with fact The senior clerk has a gray beard tied under his chin. BAD: character:anika:identity:dark-hair-with-blue-cloth-binding and character:senior-clerk:identity:male-presenting-older-with-gray-beard. That reference identifies the attribute-level fact, not the character: never use a character name alone (for example, "Dr. Sela Aro") as an identity-fact reference. NEVER use \`:identity:\` for mutable state such as location, possessions, inventory, tools or equipment, clothing, temporary injuries, goals, knowledge, emotions, current status, temporary resources, or current occupation or assignment. Those may still be continuity facts when relevant, but use ordinary semantic references instead. When the current prose refers to a character whose prior context already contains a stable identity fact, preserve that fact unless the current prose explicitly establishes an intentional change; an incidental conflicting pronoun or wording alone is not a supersession. open_loops are semantic operations with status open or resolved. Use references only to identify the prior semantic entity; never emit database IDs. scene_ending_state describes the characters and immediate pressure at the end of this scene. If the prose does not establish something, leave that array empty or that field null. Never invent canon to satisfy the schema.`;

export const SCENE_MEMORY_RESPONSE_FORMAT = {
  type: "json_schema",
  json_schema: {
    name: "scene_memory",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      required: [
        "extracted_summary",
        "character_deltas",
        "plot_thread_deltas",
        "continuity_facts",
        "open_loops",
        "scene_ending_state",
      ],
      properties: {
        extracted_summary: { type: "string" },
        character_deltas: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: [
              "character_name",
              "location",
              "knowledge_delta",
              "relationship_delta",
              "injuries",
              "goals",
              "possessions",
              "emotional_stance",
            ],
            properties: {
              character_name: { type: "string" },
              location: { type: ["string", "null"] },
              knowledge_delta: { type: ["string", "null"] },
              relationship_delta: { type: ["string", "null"] },
              injuries: { type: ["string", "null"] },
              goals: { type: ["string", "null"] },
              possessions: { type: ["string", "null"] },
              emotional_stance: { type: ["string", "null"] },
            },
          },
        },
        plot_thread_deltas: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: ["thread_name", "reference", "status", "description"],
            properties: {
              thread_name: { type: "string" },
              reference: { type: "string" },
              status: {
                type: "string",
                enum: ["introduced", "advanced", "resolved"],
              },
              description: { type: "string" },
            },
          },
        },
        continuity_facts: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: [
              "operation",
              "fact",
              "reference",
              "prior_fact_reference",
            ],
            properties: {
              operation: {
                type: "string",
                enum: ["establish", "preserve", "supersede"],
              },
              fact: { type: "string" },
              reference: { type: "string" },
              prior_fact_reference: { type: ["string", "null"] },
            },
          },
        },
        open_loops: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: ["type", "reference", "status", "description"],
            properties: {
              type: {
                type: "string",
                enum: [
                  "promise",
                  "mystery",
                  "question",
                  "threat",
                  "pending_action",
                ],
              },
              reference: { type: "string" },
              status: { type: "string", enum: ["open", "resolved"] },
              description: { type: "string" },
            },
          },
        },
        scene_ending_state: {
          type: "object",
          additionalProperties: false,
          required: ["character_positions", "immediate_pressure"],
          properties: {
            character_positions: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                required: ["character", "location", "immediate_state"],
                properties: {
                  character: { type: "string" },
                  location: { type: "string" },
                  immediate_state: { type: "string" },
                },
              },
            },
            immediate_pressure: { type: "string" },
          },
        },
      },
    },
  },
};

export interface SceneMemory {
  extracted_summary: string;
  character_deltas: Array<
    {
      character_name?: string;
      location?: string;
      knowledge_delta?: string;
      relationship_delta?: string;
      injuries?: string;
      goals?: string;
      possessions?: string;
      emotional_stance?: string;
    }
  >;
  plot_thread_deltas: Array<
    {
      thread_name?: string;
      reference?: string;
      status?: string;
      description?: string;
    }
  >;
  continuity_facts: Array<{
    operation?: "establish" | "preserve" | "supersede";
    fact?: string;
    reference?: string;
    prior_fact_reference?: string | null;
  }>;
  open_loops: Array<
    {
      type?: string;
      reference?: string;
      status?: "open" | "resolved";
      description?: string;
    }
  >;
  scene_ending_state: {
    character_positions?: Array<
      { character?: string; location?: string; immediate_state?: string }
    >;
    immediate_pressure?: string;
  };
}

export function normalizeSceneMemory(input: unknown): SceneMemory {
  const parsed = input && typeof input === "object"
    ? input as Partial<SceneMemory>
    : {};
  return {
    extracted_summary: typeof parsed.extracted_summary === "string"
      ? parsed.extracted_summary
      : "",
    character_deltas: Array.isArray(parsed.character_deltas)
      ? parsed.character_deltas
      : [],
    plot_thread_deltas: Array.isArray(parsed.plot_thread_deltas)
      ? parsed.plot_thread_deltas
      : [],
    continuity_facts: Array.isArray(parsed.continuity_facts)
      ? parsed.continuity_facts.map((fact) =>
        typeof fact === "string"
          ? {
            operation: "establish" as const,
            fact,
            prior_fact_reference: null,
          }
          : fact
      ).filter((fact) => fact && typeof fact === "object")
      : [],
    open_loops: Array.isArray(parsed.open_loops) ? parsed.open_loops : [],
    scene_ending_state: parsed.scene_ending_state &&
        typeof parsed.scene_ending_state === "object"
      ? parsed.scene_ending_state
      : {},
  };
}
