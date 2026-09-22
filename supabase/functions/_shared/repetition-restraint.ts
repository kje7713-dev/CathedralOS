// supabase/functions/_shared/repetition-restraint.ts
//
// Tiny pure helper for "Recent Repetition Restraint" — derives a compact
// volatile prompt block from a small window of recent canonical section
// prose so the generator knows what imagery and surface phrasing is already
// saturated, without weakening continuity.
//
// Design constraints (per spec):
//   - Pure: no I/O, no random, no DB calls. Stable for the same inputs.
//   - Bounded lookback: caller passes the recent `raw_text` window
//     (already ordered canonically by outline position). Lookback size is
//     the caller's responsibility; helper just reads up to RECENT_REPETITION_LOOKBACK.
//   - One canonical output type, populated in place. Empty fields are
//     omitted by the caller at render time.
//
// Spec rules implemented:
//   - Section Contract override: any motif explicitly named in the current
//     Section Contract becomes REQUIRED and is never added to avoidMotifs.
//   - Tombstone/deleted-output safety: caller passes the window. The helper
//     does not query storage. (The generate-story caller INNER-joins to
//     `generation_outputs!inner(id)` so orphan embeddings are excluded.)
//   - Narrative ordering: caller provides the window in outline order; the
//     helper does not reorder by timestamps.
//   - `raw_text` is never injected into the prompt; only counts/labels
//     derived from it are.
//   - Motif saturation rule (initial): a selected motif becomes soft-avoid
//     when it (a) appeared in the immediately previous section, OR
//     (b) appeared in >= 2 sections inside the recent lookback.
//   - Cap guidance lists to keep volatile prefix small.

export interface SelectedMotifLike {
  label?: string;
  meaning?: string;
  category?: string;
  examples?: string[];
  notes?: string;
}

export interface CurrentSectionContractLike {
  title?: string;
  summary?: string;
  entryState?: string;
  dramaticEvent?: string;
  resultingChange?: string;
  terminalState?: string;
  terminalBeat?: string;
}

export interface RecentRepetitionGuidance {
  /** Motifs the current Section Contract explicitly requires (override). */
  requiredMotifs: string[];
  /** Selected motifs recently saturated — avoid unless causally required. */
  avoidMotifs: string[];
  /** Repeated sentence openings (first ~4 normalized words). */
  avoidSentenceOpenings: string[];
  /** Repeated short phrases / reaction constructions. */
  avoidPhrases: string[];
  /** Optional paragraph rhythm guidance (only when dominant). */
  rhythmGuidance?: string;
}

/** Cap on the recent canonical sections used for motif + prose analysis. */
export const RECENT_REPETITION_LOOKBACK = 5 as const;

const MAX_AVOID_MOTIFS = 5;
const MAX_AVOID_OPENINGS = 3;
const MAX_AVOID_PHRASES = 3;

/**
 * Single-section threshold above which the paragraph-rhythm guidance is
 * emitted. We only want to flag a dominant rhythm, not every minor variation.
 * 60% is the chosen threshold — chosen so a single outlier does not fire
 * guidance for an otherwise well-paced window.
 */
const SINGLE_SENTENCE_PARAGRAPH_RATIO = 0.6;

const STOPWORDS = new Set<string>([
  "a",
  "an",
  "and",
  "are",
  "as",
  "at",
  "be",
  "been",
  "being",
  "but",
  "by",
  "could",
  "did",
  "do",
  "does",
  "doing",
  "done",
  "for",
  "from",
  "had",
  "has",
  "have",
  "having",
  "he",
  "her",
  "him",
  "his",
  "i",
  "if",
  "in",
  "into",
  "is",
  "it",
  "its",
  "may",
  "might",
  "must",
  "my",
  "no",
  "nor",
  "not",
  "of",
  "on",
  "or",
  "our",
  "out",
  "over",
  "own",
  "she",
  "should",
  "so",
  "some",
  "such",
  "than",
  "that",
  "the",
  "their",
  "them",
  "then",
  "there",
  "these",
  "they",
  "this",
  "those",
  "through",
  "to",
  "too",
  "under",
  "until",
  "up",
  "very",
  "was",
  "we",
  "were",
  "what",
  "when",
  "where",
  "which",
  "while",
  "who",
  "whom",
  "why",
  "will",
  "with",
  "would",
  "you",
  "your",
  "yours",
  "yet",
  "looked",
  "felt",
  "seemed",
  "became",
  "remained",
]);

