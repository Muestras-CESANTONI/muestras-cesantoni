// Public configuration (safe to publish: the publishable/anon key only allows what the database permits).
// NEVER put the service_role / secret key here.
window.SAMPLES_CONFIG = {
  supabaseUrl: 'https://wetjwphgdcjcukuwlfwl.supabase.co',
  anonKey: '',   // ← Supabase › Project Settings › API Keys › publishable (sb_publishable_…) or anon public (eyJ…)
  submitUrl: 'https://wetjwphgdcjcukuwlfwl.supabase.co/functions/v1/submit-request',
  basePath: '/'
};
