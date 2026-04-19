// BEEP HQ — Supabase connection config
// Safe to commit: the anon key is designed for public browser use and is protected by Row-Level Security.
// The service_role key (not here) must never be committed.

const SUPABASE_URL = 'https://hceoxzzybzrjeqhwhvxf.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhjZW94enp5YnpyamVxaHdodnhmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY1NDYxODAsImV4cCI6MjA5MjEyMjE4MH0.gQDw8wuDmVnHUTzGo43_9c8_fgqYiyN6soPPC67ywFY';

// Client is initialized lazily in index.html once the Supabase UMD bundle loads.
window.BEEP_SUPABASE_CONFIG = { url: SUPABASE_URL, anonKey: SUPABASE_ANON_KEY };
