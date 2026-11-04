// Copy to config.js on deploy. These values are PUBLIC by design (anon key + URLs); security is enforced
// by the database (RLS + SECURITY DEFINER functions) and by the Edge Function. Never put the service key here.
window.SAMPLES_CONFIG = {
  supabaseUrl: 'https://<PROJECT_REF>.supabase.co',
  anonKey: '<SUPABASE_ANON_KEY>',
  submitUrl: 'https://<PROJECT_REF>.supabase.co/functions/v1/submit-request',
  basePath: '/'
};
