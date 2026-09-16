# Connecting ChatSnap to Supabase

1. **Create a project** at https://supabase.com/dashboard (free tier is fine).
   Pick a region near you. The database password it asks for is for direct
   Postgres access — the app never uses it, but keep it somewhere.

2. **Run the schema.** Dashboard → SQL Editor → New query → paste the whole of
   `schema.sql` → Run. It creates the tables, row-level-security policies, the
   `snaps` storage bucket, the sign-up trigger, and the DM helper function.

3. **Turn off email confirmation (for development).** Dashboard → Authentication
   → Providers → Email → uncheck "Confirm email". Otherwise every test account
   needs a real inbox before it can sign in. Turn it back on before you ship.

4. **Copy the keys.** Dashboard → Project Settings → API:
   - Project URL  → `SUPABASE_URL`
   - `anon` `public` key → `SUPABASE_ANON_KEY`

   Paste both into `ChatSnap/Supabase.plist`. The anon key is designed to live
   in client apps; row-level security is what protects the data. The
   `service_role` key is NOT — never put that one in the app.

5. **Rebuild and run.** The "Connect Supabase" screen goes away and onboarding
   asks you to create an account.

## Testing with two people

Sign up on the simulator, then sign up again on your iPhone (or a second
simulator) with a different email. Add each other from the Friends tab and
send a snap — it should land on the other device within a second via the
realtime subscription.
