-- OpenAI text-embedding-3-small: $0.02 / 1M input tokens.
-- Embeddings have no output-token charge and no minimum customer charge.
insert into public.generation_models (
  id, provider, provider_model, display_name, description,
  input_credit_rate, output_credit_rate, minimum_charge_credits,
  max_output_tokens, enabled, sort_order,
  provider_input_usd_per_1m, provider_cached_input_usd_per_1m,
  provider_output_usd_per_1m, billing_multiplier, cache_mode
) values (
  'text-embedding-3-small', 'openai', 'text-embedding-3-small',
  'OpenAI Embeddings', 'Scene-memory vector embeddings.',
  0.004, 0, 0, null, true, 900,
  0.02, 0.02, 0, 2.0, 'none'
)
on conflict (id) do update set
  provider = excluded.provider,
  provider_model = excluded.provider_model,
  input_credit_rate = excluded.input_credit_rate,
  output_credit_rate = excluded.output_credit_rate,
  minimum_charge_credits = excluded.minimum_charge_credits,
  provider_input_usd_per_1m = excluded.provider_input_usd_per_1m,
  provider_cached_input_usd_per_1m = excluded.provider_cached_input_usd_per_1m,
  provider_output_usd_per_1m = excluded.provider_output_usd_per_1m,
  billing_multiplier = excluded.billing_multiplier,
  cache_mode = excluded.cache_mode,
  enabled = true;
