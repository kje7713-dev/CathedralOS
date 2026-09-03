# New Arc: Product Outline

Status: discovery plan — no implementation authorized
Source: `New_arc---ba99491e-ed8e-4f47-887f-523e372bc470.txt`
Source guidance: `product.`

## Interpretation

The source provides one usable direction: this arc should be organized around the
product outcome, not around an assumed technical feature. It does not identify
the product, user, problem, market, workflow, or success criteria. This plan
therefore records the product-discovery structure without inventing those facts.

## Product-first outline

1. **Product thesis**
   - What product or product area is changing?
   - Who is it for?
   - What valuable outcome should become easier, faster, or better?

2. **User problem and evidence**
   - Primary user and job to be done
   - Current failure or friction
   - Evidence that the problem matters
   - Existing workaround and why it is insufficient

3. **Desired product experience**
   - Entry point and user intent
   - Happy path from intent to outcome
   - Required user-visible states and feedback
   - Persistence, recovery, and empty/error states

4. **MVP boundary**
   - Smallest shippable product slice
   - Explicit non-goals
   - Reuse of existing app, backend, billing, sync, and output infrastructure
   - Decisions that must remain reversible

5. **Technical shape after product decisions**
   - Relevant iOS surfaces and service clients
   - Backend or schema changes, only if the product behavior requires them
   - Data ownership, sync, and authorization rules
   - Billing implications, if any

6. **Validation and launch bar**
   - Observable acceptance criteria tied to user outcomes
   - Source-aware tests and behavioral validation
   - Device smoke-test scenarios
   - Rollout, support, and rollback considerations

## Open decisions before implementation

- Product name and one-sentence value proposition
- Primary user/persona and first use case
- Problem statement and evidence
- Desired workflow and MVP outcome
- Whether this is a new journey, an improvement to an existing journey, or a backend capability
- Billing model and whether any existing credits are involved
- Success metrics and launch constraints

## Guardrails

- Do not infer a feature from the single word `product`.
- Do not start implementation until the product thesis, target user, MVP boundary,
and acceptance criteria are filled in.
- Keep subsequent work split into small PRs only after the product outline is
approved and the affected repository surfaces are surveyed.
