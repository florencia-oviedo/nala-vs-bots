-- =========================================================
--  Nala vs. los Bots · base de datos del ranking y visitas
--  Pegá TODO este archivo en Supabase → SQL Editor → Run
--  (se puede volver a ejecutar sin romper nada)
-- =========================================================

-- 1) Tabla del ranking
create table if not exists public.scores (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  mode        text     not null check (mode in ('normal','express')),
  name        text     not null check (char_length(name) between 1 and 30),
  score       integer  not null check (score between 1 and 15000),
  wave        smallint not null check (wave between 1 and 5),
  medal       text     not null default '' check (medal in ('', '🥇', '🥈', '🥉'))
);
-- nombres sin caracteres invisibles ni de control
alter table public.scores drop constraint if exists scores_name_clean;
alter table public.scores add  constraint scores_name_clean
  check (name !~ '[[:cntrl:]​-‏‪-‮⁠-⁩﻿]' and btrim(name) <> '');

create index if not exists scores_mode_score_idx on public.scores (mode, score desc);
create index if not exists scores_created_idx    on public.scores (created_at desc);

-- Seguridad: cualquiera puede LEER y AGREGAR puntajes; nadie puede editar ni borrar
alter table public.scores enable row level security;
drop policy if exists "leer ranking"    on public.scores;
drop policy if exists "agregar puntaje" on public.scores;
create policy "leer ranking"    on public.scores for select to anon using (true);
create policy "agregar puntaje" on public.scores for insert to anon with check (true);
revoke all on public.scores from anon, authenticated;
grant select (id, name, score, wave, medal, mode) on public.scores to anon;
grant insert (mode, name, score, wave, medal)     on public.scores to anon;

-- Filtro de nombres ofensivos (palabras completas, para no bloquear nombres como Penélope o Vergara)
create or replace function public.nombre_ofensivo(n text) returns boolean
language plpgsql immutable set search_path = public as $$
declare
  base text := translate(lower(n), 'áàäâéèëêíìïîóòöôúùüûñ', 'aaaaeeeeiiiioooouuuun');
  v text; x text;
begin
  foreach v in array array[ translate(base, '01!34@5$7', 'oiieaasst'), regexp_replace(base, '[0-9]+', ' ', 'g') ] loop
    v := regexp_replace(v, '([a-z])[._*+·-]+(?=[a-z])', '\1', 'g');
    v := btrim(regexp_replace(v, '[^a-z]+', ' ', 'g'));
    foreach x in array array[ v, regexp_replace(v, '(.)\1+', '\1', 'g') ] loop
      if x ~ '(^| )(?:la concha|put[oa]s?|putit[oa]s?|pija|pijas|pijud[oa]s?|verga|vergas|vergota|cul[oa]s?|culit[oa]|culiao|culiado|culead[oa]|forr[oa]s?|bolud[oa]s?|chot[oa]s?|coger[a-z]*|cogete|cogeme|cogid[oa]s?|cojer[a-z]*|sexo|sexual|sexy|pene|penes|tetas?|tetona|tetonas|orto|ortos|trol[oa]s?|mogolic[oa]s?|maric[oa]s?|maricon|maricones|idiotas?|estupid[oa]s?|imbecil|imbeciles|tarad[oa]s?|pajer[oa]s?|cornud[oa]s?|kkk|shit|bitch|dick|dicks|cock|ass|asshole|whore|slut|nigger|nigga|negr[oa]demierda|(?:mierd|pelotud|conchetu|conchasu|hijodeput|hdp|garch|fuck|porn|nazi|hitler|prostitut|violad|violacion|suicid|vagin)[a-z]*)( |$)' then return true; end if;
      if replace(x,' ','') ~ 'porn|fuck|nazi|hitler|pelotud|mierd|conchetu|hijodeput|prostitut|nigger' then return true; end if;
      if replace(x,' ','') ~ '^(?:(?:mierd|pelotud|conchetu|conchasu|hijodeput|hdp|garch|fuck|porn|nazi|hitler|prostitut|violad|violacion|suicid|vagin)|(?:la concha|put[oa]s?|putit[oa]s?|pija|pijas|pijud[oa]s?|verga|vergas|vergota|cul[oa]s?|culit[oa]|culiao|culiado|culead[oa]|forr[oa]s?|bolud[oa]s?|chot[oa]s?|coger[a-z]*|cogete|cogeme|cogid[oa]s?|cojer[a-z]*|sexo|sexual|sexy|pene|penes|tetas?|tetona|tetonas|orto|ortos|trol[oa]s?|mogolic[oa]s?|maric[oa]s?|maricon|maricones|idiotas?|estupid[oa]s?|imbecil|imbeciles|tarad[oa]s?|pajer[oa]s?|cornud[oa]s?|kkk|shit|bitch|dick|dicks|cock|ass|asshole|whore|slut|nigger|nigga|negr[oa]demierda)$)' then return true; end if;
    end loop;
  end loop;
  return false;
end $$;

-- Control al guardar: freno anti-spam + filtro de palabras ofensivas
create or replace function public.scores_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.scores where created_at > now() - interval '1 minute') >= 40 then
    raise exception 'Demasiados puntajes seguidos, probá en un minuto';
  end if;
  if (select count(*) from public.scores
        where name = new.name and created_at > now() - interval '1 minute') >= 5 then
    raise exception 'Demasiados puntajes con ese nombre, probá en un minuto';
  end if;
  if public.nombre_ofensivo(new.name) then
    new.name := 'Anónima';
  end if;
  new.created_at := now();
  return new;
end $$;
drop trigger if exists scores_rate_limit on public.scores;
drop function if exists public.scores_rate_limit();
drop trigger if exists scores_guard on public.scores;
create trigger scores_guard before insert on public.scores
  for each row execute function public.scores_guard();

-- 2) Contador de visitas (nadie puede tocar la tabla directo)
create table if not exists public.counters (
  name text primary key,
  n    bigint not null default 0
);
alter table public.counters enable row level security;
revoke all on public.counters from anon, authenticated;
insert into public.counters (name, n) values ('visits', 0) on conflict do nothing;

create or replace function public.hit_visit() returns bigint
language sql security definer set search_path = public as $$
  update public.counters set n = n + 1 where name = 'visits' returning n;
$$;
create or replace function public.get_visits() returns bigint
language sql stable security definer set search_path = public as $$
  select n from public.counters where name = 'visits';
$$;
revoke all on function public.hit_visit()  from public, anon, authenticated;
revoke all on function public.get_visits() from public, anon, authenticated;
grant execute on function public.hit_visit()  to anon;
grant execute on function public.get_visits() to anon;
revoke all on function public.scores_guard() from public, anon, authenticated;
revoke all on function public.nombre_ofensivo(text) from public, anon, authenticated;

-- =========================================================
--  Consultas útiles (ejecutalas cuando quieras):
--  Ver visitas:        select n from public.counters where name = 'visits';
--  Últimos puntajes:   select id, name, score, created_at from public.scores
--                      order by created_at desc limit 50;
--  Borrar un nombre:   delete from public.scores where id = 123;
--  Vaciar el ranking:  truncate public.scores;
-- =========================================================
