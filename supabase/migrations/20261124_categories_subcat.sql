-- 울릉 분류 다시 짜기 (2026-11-24)
--  · «나물·약초»를 «식물·꽃·열매»에 합치고 체크(세부 분류 «나물·약초»)로
--  · «바다»는 바다 풍경이 기본, 갯바위·해조류를 가까이 찍으면 체크(세부 분류 «갯바위·해조류»)
--  · «풍경·지질»(산·들판·마을 풍경, 바위·절벽·흙) 새로
--  분류 순서: 식물·꽃·열매 · 바다 · 풍경·지질 · 농작물·먹거리 · 생업 재료 · 기타 · 기억 카드

-- 0) 아래 트리거는 2026-11-24 아침 DB 정의(사진 맞추기 포함)에 세부 분류 줄만 더한 것이다.
--    그 사이 정의가 바뀌었으면 덮어쓰지 않도록 여기서 멈춘다.
do $$ begin
  if md5(pg_get_functiondef('public.records_before_update'::regproc)) <> 'a80c75e0a58e48ff12d63c0acbe162f8' then
    raise exception 'records_before_update가 이 마이그레이션을 만든 뒤 바뀌었어요. 지금 정의에 v_sub 줄(선언·보관·짝 확인·반영)만 더해 다시 만들어 주세요';
  end if;
end $$;

-- 1) 세부 분류 칸
alter table public.records add column if not exists subcat text not null default '';
alter table public.records drop constraint if exists records_subcat_check;
alter table public.records add constraint records_subcat_check check (subcat in ('', '나물·약초', '갯바위·해조류'));
comment on column public.records.subcat is '세부 분류: 식물·꽃·열매 → 나물·약초(먹거나 약으로 씀), 바다 → 갯바위·해조류(가까이 찍음). 빈 값이면 기본(식물 / 바다 풍경)';

-- 2) 울릉 분류 목록 (작성자가 분류를 고칠 때 이 목록으로 확인한다)
update public.editions
   set categories = array['식물·꽃·열매','바다','풍경·지질','농작물·먹거리','생업 재료','기타','기억 카드']
 where slug = 'ulleung';

-- 3) 예전 «나물·약초» 기록을 합친 분류로 (작성자 확인 트리거는 이 한 번만 건너뛴다)
select set_config('app.claiming', '1', true);
update public.records set category = '식물·꽃·열매', subcat = '나물·약초' where category = '나물·약초';
select set_config('app.claiming', '', true);

-- 4) 작성자가 확인 중·인정 기록에서 세부 분류를 고칠 수 있게
create or replace function public.records_before_update()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_share boolean; v_ln text; v_cn text; v_us text; v_st text;
        v_cat text; v_area text; v_pid text; v_light text; v_wx text; v_f boolean := false;
        v_note text; v_taken timestamptz; v_src text; v_sun numeric;
        v_crop jsonb; v_prev text; v_sub text;
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
  -- 작성자: 공개 여부는 언제나. 확인 중(pending)·인정(approved) 기록에서 글과 분류(세부 분류 포함)·동네·찍은 때·날씨를 고칠 수 있다
  v_share := new.share;
  v_ln := left(btrim(coalesce(new.local_name, '')), 40);
  v_cn := left(btrim(coalesce(new.color_name, '')), 30);
  v_us := left(btrim(coalesce(new.usage, '')), 500);
  v_st := left(btrim(coalesce(new.story, '')), 1000);
  v_cat := new.category; v_area := left(btrim(coalesce(new.area, '')), 40); v_pid := coalesce(new.place_id, '');
  v_light := btrim(coalesce(new.light, '')); v_wx := btrim(coalesce(new.weather, ''));  -- 비어 있으면 '' (칸이 not null)
  v_note := nullif(left(btrim(coalesce(new.time_note, '')), 40), '');
  v_taken := new.taken_at; v_src := new.taken_src; v_sun := new.sun_elev;
  v_crop := new.photo2_crop; v_prev := new.photo2_preview;
  v_sub := btrim(coalesce(new.subcat, ''));
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
    -- 세부 분류는 정해진 짝(식물·꽃·열매 ↔ 나물·약초, 바다 ↔ 갯바위·해조류)일 때만. 아니면 비운다
    if not ((new.category = '식물·꽃·열매' and v_sub = '나물·약초') or (new.category = '바다' and v_sub = '갯바위·해조류')) then
      v_sub := '';
    end if;
    if v_sub is distinct from coalesce(old.subcat, '') then
      new.subcat := v_sub; v_f := true;
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
    -- 사진 맞추기(② 사진의 틀): 작성자가 다시 맞출 수 있다. 틀과 함께 새로 만든 미리보기 경로도 받되, 자기 폴더의 파일만
    if v_crop is distinct from old.photo2_crop then
      if v_crop is not null and not public.photo_crop_ok(v_crop) then raise exception 'bad crop'; end if;
      new.photo2_crop := v_crop; v_f := true;
      if v_prev is distinct from old.photo2_preview and v_prev like auth.uid()::text || '/%' then
        new.photo2_preview := v_prev;
      end if;
    end if;
    if v_f then new.fields_edited_at := now(); end if;
  end if;
  return new;
end $function$;
