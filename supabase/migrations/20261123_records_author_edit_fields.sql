-- 주민은 현장에서 폰으로 빨리 올리고, 나중에 컴퓨터로 차분히 고친다.
-- 확인 중·인정 기록에서 작성자가 고칠 수 있는 칸을 넓힌다: 글(이름·답·이야기) + 분류·동네·찍은 때(light)·날씨.
-- 사진·키링·위치 좌표·상태는 그대로 막는다. 인정된 기록은 인정 상태를 유지하고, 고친 시각을 남겨 운영진이 다시 볼 수 있게 한다.
alter table public.records add column if not exists fields_edited_at timestamptz;
comment on column public.records.fields_edited_at is '작성자가 분류·동네·찍은 때·날씨를 고친 마지막 시각 (글은 text_edited_at)';

create or replace function public.records_before_update()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare v_share boolean; v_ln text; v_cn text; v_us text; v_st text;
        v_cat text; v_area text; v_pid text; v_light text; v_wx text; v_f boolean := false;
begin
  if coalesce(current_setting('app.claiming', true), '') = '1' then
    return new;
  end if;
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
  v_light := nullif(btrim(coalesce(new.light, '')), ''); v_wx := nullif(btrim(coalesce(new.weather, '')), '');
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
    if v_light is distinct from old.light then
      if v_light is not null and v_light not in ('새벽','아침','한낮','오후','해 질 녘','밤') then raise exception 'bad light'; end if;
      new.light := v_light; v_f := true;
    end if;
    if v_wx is distinct from old.weather then
      if v_wx is not null and v_wx not in ('맑음','구름 조금','흐림','비·눈','안개') then raise exception 'bad weather'; end if;
      new.weather := v_wx; v_f := true;
    end if;
    if v_f then new.fields_edited_at := now(); end if;
  end if;
  return new;
end $function$;
