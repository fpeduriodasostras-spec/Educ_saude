-- só para o banco DESCARTÁVEL: imita o que o banco de verdade já tem
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''), nullif(current_setting('request.jwt.claims', true), ''))::jsonb
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.jwt() to anon, authenticated, service_role;
create table if not exists public.os_campo (
  id bigint primary key, numero integer, numero_fict integer, fict_ref text, unidade text, foto_urls text[], contrato text
);
alter table public.os_campo enable row level security;
drop policy if exists "fpv_autenticados_select" on public.os_campo;
create policy "fpv_autenticados_select" on public.os_campo for select to authenticated using (true);
grant select on public.os_campo to authenticated;
insert into public.os_campo values
  (1682, 1681, null, null, 'Escola M. João Batista Gomes da Cruz', array['https://x/1.jpg','https://x/2.jpg'], 'Educação'),
  (1694, 1693, null, null, 'Creche M. Valdira Flausino Rodrigues', array['https://x/3.jpg'], 'Educação'),
  (4398, null, null, 'NS29', 'UBS Nilson Gonçalves Marins', array['https://x/4.jpg'], 'Saúde')
on conflict do nothing;
