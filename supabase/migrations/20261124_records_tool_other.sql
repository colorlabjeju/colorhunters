-- 색 잣대 «기타»(흰 종이·다른 색표)와 «사진만»(색 잣대 없이)
--  · keyring에 '기타' 허용. «사진만»은 지금처럼 keyring = ''
--  · tool_note : keyring이 '기타'일 때 주민이 적은 도구 이름 (30자)
alter table public.records drop constraint if exists records_keyring_check;
alter table public.records add constraint records_keyring_check
  check (keyring = any (array['', '바다', '숲', '꽃', '제주블루스', '기본', '컬러칩', '컬러프레임', '기타']));
alter table public.records add column if not exists tool_note text;
alter table public.records drop constraint if exists records_tool_note_check;
alter table public.records add constraint records_tool_note_check check (tool_note is null or char_length(tool_note) <= 30);
comment on column public.records.tool_note is 'keyring이 ''기타''일 때 주민이 적은 도구 이름 (예: 흰 종이, 회색 카드). 그 밖에는 null';
comment on column public.records.keyring is
  '함께 찍은 색 잣대: 톤파인더 기본·바다·숲·꽃, 컬러칩(컬러카드·컬러칩), 컬러프레임, 기타(tool_note에 이름), 제주블루스 키링. 빈 값은 잣대 없이 찍은 기록(사진만)';
