# كاليندر كنيسة السيدة العذراء والقديس أثناسيوس - دار السلام

موقع ثابت (index.html + config.js) وقاعدة بيانات على Supabase.

1. أنشئ مشروع على supabase.com.
2. SQL Editor: شغّل `schema.sql` وبعده `seed.sql`.
3. Authentication ← Users ← Add user: أنشئ حساب لكل مشرف (إيميل وكلمة سر).
4. SQL Editor: ضيف المشرفين:
   insert into public.admins (user_id) select id from auth.users where email in ('admin@example.com');
5. Project Settings ← API: انسخ Project URL و anon key في `config.js`.
6. ارفع الفولدر على GitHub (Pages) أو على أي سيرفر ملفات ثابتة.
