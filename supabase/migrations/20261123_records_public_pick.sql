-- 두 단계 공개: «인정»(아카이브 데이터로 쓸 수 있다)과 «공개 선정»(바깥에 보여 줄 대표 기록)을 나눈다.
-- 초대형 미션(울릉)은 운영진이 «공개 선정»한 기록만 바깥에 나간다.
-- 누구나 참여하는 미션(제주블루스·동백 등)은 예전처럼 인정 + 공개 동의면 자동으로 공개 선정된다.
alter table public.records
  add column if not exists public_pick boolean not null default false,
  add column if not exists public_picked_at timestamptz,
  add column if not exists public_picked_by uuid;
comment on column public.records.public_pick is '바깥(누구나 보는 화면)에 내보낼 기록으로 운영진이 고름. 인정 + 공개 동의일 때만 true';

-- records_bu(작성자는 new := old 로 되돌림) 뒤에 돌도록 이름을 records_pick 으로 둔다 (트리거는 이름 순서로 실행)
create or replace function public.records_pick()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if tg_op = 'INSERT' then new.public_pick := false; end if;
  if new.status <> 'approved' or not new.share then
    new.public_pick := false;   -- 인정이 풀리거나 주민이 공개 동의를 끄면 바로 내린다
  elsif exists (select 1 from public.editions e where e.slug = new.edition and e.status = 'public') then
    new.public_pick := true;    -- 누구나 참여하는 미션은 따로 고르지 않는다
  end if;
  if tg_op = 'INSERT' or new.public_pick is distinct from old.public_pick then
    new.public_picked_at := case when new.public_pick then now() end;
    new.public_picked_by := case when new.public_pick then auth.uid() end;
  else
    new.public_picked_at := old.public_picked_at;
    new.public_picked_by := old.public_picked_by;
  end if;
  return new;
end $function$;
revoke all on function public.records_pick() from public, anon, authenticated;

drop trigger if exists records_pick on public.records;
create trigger records_pick before insert or update on public.records
  for each row execute function public.records_pick();

-- 처음 한 번: 지금 인정 + 공개 동의된 기록은 공개 선정으로 옮긴다
do $$ begin
  perform set_config('app.claiming', '1', true);
  update public.records set public_pick = true where status = 'approved' and share;
  perform set_config('app.claiming', '', true);
end $$;

-- 표를 직접 읽을 때도 바깥에는 공개 선정된 기록만
drop policy if exists "records read approved public" on public.records;
create policy "records read approved public" on public.records for select to anon
  using (status = 'approved' and share and public_pick);
drop policy if exists "records read" on public.records;
create policy "records read" on public.records for select to authenticated
  using (
    author = (select auth.uid())
    or (status = 'approved' and share and public_pick)
    or public.has_edition_role(array['reviewer','admin','superadmin'], edition)
  );
