-- 울릉 기록: 키링 부분 원본 자르기와, 사진①에서 주민이 짚은 키링·대상 위치(0~1 비율)
-- index.html의 claude/ulleung-questions 브랜치(3fce0ca)가 이 칸들을 씀 → 배포 전에 먼저 적용
alter table public.records
  add column if not exists photo1_keyring_path text,
  add column if not exists keyring_xy jsonb,
  add column if not exists target_xy jsonb;

comment on column public.records.photo1_keyring_path is '사진①에서 키링 부분만 원본 해상도로 자른 JPEG 경로 ({uid}/{id}-1k.jpg). 보정 계산용';
comment on column public.records.keyring_xy is '사진①에서 주민이 짚은 키링 위치 {x,y} — 사진 폭·높이 대비 0~1, 회전 보정 후 기준. crop: 자른 범위';
comment on column public.records.target_xy is '사진①에서 주민이 짚은 대상 위치 {x,y} — 색 추출 영역의 중심';
comment on column public.records.photo1_preview is '목록·갤러리용 작은 미리보기 (약 400px) 경로';
comment on column public.records.photo2_preview is '목록·갤러리용 작은 미리보기 (약 400px) 경로';

-- 키링 자른 사진도 작성자와 운영진이 볼 수 있게
drop policy if exists "photos read own or staff" on storage.objects;
create policy "photos read own or staff" on storage.objects for select to authenticated
using (
  bucket_id = 'record-photos' and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or public.is_any_staff()
    or exists (
      select 1 from public.records r
      where r.author = (select auth.uid())
        and objects.name in (r.photo1_path, r.photo1_preview, r.photo2_path, r.photo2_preview, r.photo1_keyring_path)
    )
  )
);
