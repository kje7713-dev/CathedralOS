// Shared scene-memory contract used by generation and embedding paths.
// Keeping the schema in one module prevents the producer and consumer from
// drifting apart.

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
            required: ["thread_name", "status", "description"],
            properties: {
              thread_name: { type: "string" },
              status: {
                type: "string",
                enum: ["introduced", "advanced", "resolved"],
              },
              description: { type: "string" },
            },
          },
        },
        continuity_facts: { type: "array", items: { type: "string" } },
        open_loops: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: ["type", "description"],
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
    { thread_name?: string; status?: string; description?: string }
  >;
  continuity_facts: string[];
  open_loops: Array<{ type?: string; description?: string }>;
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
      ? parsed.continuity_facts
      : [],
    open_loops: Array.isArray(parsed.open_loops) ? parsed.open_loops : [],
    scene_ending_state: parsed.scene_ending_state &&
        typeof parsed.scene_ending_state === "object"
      ? parsed.scene_ending_state
      : {},
  };
}
