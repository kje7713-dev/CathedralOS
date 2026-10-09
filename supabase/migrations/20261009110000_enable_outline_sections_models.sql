-- CathedralOS — make the Outline Sections MVP model surface operational.
-- Only exact approved IDs are touched, and only when the existing catalog
-- already satisfies the same provider/pricing gates used by runtime billing.
-- This does not create aliases or substitute one provider model for another.

update public.generation_models
set
  enabled = true,
  display_name = case id
    when 'gpt-6-luna' then 'GPT-6 Luna'
    when 'gpt-6.1-sol' then 'GPT-6.1 Sol'
    when 'gpt-6-astra' then 'GPT-6 Astra'
    else display_name
  end,
  sort_order = case id
    when 'gpt-6-luna' then 35
    when 'gpt-6.1-sol' then 45
    when 'gpt-6-astra' then 55
    else sort_order
  end,
  updated_at = now()
where id in ('gpt-6-luna', 'gpt-6.1-sol', 'gpt-6-astra')
  and provider = 'openai'
  and provider_model = id
  and enabled is not true
  and provider_available = true
  and model_kind = 'text_generation'
  and pricing_state = 'verified'
  and pricing_verified_at is not null
  and coalesce(provider_input_usd_per_1m, 0) > 0
  and coalesce(provider_output_usd_per_1m, 0) > 0
  and coalesce(billing_multiplier, 0) > 0
  and (
    cache_write_pricing_required is not true
    or provider_cache_write_usd_per_1m is not null
  );
