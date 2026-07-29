-- ---------------------------------------------------------------------------
-- Phase 1 generation telemetry: per-model cost rates and margin columns.
-- Source of truth: docs/generation-budget.md §5.
-- ---------------------------------------------------------------------------

-- model_rates: per-model USD/token cost. Keyed by provider_model string so
-- it matches generation_usage_events.model_name directly (no JOIN).
create table if not exists public.model_rates (
  model_name             text          primary key,
  input_per_1k_usd       numeric(10,6) not null check (input_per_1k_usd >= 0),
  output_per_1k_usd      numeric(10,6) not null check (output_per_1k_usd >= 0),
  premium_markup_pct     numeric(5,4)  not null default 0.0 check (premium_markup_pct >= 0),
  tier                   text          not null check (tier in ('cheap','standard','premium')),
  is_active              boolean       not null default true,
  notes                  text          null,
  updated_at             timestamptz   not null default now()
);

create index if not exists idx_model_rates_tier_active
  on public.model_rates(tier, is_active);

-- Extend generation_usage_events with margin / cost columns. All nullable
-- because failed generations have no tokens / revenue to attribute.
alter table public.generation_usage_events
  add column if not exists model_input_usd     numeric(10,6),
  add column if not exists model_output_usd    numeric(10,6),
  add column if not exists total_model_usd     numeric(10,6),
  add column if not exists credit_revenue_usd  numeric(10,6),
  add column if not exists margin_usd          numeric(10,6),
  add column if not exists margin_pct          numeric(10,6);

create index if not exists idx_generation_usage_events_created_at
  on public.generation_usage_events(created_at desc);
create index if not exists idx_generation_usage_events_model_name
  on public.generation_usage_events(model_name);
create index if not exists idx_generation_usage_events_status_created
  on public.generation_usage_events(status, created_at desc);

-- RLS: model_rates is publicly readable for active rows; writes are service_role only.
alter table public.model_rates enable row level security;

create policy "model_rates: anyone can read active rows"
  on public.model_rates for select
  using (is_active = true);

-- generation_usage_events column additions inherit existing RLS (users see only
-- their own rows; the new columns are pure telemetry, no extra policy needed).

-- ---------------------------------------------------------------------------
-- Seed data. Sources: public list pricing pages of each provider as of
-- early 2026. Validate against provider invoices before relying on margin
-- numbers — see docs/generation-budget.md §5.2 validation checklist.
-- Premium_markup_pct is applied to the base credit charge (cheap = 0.0,
-- standard = 0.5, premium = 1.5). Kimi and MiniMax are seeded inactive
-- until Kevin wires up the endpoints.
-- ---------------------------------------------------------------------------
insert into public.model_rates
  (model_name, input_per_1k_usd, output_per_1k_usd, premium_markup_pct, tier, is_active, notes)
values
  -- Cheap tier (×1.0 multiplier)
  ('gpt-4o-mini',        0.000150, 0.000600, 0.0, 'cheap',    true,  'Default per _generation_models.ts'),
  ('gpt-4.1-mini',       0.000400, 0.001600, 0.0, 'cheap',    true,  'OpenAI mid-cheap'),
  ('gpt-4.1-nano',       0.000100, 0.000400, 0.0, 'cheap',    true,  'OpenAI nano, very cheap'),
  ('claude-3-5-haiku',   0.000800, 0.004000, 0.0, 'cheap',    true,  'Anthropic cheap'),
  ('gemini-2.0-flash',   0.000100, 0.000400, 0.0, 'cheap',    true,  'Google cheap'),
  ('gemini-1.5-flash',   0.000075, 0.000300, 0.0, 'cheap',    true,  'Google older cheap'),
  ('kimi',               0.000150, 0.000600, 0.0, 'cheap',    false, 'Moonshot Kimi — endpoint not wired yet'),
  ('MiniMax',            0.000100, 0.000400, 0.0, 'cheap',    false, 'MiniMax — endpoint not wired yet'),

  -- Standard tier (×1.5 multiplier)
  ('gpt-4o',             0.002500, 0.010000, 0.5, 'standard', true,  'OpenAI standard'),
  ('gpt-4.1',            0.002000, 0.008000, 0.5, 'standard', true,  'OpenAI 4.1'),
  ('claude-3-5-sonnet',  0.003000, 0.015000, 0.5, 'standard', true,  'Anthropic standard'),
  ('gemini-1.5-pro',     0.001250, 0.005000, 0.5, 'standard', true,  'Google standard'),

  -- Premium tier (×2.5 multiplier)
  ('claude-3-opus',      0.015000, 0.075000, 1.5, 'premium',  true,  'Anthropic premium'),
  ('o1',                 0.015000, 0.060000, 1.5, 'premium',  true,  'OpenAI reasoning'),
  ('o3-mini',            0.001100, 0.004400, 1.5, 'premium',  true,  'OpenAI reasoning small')
on conflict (model_name) do update set
  input_per_1k_usd   = excluded.input_per_1k_usd,
  output_per_1k_usd  = excluded.output_per_1k_usd,
  premium_markup_pct = excluded.premium_markup_pct,
  tier               = excluded.tier,
  is_active          = excluded.is_active,
  notes              = excluded.notes,
  updated_at         = now();
