// One Supabase client for the whole site. Loaded after the supabase-js UMD build.
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

if (!window.supabase?.createClient) {
  throw new Error("The sign-in library didn't load. Check your connection and reload.");
}

export const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

/** Resolve with the current session, or send the visitor to the sign-in page. */
export async function requireSession() {
  const { data, error } = await supabase.auth.getSession();
  if (error || !data.session) {
    const back = encodeURIComponent(location.pathname + location.search);
    location.replace(`/signin?next=${back}`);
    return new Promise(() => {}); // stop the page while the redirect happens
  }
  return data.session;
}

export async function signOut() {
  await supabase.auth.signOut();
  location.replace("/signin");
}
