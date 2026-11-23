-- 울릉 주민이 «수집단 N번» 같은 번호 별칭을 자기 이름·별명으로 바꾼다.
-- invites는 운영진만 고칠 수 있으므로, 본인 행의 nickname만 바꾸는 함수를 둔다. (real_name·phone·memo는 그대로)
create or replace function public.set_my_nickname(p_nickname text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v text := btrim(coalesce(p_nickname, ''));
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if char_length(v) < 1 or char_length(v) > 20 then raise exception 'bad nickname'; end if;
  update public.invites set nickname = v where user_id = auth.uid();
  insert into public.profiles (id, nickname) values (auth.uid(), v)
    on conflict (id) do update set nickname = excluded.nickname;
  return v;
end
$$;

revoke all on function public.set_my_nickname(text) from public, anon;
grant execute on function public.set_my_nickname(text) to authenticated;
