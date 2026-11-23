-- «내가 본 색» 3색: 사진의 대상 둘레에서 뽑은 색. 키링 보정 전 값이라 calibrated:false 로 남긴다.
-- { method, calibrated:false, weightL:0.5, roi:{photo,x,y,r}, colors:[main,sub,sub], clusters5:[...] }
alter table public.records add column if not exists colors jsonb;
comment on column public.records.colors is '사진에서 뽑은 색(보정 전). method·calibrated·weightL·roi(색을 뽑은 곳)·colors[main,sub,sub]·clusters5. 작성자는 올릴 때만, 그 뒤는 운영진이 채운다';
