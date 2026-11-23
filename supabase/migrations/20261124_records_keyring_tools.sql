-- 색 잣대 도구 늘리기: 톤파인더 기본, 컬러카드·컬러칩, 컬러프레임
-- records.keyring 칸에 도구 값을 그대로 쓴다. 예전 값('바다'·'숲'·'꽃'·'제주블루스'·'')은 그대로 허용.
alter table public.records drop constraint if exists records_keyring_check;
alter table public.records add constraint records_keyring_check
  check (keyring = any (array['', '바다', '숲', '꽃', '제주블루스', '기본', '컬러칩', '컬러프레임']));
comment on column public.records.keyring is
  '함께 찍은 색 잣대: 톤파인더 기본·바다·숲·꽃, 컬러칩(컬러카드·컬러칩), 컬러프레임, 제주블루스 키링. 빈 값은 잣대 없이 찍은 기록';
