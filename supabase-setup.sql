-- =====================================================================
--  פיתוח חברותא מרכז – הקמת מסד הנתונים ב-Supabase
--  להדביק את כל הקובץ ב-SQL Editor של הפרויקט וללחוץ Run.
--  אפשר להריץ שוב בבטחה (לא מוחק נתונים קיימים).
--
--  עקרון האבטחה: לציבור אין גישה ישירה לאף טבלה.
--  כל פעולה עוברת דרך פונקציה בשרת שבודקת מה מותר:
--   • ציבור: שליחת פנייה, בדיקת סטטוס לפי קוד, קריאת המאגר הציבורי.
--   • משרתים: רק אחרי כניסה עם סיסמה (שנשמרת מוצפנת בשרת בלבד).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- טבלאות ----------
create table if not exists public.fd_inquiries (
  id          text primary key,
  code        text unique,                       -- 4 ספרות, רק לפנייה אנונימית
  status      text not null default 'new'
              check (status in ('new','in_review','awaiting_clarification','closed')),
  data        jsonb not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  closed_at   timestamptz
);
create table if not exists public.fd_kb (
  id           text primary key,
  entry        jsonb not null,
  published_at timestamptz not null default now()
);
create table if not exists public.fd_admin (
  id        int primary key default 1 check (id = 1),
  pass_hash text not null
);
create table if not exists public.fd_sessions (
  token_hash text primary key,
  expires_at timestamptz not null
);
create table if not exists public.fd_throttle (
  bucket       text primary key,
  n            int not null,
  window_start timestamptz not null
);

-- נעילה: RLS פעיל בלי מדיניות = אין גישה ישירה לטבלאות
alter table public.fd_inquiries enable row level security;
alter table public.fd_kb        enable row level security;
alter table public.fd_admin     enable row level security;
alter table public.fd_sessions  enable row level security;
alter table public.fd_throttle  enable row level security;
revoke all on public.fd_inquiries, public.fd_kb, public.fd_admin, public.fd_sessions, public.fd_throttle from anon, authenticated;

-- ---------- פונקציות פנימיות ----------
create or replace function public.fd_now_ms() returns bigint
language sql stable as $$ select (extract(epoch from now()) * 1000)::bigint $$;

-- מגבלת קצב גלובלית (בלי IP – כדי לא לפגוע באנונימיות)
create or replace function public.fd_hit(p_bucket text, p_max int, p_window interval) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  select * into r from fd_throttle where bucket = p_bucket for update;
  if not found or r.window_start < now() - p_window then
    insert into fd_throttle(bucket, n, window_start) values (p_bucket, 1, now())
      on conflict (bucket) do update set n = 1, window_start = now();
    return true;
  end if;
  if r.n >= p_max then return false; end if;
  update fd_throttle set n = n + 1 where bucket = p_bucket;
  return true;
end $$;

create or replace function public.fd_over_limit(p_bucket text, p_max int, p_window interval) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select n >= p_max and window_start >= now() - p_window from fd_throttle where bucket = p_bucket), false)
$$;

