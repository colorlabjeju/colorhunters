-- 찍은 때: 시계 칸 대신 해 높이로 이름표를 붙인다.
--  · sun_elev  : 찍은 시각·위치로 계산한 해 높이(도, 소수 1자리)
--  · taken_src : 찍은 시각이 어디서 왔는지 — exif(사진) / person(올린 사람이 적음) / file(파일 시각) / unknown(모름)
--  · time_note : «그때를 내 말로» (썰물 때, 비 갠 뒤 …) 40자
-- 예전 기록의 저장값은 바꾸지 않는다(새 칸은 비어 있음).
alter table public.records add column if not exists sun_elev numeric(4,1);
alter table public.records add column if not exists taken_src text;
alter table public.records add column if not exists time_note text;
alter table public.records drop constraint if exists records_sun_elev_check;
alter table public.records add constraint records_sun_elev_check check (sun_elev is null or (sun_elev >= -90 and sun_elev <= 90));
alter table public.records drop constraint if exists records_taken_src_check;
alter table public.records add constraint records_taken_src_check check (taken_src is null or taken_src in ('exif','person','file','unknown'));
alter table public.records drop constraint if exists records_time_note_check;
alter table public.records add constraint records_time_note_check check (time_note is null or char_length(time_note) <= 40);
comment on column public.records.sun_elev is '찍은 시각·위치로 계산한 해 높이(도). light 이름표의 근거';
comment on column public.records.taken_src is '찍은 시각의 출처: exif | person | file | unknown';
comment on column public.records.time_note is '그때를 내 말로 (40자)';

create or replace function public.records_before_update()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_share boolean; v_ln text; v_cn text; v_us text; v_st text;
        v_cat text; v_area text; v_pid text; v_light text; v_wx text; v_f boolean := false;
        v_note text; v_taken timestamptz; v_src text; v_sun numeric;
begin
  if coalesce(current_setting('app.claiming', true), '') = '1' then
    return new;
  end if;
  new.light := coalesce(new.light, '');
  new.weather := coalesce(new.weather, '');
  if public.has_edition_role(array['reviewer','admin','superadmin'], old.edition) then
    -- 판정이 바뀌거나, 운영진이 다시 확인했다고 reviewed_at을 보내면(인정 후 고친 기록 재확인) 확인한 사람·시각을 남긴다
    if new.status is distinct from old.status or new.review_reasons is distinct from old.review_reasons or new.review_memo is distinct from old.review_memo
       or new.reviewed_at is distinct from old.reviewed_at then
      new.reviewed_by := auth.uid();
      new.reviewed_at := now();
    end if;
    new.author := old.author;
    new.created_at := old.created_at;
    return new;
  end if;
  if old.author is distinct from auth.uid() then
    raise exception 'not allowed';
  end if;
  if old.status = 'held' then
    new.status := 'pending';
    new.resubmitted_at := now();
    new.review_reasons := old.review_reasons;
    new.review_memo := old.review_memo;
    new.reviewed_by := old.reviewed_by;
    new.reviewed_at := old.reviewed_at;
    new.author := old.author;
    new.edition := old.edition;
    new.created_at := old.created_at;
    return new;
  end if;
  -- 작성자: 공개 여부는 언제나. 확인 중(pending)·인정(approved) 기록에서 글과 분류·동네·찍은 때·날씨를 고칠 수 있다
  v_share := new.share;
  v_ln := left(btrim(coalesce(new.local_name, '')), 40);
  v_cn := left(btrim(coalesce(new.color_name, '')), 30);
  v_us := left(btrim(coalesce(new.usage, '')), 500);
  v_st := left(btrim(coalesce(new.story, '')), 1000);
  v_cat := new.category; v_area := left(btrim(coalesce(new.area, '')), 40); v_pid := coalesce(new.place_id, '');
  v_light := btrim(coalesce(new.light, '')); v_wx := btrim(coalesce(new.weather, ''));  -- 비어 있으면 '' (칸이 not null)
  v_note := nullif(left(btrim(coalesce(new.time_note, '')), 40), '');
  v_taken := new.taken_at; v_src := new.taken_src; v_sun := new.sun_elev;
  new := old;
  new.share := v_share;
  if old.status in ('pending', 'approved') then
    if v_ln <> '' and (v_ln is distinct from coalesce(old.local_name, '') or v_us is distinct from coalesce(old.usage, '') or v_st is distinct from coalesce(old.story, '')) then
      if old.is_memory and v_st = '' then
        raise exception 'story required';
      end if;
      new.local_name := v_ln;
      new.color_name := case when v_cn <> '' then v_cn else left(v_ln, 30) end;
      new.usage := v_us;
      new.story := v_st;
      new.text_edited_at := now();
    end if;
    if v_cat is distinct from old.category then
      if old.is_memory or v_cat is null or v_cat = '기억 카드'
         or not exists (select 1 from public.editions e where e.slug = old.edition and v_cat = any(e.categories)) then
        raise exception 'bad category';
      end if;
      new.category := v_cat; v_f := true;
    end if;
    if v_area <> '' and v_area is distinct from coalesce(old.area, '') then
      new.area := v_area; new.place_name := v_area; new.place_id := v_pid; v_f := true;
    end if;
    -- 찍은 시각을 손으로 고치면 출처는 person(적음) 또는 unknown(모름)만. 사진에서 읽었다고(exif) 바꿔 적을 수는 없다
    if v_taken is distinct from old.taken_at or v_src is distinct from old.taken_src then
      if v_src = 'unknown' then
        new.taken_at := null; new.sun_elev := null; new.taken_src := 'unknown';
      elsif v_src = 'person' and v_taken is not null then
        new.taken_at := v_taken; new.taken_src := 'person';
        new.sun_elev := case when v_sun between -90 and 90 then round(v_sun, 1) else null end;
      else
        raise exception 'bad taken';
      end if;
      v_f := true;
    end if;
    if v_light is distinct from coalesce(old.light, '') then
      if v_light <> '' and v_light not in ('새벽','아침','오전','한낮','오후','해 질 녘','밤') then raise exception 'bad light'; end if;
      new.light := v_light; v_f := true;
    end if;
    if v_wx is distinct from coalesce(old.weather, '') then
      if v_wx <> '' and v_wx not in ('맑음','구름 조금','흐림','비·눈','안개') then raise exception 'bad weather'; end if;
      new.weather := v_wx; v_f := true;
    end if;
    if v_note is distinct from old.time_note then
      new.time_note := v_note; v_f := true;
    end if;
    if v_f then new.fields_edited_at := now(); end if;
  end if;
  return new;
end $function$;