export interface AnalyzeRecentRepetitionInput {
  /** Recent canonical section prose, in outline order. May be empty. */
  recentRawText: string[];
  /** Selected motifs from the canonical prompt-pack payload. */
  selectedMotifs: SelectedMotifLike[];
  /** Current authoritative Section Contract. May be partial/null. */
  currentContract: CurrentSectionContractLike | null | undefined;
}

export function normalizeWhitespace(input: string): string {
  return String(input ?? "")
    .replace(/[\u2010-\u2015]/g, "-")
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[ \t]+/g, " ")
    .replace(/[ \t]*\n[ \t]*/g, "\n")
    .trim();
}

export function normalizedLower(input: string): string {
  return normalizeWhitespace(input).toLowerCase();
}

export function splitSentences(prose: string): string[] {
  const cleaned = normalizeWhitespace(prose);
  if (!cleaned) return [];
  return cleaned
    .replace(/\n+/g, " ")
    .split(SPLIT_SENTENCE_REGEX)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

const SPLIT_SENTENCE_REGEX = /(?<=[.?!…])\s+|\n/;

export function paragraphsOf(prose: string): string[] {
  const cleaned = normalizeWhitespace(prose);
  if (!cleaned) return [];
  return cleaned
    .split(/\n\s*\n+/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
}

export function tokenize(phrase: string): string[] {
  return normalizedLower(phrase)
    .split(/[^a-z0-9\']+/)
    .filter((t) => t.length > 0);
}

export function deriveMotifSearchTerms(motif: SelectedMotifLike): string[] {
  const terms: string[] = [];
  if (typeof motif.label === "string" && motif.label.trim().length > 0) {
    terms.push(motif.label.trim());
  }
  if (Array.isArray(motif.examples)) {
    for (const ex of motif.examples) {
      if (typeof ex === "string" && ex.trim().length > 0) {
        terms.push(ex.trim());
      }
    }
  }
  const seen = new Set<string>();
  const out: string[] = [];
  for (const t of terms) {
    const k = normalizedLower(t);
    if (k && !seen.has(k)) {
      seen.add(k);
      out.push(k);
    }
  }
  return out;
}

export function sectionMatchesMotif(
  haystack: string,
  term: string,
): boolean {
  const haystackTokens = tokenize(haystack);
  const termTokens = tokenize(term);
  if (termTokens.length === 0 || termTokens.length > haystackTokens.length) {
    return false;
  }
  for (let i = 0; i <= haystackTokens.length - termTokens.length; i++) {
    if (
      termTokens.every((token, offset) => haystackTokens[i + offset] === token)
    ) {
      return true;
    }
  }
  return false;
}

export function sectionsMentioningMotif(
  lowerSections: string[],
  motif: SelectedMotifLike,
): { sectionIndices: number[]; matched: boolean } {
  const terms = deriveMotifSearchTerms(motif);
  if (terms.length === 0) return { sectionIndices: [], matched: false };
  const indices: number[] = [];
  for (let i = 0; i < lowerSections.length; i++) {
    for (const t of terms) {
      if (sectionMatchesMotif(lowerSections[i], t)) {
        indices.push(i);
        break;
      }
    }
  }
  return { sectionIndices: indices, matched: indices.length > 0 };
}

export function deriveRequiredMotifs(
  selectedMotifs: SelectedMotifLike[],
  contract: CurrentSectionContractLike | null | undefined,
): string[] {
  if (!contract) return [];
  const haystack = normalizedLower(
    [
      contract.title ?? "",
      contract.summary ?? "",
      contract.entryState ?? "",
      contract.dramaticEvent ?? "",
      contract.resultingChange ?? "",
      contract.terminalState ?? "",
      contract.terminalBeat ?? "",
    ].join("\n"),
  );
  if (!haystack) return [];
  const out: string[] = [];
  for (const m of selectedMotifs) {
    if (typeof m.label !== "string" || m.label.trim() === "") continue;
    const terms = deriveMotifSearchTerms(m);
    if (terms.length === 0) continue;
    if (terms.some((t) => sectionMatchesMotif(haystack, t))) {
      out.push(m.label.trim());
    }
  }
  return out;
}

export function deriveAvoidMotifs(
  selectedMotifs: SelectedMotifLike[],
  lowerSections: string[],
  requiredSet: Set<string>,
): string[] {
  if (lowerSections.length === 0 || selectedMotifs.length === 0) return [];
  const lastIdx = lowerSections.length - 1;
  const scored: Array<{ label: string; useCount: number; recent: boolean }> =
    [];
  for (const m of selectedMotifs) {
    if (typeof m.label !== "string" || m.label.trim() === "") continue;
    if (requiredSet.has(m.label.trim().toLowerCase())) continue;
    const { sectionIndices } = sectionsMentioningMotif(lowerSections, m);
    if (sectionIndices.length === 0) continue;
    const useCount = sectionIndices.length;
    const recent = sectionIndices[sectionIndices.length - 1] === lastIdx;
    if (recent || useCount >= 2) {
      scored.push({ label: m.label.trim(), useCount, recent });
    }
  }
  scored.sort((a, b) => {
    if (a.recent !== b.recent) return a.recent ? -1 : 1;
    return b.useCount - a.useCount;
  });
  return scored.slice(0, MAX_AVOID_MOTIFS).map((s) => s.label);
}

export function deriveRepeatedOpenings(
  lowerSections: string[],
): string[] {
  const counts = new Map<string, number>();
  for (const sec of lowerSections) {
    const seenInThisSection = new Set<string>();
    for (const sentence of splitSentences(sec)) {
      const tokens = tokenize(sentence).slice(0, 4);
      if (tokens.length < 2) continue;
      if (tokens.every((t) => STOPWORDS.has(t))) continue;
      const key = tokens.join(" ");
      if (seenInThisSection.has(key)) continue;
      seenInThisSection.add(key);
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
  }
  const entries = [...counts.entries()]
    .filter(([, n]) => n >= 2)
    .sort((a, b) => b[1] - a[1]);
  return entries.slice(0, MAX_AVOID_OPENINGS).map(([k]) => k);
}

export function deriveRepeatedPhrases(
  lowerSections: string[],
): string[] {
  if (lowerSections.length < 2) return [];
  const phraseCounts = new Map<string, Set<number>>();
  lowerSections.forEach((sec, idx) => {
    const seenInSection = new Set<string>();
    const sentences = splitSentences(sec);
    for (const sentence of sentences) {
      const tokens = tokenize(sentence);
      for (let len = 3; len <= Math.min(7, tokens.length); len++) {
        for (let start = 0; start + len <= tokens.length; start++) {
          const slice = tokens.slice(start, start + len);
          if (slice.every((t) => STOPWORDS.has(t))) continue;
          if (
            STOPWORDS.has(slice[0]) &&
            STOPWORDS.has(slice[slice.length - 1])
          ) continue;
          const key = slice.join(" ");
          if (seenInSection.has(key)) continue;
          seenInSection.add(key);
          let bucket = phraseCounts.get(key);
          if (!bucket) {
            bucket = new Set();
            phraseCounts.set(key, bucket);
          }
          bucket.add(idx);
        }
      }
    }
  });
  const candidates = [...phraseCounts.entries()]
    .filter(([, indices]) => indices.size >= 2)
    .map(([phrase, indices]) => ({ phrase, sectionCount: indices.size }))
    .sort((a, b) => {
      if (b.sectionCount !== a.sectionCount) {
        return b.sectionCount - a.sectionCount;
      }
      return b.phrase.length - a.phrase.length;
    });
  return candidates.slice(0, MAX_AVOID_PHRASES).map((c) => c.phrase);
}

export function deriveRhythmGuidance(
  lowerSections: string[],
): string | undefined {
  let totalParagraphs = 0;
  let singleSentenceParagraphs = 0;
  for (const sec of lowerSections) {
    for (const p of paragraphsOf(sec)) {
      totalParagraphs += 1;
      const sentenceCount = splitSentences(p).length;
      if (sentenceCount <= 1) singleSentenceParagraphs += 1;
    }
  }
  if (totalParagraphs === 0) return undefined;
  const ratio = singleSentenceParagraphs / totalParagraphs;
  if (ratio < SINGLE_SENTENCE_PARAGRAPH_RATIO) return undefined;
  return "Recent sections heavily favor isolated one-sentence paragraphs. Use fuller paragraph development where natural; reserve isolated short paragraphs for actual emphasis.";
}

export function analyzeRecentRepetition(
  input: AnalyzeRecentRepetitionInput,
): RecentRepetitionGuidance {
  const recent = Array.isArray(input.recentRawText)
    ? input.recentRawText
      .filter((s): s is string => typeof s === "string")
      .map((s) => String(s))
      .slice(-RECENT_REPETITION_LOOKBACK)
    : [];
  const lowerSections = recent.map((s) => normalizedLower(s));
  const selectedMotifs = Array.isArray(input.selectedMotifs)
    ? input.selectedMotifs
    : [];
  const contract = input.currentContract ?? null;

  const requiredMotifs = deriveRequiredMotifs(selectedMotifs, contract);
  const requiredSet = new Set(requiredMotifs.map((s) => s.toLowerCase()));

  return {
    requiredMotifs,
    avoidMotifs: deriveAvoidMotifs(selectedMotifs, lowerSections, requiredSet),
    avoidSentenceOpenings: deriveRepeatedOpenings(lowerSections),
    avoidPhrases: deriveRepeatedPhrases(lowerSections),
    rhythmGuidance: deriveRhythmGuidance(lowerSections),
  };
}

function capitalizeFirst(s: string): string {
  if (!s) return s;
  return s[0].toUpperCase() + s.slice(1);
}

export function renderRecentRepetitionBlock(
  g: RecentRepetitionGuidance,
): string {
  const sections: string[] = [];
  if (g.requiredMotifs.length > 0) {
    sections.push(
      "Required recurring material (current Section Contract):",
      ...g.requiredMotifs.map((m) => `- ${m}`),
      "",
    );
  }
  if (g.avoidMotifs.length > 0) {
    sections.push(
      "Recently saturated motifs — avoid unless required by causality or continuity:",
      ...g.avoidMotifs.map((m) => `- ${m}`),
      "",
    );
  }
  if (g.avoidSentenceOpenings.length > 0 || g.avoidPhrases.length > 0) {
    const items: string[] = [];
    for (const o of g.avoidSentenceOpenings) {
      items.push(`"${capitalizeFirst(o)}…"`);
    }
    for (const p of g.avoidPhrases) items.push(`"${p}"`);
    if (items.length > 0) {
      sections.push(
        "Recent prose patterns to avoid repeating:",
        ...items,
        "",
      );
    }
  }
  if (g.rhythmGuidance) {
    sections.push("Rhythm:", g.rhythmGuidance, "");
  }
  if (sections.length === 0) return "";
  sections.push(
    "These are restraint signals, not new story requirements. Do not alter the Section Contract, invent different events, omit necessary continuity, or distort character voice merely to avoid repetition. The Section Contract remains authoritative.",
  );
  return ["## Recent Repetition Restraint", "", ...sections].join("\n");
}

export const _internal = {
  MAX_AVOID_MOTIFS,
  MAX_AVOID_OPENINGS,
  MAX_AVOID_PHRASES,
  SINGLE_SENTENCE_PARAGRAPH_RATIO,
  STOPWORDS,
  SPLIT_SENTENCE_REGEX,
  capitalizeFirst,
};