create or replace function public.fd_check_token(p_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is null or not exists (
       select 1 from fd_sessions
       where token_hash = encode(digest(p_token, 'sha256'), 'hex') and expires_at > now()) then
    raise exception 'not_authorized';
  end if;
end $$;

-- מחיקות אוטומטיות (נקרא מתוך שליחת פנייה, בלי צורך בתזמון)
create or replace function public.fd_purge() returns void
language plpgsql security definer set search_path = public as $$
begin
  -- פרטי קשר נמחקים 30 יום אחרי שהפנייה נסגרה
  update fd_inquiries set data = data - 'phone' - 'email'
   where closed_at < now() - interval '30 days' and (data ? 'phone' or data ? 'email');
  -- פניות סגורות נמחקות 180 יום אחרי הסגירה
  delete from fd_inquiries where closed_at < now() - interval '180 days';
  delete from fd_sessions where expires_at < now();
end $$;

-- ---------- פעולות ציבוריות ----------
create or replace function public.fd_submit(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_channel text := p->>'channel';
  v_q       text := left(coalesce(p->>'question',''), 3000);
  v_phone   text := regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g');
  v_email   text := left(trim(coalesce(p->>'email','')), 200);
  v_id      text := 'id-' || encode(gen_random_bytes(12), 'hex');
  v_code    text := null;
  v_data    jsonb;
  i int := 0;
begin
  if not fd_hit('submit', 60, interval '10 minutes') then raise exception 'rate_limited'; end if;
  if length(v_q) < 50 then raise exception 'question_too_short'; end if;
  if v_channel not in ('anonymous','whatsapp','email') then raise exception 'bad_channel'; end if;
  if v_channel = 'whatsapp' and length(v_phone) not between 8 and 15 then raise exception 'bad_phone'; end if;
  if v_channel = 'email' and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'bad_email'; end if;

  if v_channel = 'anonymous' then
    if (select count(*) from fd_inquiries where code is not null) >= 9000 then raise exception 'no_codes'; end if;
    loop
      v_code := lpad(((get_byte(gen_random_bytes(2),0) * 256 + get_byte(gen_random_bytes(2),1)) % 10000)::text, 4, '0');
      exit when not exists (select 1 from fd_inquiries where code = v_code);
      i := i + 1; if i > 200 then raise exception 'no_codes'; end if;
    end loop;
  end if;

  v_data := jsonb_build_object(
    'created',       fd_now_ms(),
    'channel',       v_channel,
    'question',      v_q,
    'tried',         left(coalesce(p->>'tried',''), 1500),
    'categoryLabel', left(coalesce(p->>'categoryLabel',''), 200),
    'urgency',       case when p->>'urgency' in ('normal','deadline_1w','deadline_2w') then p->>'urgency' else 'normal' end,
    'role',          case when p->>'role' in ('member','group_servant','service_body','other') then p->>'role' else null end,
    'publish',       coalesce((p->>'publish')::boolean, false),
    'phone',         case when v_channel = 'whatsapp' then v_phone else null end,
    'email',         case when v_channel = 'email' then v_email else null end
  );
  insert into fd_inquiries(id, code, status, data) values (v_id, v_code, 'new', v_data);
  perform fd_purge();
  return jsonb_build_object('ok', true, 'code', v_code);
end $$;

-- בדיקת סטטוס לפי קוד (רק פניות אנונימיות). מוגבל: 30 קודים שגויים בדקה לכל האתר.
create or replace function public.fd_status(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_code text := regexp_replace(coalesce(p_code,''), '\D', '', 'g');
begin
  if fd_over_limit('status-fail', 30, interval '1 minute') then raise exception 'rate_limited'; end if;
  select * into r from fd_inquiries where code = v_code and length(v_code) = 4;
  if not found then
    perform fd_hit('status-fail', 30, interval '1 minute');
    return null;
  end if;
  return jsonb_build_object(
    'status', r.status,
    'created', r.data->'created',
    'answered', r.data->'answered',
    'answerText', case when r.status = 'closed' then r.data->'answerText' end,
    'refs', case when r.status = 'closed' then r.data->'refs' end,
    'signedBy', r.status = 'closed',
    'clarification', r.data->'clarification',
    'clarReply', r.data->'clarReply',
    'question', r.data->'question',
    'categoryLabel', r.data->'categoryLabel');
end $$;

create or replace function public.fd_clarify(p_code text, p_text text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update fd_inquiries
     set data = data || jsonb_build_object('clarReply', left(p_text, 1500), 'clarReplyAt', fd_now_ms(), 'status', 'in_review'),
         status = 'in_review', updated_at = now()
   where code = regexp_replace(coalesce(p_code,''), '\D', '', 'g') and status = 'awaiting_clarification'
     and length(coalesce(p_text,'')) > 0;
  return found;
end $$;

create or replace function public.fd_delete_mine(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  delete from fd_inquiries where code = regexp_replace(coalesce(p_code,''), '\D', '', 'g') and code is not null;
  return found;
end $$;

create or replace function public.fd_kb_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(entry || jsonb_build_object('published', (extract(epoch from published_at)*1000)::bigint) order by published_at desc), '[]'::jsonb) from fd_kb
$$;

-- ---------- פעולות משרתים ----------
create or replace function public.fd_admin_login(p_pass text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_token text;
begin
  if fd_over_limit('login-fail', 10, interval '10 minutes') then raise exception 'rate_limited'; end if;
  select pass_hash into v_hash from fd_admin where id = 1;
  if v_hash is null then raise exception 'no_admin_password'; end if;
  if crypt(coalesce(p_pass,''), v_hash) <> v_hash then
    perform fd_hit('login-fail', 10, interval '10 minutes');
    perform pg_sleep(0.7);
    raise exception 'bad_password';
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into fd_sessions(token_hash, expires_at) values (encode(digest(v_token,'sha256'),'hex'), now() + interval '12 hours');
  return v_token;
end $$;

create or replace function public.fd_admin_logout(p_token text) returns void
language sql security definer set search_path = public, extensions as $$
  delete from fd_sessions where token_hash = encode(digest(coalesce(p_token,''),'sha256'),'hex')
$$;

create or replace function public.fd_admin_list(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform fd_check_token(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'status', status, 'data', data, 'anonymous', code is not null) order by created_at)
                   from fd_inquiries), '[]'::jsonb);
end $$;

create or replace function public.fd_admin_save(p_token text, p_id text, p_data jsonb, p_status text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform fd_check_token(p_token);
  update fd_inquiries
     set data = p_data - 'demo', status = p_status, updated_at = now(),
         closed_at = case when p_status = 'closed' then coalesce(closed_at, now()) else null end
   where id = p_id;
  return found;
end $$;

create or replace function public.fd_admin_delete(p_token text, p_id text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform fd_check_token(p_token);
  delete from fd_inquiries where id = p_id;
  return found;
end $$;

create or replace function public.fd_admin_publish(p_token text, p_entry jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform fd_check_token(p_token);
  insert into fd_kb(id, entry) values (p_entry->>'id', p_entry)
    on conflict (id) do update set entry = excluded.entry;
  return true;
end $$;

create or replace function public.fd_admin_unpublish(p_token text, p_id text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform fd_check_token(p_token);
  delete from fd_kb where id = p_id;
  return found;
end $$;

-- הגדרת/החלפת סיסמת המשרתים – רק מתוך ה-SQL Editor (לא נגישה מהאתר)
create or replace function public.fd_set_admin_password(p_pass text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(coalesce(p_pass,'')) < 10 then raise exception 'הסיסמה חייבת להיות באורך 10 תווים לפחות'; end if;
  insert into fd_admin(id, pass_hash) values (1, crypt(p_pass, gen_salt('bf', 10)))
    on conflict (id) do update set pass_hash = excluded.pass_hash;
  delete from fd_sessions;   -- מנתק את כל מי שהיה מחובר
  return 'הסיסמה עודכנה';
end $$;

-- ---------- הרשאות ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.fd_submit(jsonb), public.fd_status(text), public.fd_clarify(text,text), public.fd_delete_mine(text),
  public.fd_kb_list(),
  public.fd_admin_login(text), public.fd_admin_logout(text), public.fd_admin_list(text),
  public.fd_admin_save(text,text,jsonb,text), public.fd_admin_delete(text,text),
  public.fd_admin_publish(text,jsonb), public.fd_admin_unpublish(text,text)
to anon, authenticated;

-- =====================================================================
--  שלב אחרון (חובה): לבחור סיסמה למשרתים. להריץ שורה אחת, עם סיסמה משלכם:
--
--     select fd_set_admin_password('כאן-סיסמה-ארוכה-וחזקה');
--
--  אל תשמרו את הסיסמה בקובץ הזה ואל תעלו אותה לגיטהב.
-- =====================================================================
