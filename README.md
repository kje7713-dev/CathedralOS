# CathedralOS
CathedralOS makes AI think in the context of your life.
Good catch. Here it is, clean and consistent, all in one format, ready to drop directly into your repo as README.md.

⸻

CathedralOS

CathedralOS is a private context layer that helps AI understand what matters to you before it answers.

Instead of re-explaining your life every time you ask for advice, CathedralOS stores your current goals and constraints locally and generates a small, structured context block you can paste into any LLM.

This is not a journaling app.
This is not a productivity dashboard.
This is a context compiler.

⸻

Why This Exists

LLMs are powerful but context-blind.

If you don’t provide:
	•	Your current goals
	•	Your constraints
	•	Your limits
	•	What you’re optimizing for

You get generic advice.

Most people solve this by oversharing or repeatedly typing their backstory.

CathedralOS solves this by compiling a deterministic, reusable context block that keeps your priorities in the room.

⸻

V1 Scope (Non-Negotiable)

CathedralOS v1 does exactly this:
	1.	Store:
	•	Active Goals
	•	Constraints
	2.	Compile:
	•	A short, LLM-friendly context block
	3.	Export:
	•	Copy to clipboard
	•	Share sheet

That’s it.

No:
	•	Journals
	•	Metrics dashboards
	•	Ontology editors
	•	Agent orchestration
	•	Behavioral tracking

V1 is goals + constraints + compiler.

⸻

Core Concepts

Cathedral Profile

A Cathedral is your current operating context.

It includes:
	•	Goals (what you are trying to achieve)
	•	Constraints (what limits you)

Example:
	•	Goal: Reach $5k MRR in 3–6 months
	•	Goal: Improve household organization
	•	Constraint: Time and focus stretched thin

⸻

Compiled Context Block

CathedralOS generates a deterministic context block optimized for LLM reasoning.

Example output:

{
“cathedral_context”: {
“goals”: [
“Reach $5k MRR in 3–6 months”,
“Improve household organization”
],
“constraints”: [
“Time and focus stretched thin”
],
“instruction_bias”: [
“Prefer short actions with fast feedback”,
“Avoid plans requiring long uninterrupted blocks”
]
}
}

This block is:
	•	Small
	•	Structured
	•	Paste-friendly
	•	Hard for the LLM to ignore

⸻

Privacy Model

CathedralOS is local-first.
	•	Raw context stays on device.
	•	Only the compiled block is copied or shared.
	•	No user data is sold.
	•	No analytics that inspect personal context.

Trust is the product.

⸻

Features

Free (MVP)
	•	Single Cathedral profile
	•	Add/edit/delete Goals
	•	Add/edit/delete Constraints
	•	Compile preview
	•	Copy to clipboard
	•	Share sheet export

Pro (Planned)
	•	Multiple Cathedral profiles
	•	Redaction / abstraction rules
	•	Multiple compile modes (Concise / Strategic)
	•	Version history
	•	BYO API key for in-app LLM calls
	•	Custom GPT instruction export format

⸻

Tech Stack (Proposed)
	•	iOS app: SwiftUI
	•	Persistence: SwiftData or Core Data
	•	Secrets storage: Keychain (for future BYO API keys)
	•	CI: GitHub Actions
	•	No backend for MVP

Local-first by design.

⸻

Repository Structure (Target)

CathedralOS/
CathedralOSApp/
App/
Features/
CathedralEditor/
Compiler/
Export/
Settings/
Models/
Services/
Utils/
CathedralOSAppTests/
.github/workflows/
README.md

⸻

MVP Functional Requirements

Data Model

Create:
	•	Goal
	•	id
	•	title
	•	optional timeframe
	•	Constraint
	•	id
	•	description
	•	CathedralProfile
	•	id
	•	name
	•	list of Goals
	•	list of Constraints

⸻

UI

Main Screen:
	•	Goals list
	•	Add
	•	Edit
	•	Delete
	•	Constraints list
	•	Add
	•	Edit
	•	Delete
	•	Compiled Context Preview (read-only)
	•	Copy Button
	•	Copies compiled block to clipboard
	•	Share Button
	•	Opens iOS share sheet

⸻

Compiler Requirements
	•	Deterministic JSON output
	•	Stable key ordering
	•	No randomness
	•	Small output size
	•	Consistent formatting
	•	Pure function (input profile → output string)

⸻

Definition of Done (Any PR)
	•	App builds successfully in CI
	•	No debug-only code left in production
	•	Compiler has unit tests
	•	Output formatting is stable
	•	UI compiles without warnings

⸻

GitHub Agent Task List (MVP)
	•	Create SwiftUI iOS app scaffold
	•	Implement data models: Goal, Constraint, CathedralProfile
	•	Implement persistence layer
	•	Build Cathedral Editor screen
	•	Implement Compiler module
	•	Add Copy to Clipboard functionality
	•	Add Share Sheet export
	•	Add unit tests for Compiler output
	•	Add GitHub Actions workflow to build on PR
	•	Submit PR with screenshots and summary

⸻

Roadmap

Phase 1:
	•	Single profile
	•	Goals + Constraints
	•	Compiler + Copy

Phase 2:
	•	Templates
	•	Compile modes
	•	Improved formatting

Phase 3:
	•	Multiple profiles
	•	Redaction rules
	•	BYO API key support
	•	Version history

⸻

Product Principle

If it is not faster than re-explaining yourself, it fails.

CathedralOS exists to reduce ambiguity between you and AI.

Not to become another system you have to maintain.

⸻

If you want next, I can generate:
	•	A starter Swift file structure
	•	A basic Compiler.swift implementation
	•	A GitHub Actions iOS build workflow
	•	Or a Product Hunt-style positioning draft

Just pick the next brick.
