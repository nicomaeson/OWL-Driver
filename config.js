// Owl Driver: connection to the shared Supabase database.
// Both values come from Supabase: Project Settings -> API (or "Connect").
// The anon key is designed to be public; the database only allows the
// actions defined in supabase-setup.sql. Never put the service_role key here.
window.OWL_DRIVER_CONFIG = {
  supabaseUrl: "YOUR_SUPABASE_URL",
  supabaseAnonKey: "YOUR_SUPABASE_ANON_KEY"
};
