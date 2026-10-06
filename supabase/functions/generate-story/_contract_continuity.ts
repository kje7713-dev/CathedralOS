export type SectionContractFields = {
  title: string;
  summary: string;
  entryState?: string | null;
  dramaticEvent?: string | null;
  resultingChange?: string | null;
  terminalState?: string | null;
};

export type CanonicalCharacterState = {
  name: string;
  location?: string;
  injuries?: string;
  possessions?: string;
  status?: string;
  raw: Record<string, unknown>;
};

export type ContractContinuityCandidate = {
  characters: string[];
  canonicalStates: CanonicalCharacterState[];
  reason: string;
};

export type ContractRepairResult = {
  conflict: boolean;
  reason: string;
  contract: SectionContractFields;
};

const CONTRACT_KEYS = [
  "title",
  "summary",
  "entryState",
  "dramaticEvent",
  "resultingChange",
  "terminalState",
] as const;

function normalize(value: unknown): string {
  return String(value ?? "").toLocaleLowerCase().replace(/[^a-z0-9]+/g, " ")
    .trim();
}

export function parseCanonicalCharacterStates(
  projectState: string,
): CanonicalCharacterState[] {
  const states: CanonicalCharacterState[] = [];
  const rows = projectState.matchAll(/- \*\*([^*]+)\*\*:\s*(\{[^\n]+\})/g);
  for (const match of rows) {
    const name = String(match[1] ?? "").trim();
    if (!name) continue;
    try {
      const raw = JSON.parse(String(match[2])) as Record<string, unknown>;
      states.push({
        name,
        location: typeof raw.location === "string" ? raw.location : undefined,
        injuries: typeof raw.injuries === "string" ? raw.injuries : undefined,
        possessions: typeof raw.possessions === "string"
          ? raw.possessions
          : undefined,
        status: typeof raw.status === "string" ? raw.status : undefined,
        raw,
      });
    } catch {
      // Ignore malformed legacy rows; canonical rows are JSON when emitted.
    }
  }
  return states;
}

/**
 * Finds only suspicious backward-looking concrete assertions. This is a
 * candidate gate, not a semantic verdict; the single repair call decides.
 */
export function detectPotentialContractCanonConflict(
  projectState: string,
  contract: SectionContractFields,
): ContractContinuityCandidate | null {
  if (!projectState) return null;
  const states = parseCanonicalCharacterStates(projectState);
  const contractText = normalize(
    CONTRACT_KEYS.map((key) => contract[key]).join(" "),
  );
  const matching = states.filter((state) =>
    contractText.includes(normalize(state.name))
  );
  if (!matching.length) return null;

  const backwardStateAssertion =
    /\b(?:missing|absent|not present|nowhere to be found|disappeared|already dead|was found dead|had died|never (?:arrived|reached|made|completed)|failed to (?:arrive|reach|make|complete)|did not (?:arrive|reach|make|complete))\b/;
  const possessionLoss =
    /\b(?:no longer has|without (?:his|her|their|the)|lost (?:his|her|their|the))\b/;
  const injuryContradiction =
    /\b(?:uninjured|injury healed|wound healed|no longer injured)\b/;

  const suspicious = matching.filter((state) => {
    const hasConcreteCanon = Boolean(
      state.location || state.status || state.possessions || state.injuries,
    );
    return hasConcreteCanon && (
      backwardStateAssertion.test(contractText) ||
      (Boolean(state.possessions) && possessionLoss.test(contractText)) ||
      (Boolean(state.injuries) && injuryContradiction.test(contractText))
    );
  });
  if (!suspicious.length) return null;
  return {
    characters: suspicious.map((state) => state.name),
    canonicalStates: suspicious,
    reason:
      "The current contract contains a suspicious backward-looking concrete-state assertion for a character with established canonical state.",
  };
}

export const CONTRACT_REPAIR_RESPONSE_FORMAT = {
  type: "json_schema",
  json_schema: {
    name: "section_contract_continuity_reconciliation",
    strict: true,
    schema: {
      type: "object",
      properties: {
        conflict: { type: "boolean" },
        reason: { type: "string" },
        contract: {
          type: "object",
          properties: {
            title: { type: "string" },
            summary: { type: "string" },
            entryState: { type: "string" },
            dramaticEvent: { type: "string" },
            resultingChange: { type: "string" },
            terminalState: { type: "string" },
          },
          required: [...CONTRACT_KEYS],
          additionalProperties: false,
        },
      },
      required: ["conflict", "reason", "contract"],
      additionalProperties: false,
    },
  },
} as const;

export function buildContractRepairPrompt(
  projectState: string,
  contract: SectionContractFields,
  invariants: Record<string, unknown>,
  futureOutlineContext: string,
  candidate: ContractContinuityCandidate,
): string {
  return [
    "RECONCILE THE CURRENT SECTION CONTRACT AGAINST ESTABLISHED CANON.",
    "You may change only the six Section Contract fields.",
    "You may NOT change established canonical Project State, container, terminal beat / Story Arc placement, or unrelated future outline sections.",
    "If there is no real contradiction, return conflict=false and return the original contract byte-for-byte in all six fields.",
    "If there is a contradiction, make the smallest contract change necessary to reconcile it while preserving the section's dramatic purpose and downstream trajectory.",
    "The current contract may legitimately describe a new event that changes canon now; do not call that a retcon merely because the canonical state describes the earlier state.",
    `Candidate characters: ${candidate.characters.join(", ")}.`,
    `Candidate reason: ${candidate.reason}`,
    "",
    "CURRENT SECTION CONTRACT:",
    JSON.stringify(contract, null, 2),
    "",
    "CURRENT GENERATION INVARIANTS:",
    JSON.stringify(invariants, null, 2),
    "",
    "ESTABLISHED CANONICAL PROJECT STATE:",
    projectState,
    "",
    "FUTURE OUTLINE OBLIGATIONS:",
    futureOutlineContext || "(none)",
    "",
    "Return only the requested JSON object.",
  ].join("\n");
}

export function parseContractRepairResult(
  content: string,
): ContractRepairResult {
  const parsed = JSON.parse(content) as Record<string, unknown>;
  if (typeof parsed.conflict !== "boolean") {
    throw new Error("invalid contract repair conflict flag");
  }
  if (typeof parsed.reason !== "string") {
    throw new Error("invalid contract repair reason");
  }
  const contract = parsed.contract;
  if (!contract || typeof contract !== "object") {
    throw new Error("invalid contract repair contract");
  }
  const fields = contract as Record<string, unknown>;
  for (const key of CONTRACT_KEYS) {
    if (typeof fields[key] !== "string") {
      throw new Error(`invalid repaired contract field: ${key}`);
    }
  }
  return {
    conflict: parsed.conflict,
    reason: parsed.reason,
    contract: {
      title: fields.title as string,
      summary: fields.summary as string,
      entryState: fields.entryState as string,
      dramaticEvent: fields.dramaticEvent as string,
      resultingChange: fields.resultingChange as string,
      terminalState: fields.terminalState as string,
    },
  };
}

export function contractsEqual(
  left: SectionContractFields,
  right: SectionContractFields,
): boolean {
  return CONTRACT_KEYS.every((key) => left[key] === right[key]);
}
