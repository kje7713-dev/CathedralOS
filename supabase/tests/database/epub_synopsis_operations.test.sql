-- Paid EPUB synopsis operation claim/recovery integration tests.
create extension if not exists pgtap;
\set ON_ERROR_STOP on
begin;
select plan(14);

insert into auth.users (id, email)
values ('00000000-0000-4000-8000-000000008601', 'pr860-synopsis@example.invalid');
insert into public.user_entitlements (user_id, monthly_credit_allowance, entitlement_source)
values ('00000000-0000-4000-8000-000000008601', 10, 'manual');

create temporary table synopsis_claim_a as
select * from public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-a', 'project-a', 'Book A', 'fingerprint-a'
);
select is((select claim_status from synopsis_claim_a), 'claimed', 'first request atomically claims operation');
select isnt((select claim_token from synopsis_claim_a), null, 'first claim receives an ownership token');

select is((select claim_status from public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-a', 'project-a', 'Book A', 'fingerprint-a'
)), 'in_progress', 'active claim cannot be stolen by concurrent retry');

update public.epub_synopsis_operations
   set synopsis = repeat('synopsis ', 90),
       provider_model = 'gpt-test',
       provider_input_tokens = 100,
       provider_output_tokens = 100,
       claimed_at = now()
 where user_id = '00000000-0000-4000-8000-000000008601'
   and operation_id = 'op-a'
   and claim_token = (select claim_token from synopsis_claim_a);
select is((select claim_status from public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-a', 'project-a', 'Book A', 'fingerprint-a'
)), 'in_progress', 'checkpointed synopsis remains owned while claim is active');

update public.epub_synopsis_operations
   set claimed_at = now() - interval '11 minutes'
 where user_id = '00000000-0000-4000-8000-000000008601' and operation_id = 'op-a';
create temporary table synopsis_claim_b as
select * from public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-a', 'project-a', 'Book A', 'fingerprint-a'
);
select is((select claim_status from synopsis_claim_b), 'ready', 'expired checkpoint can be recovered');
select isnt((select claim_token from synopsis_claim_b), (select claim_token from synopsis_claim_a), 'recovery gets a new ownership token');

select is((select settlement_status from public.settle_billable_usage(
  '00000000-0000-4000-8000-000000008601', 'generate', 'epub-synopsis', 'gpt-test',
  'synopsis-billing-key', 1, 100, 100, 'short', 320
)), 'settled', 'recovery uses the shared atomic billing settlement');

update public.epub_synopsis_operations
   set status = 'complete', completed_at = now()
 where user_id = '00000000-0000-4000-8000-000000008601'
   and operation_id = 'op-a'
   and claim_token = (select claim_token from synopsis_claim_b)
   and status = 'pending';
select is((select status from public.epub_synopsis_operations where operation_id = 'op-a'), 'complete', 'successful charge can complete operation');
select is((select claim_status from public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-a', 'project-a', 'Book A', 'fingerprint-a'
)), 'complete', 'completed operation is replayable');
select is((select synopsis from public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-a', 'project-a', 'Book A', 'fingerprint-a'
)), repeat('synopsis ', 90), 'completed replay returns persisted synopsis');

select is((select claim_status from public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-b', 'project-a', 'Book A', 'fingerprint-a'
)), 'claimed', 'distinct operation IDs claim independently');
select throws_ok($$select public.claim_epub_synopsis_operation(
  '00000000-0000-4000-8000-000000008601', 'op-a', 'different-project', 'Book A', 'fingerprint-a'
)$$, null, null, 'reusing an operation for a different source fails closed');
select ok((select monthly_credit_allowance from public.user_entitlements where user_id = '00000000-0000-4000-8000-000000008601') < 10, 'shared settlement charged credits exactly through entitlement ledger');
select ok((select count(*) from public.generation_usage_events where idempotency_key = 'synopsis-billing-key') = 1, 'shared settlement wrote one usage event');

select * from finish();
rollback;
