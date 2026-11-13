import { supabase } from "./supabase.js";

const form = document.getElementById("signin-form");
const msg = document.getElementById("signin-msg");
const createBtn = document.getElementById("create-account");
const params = new URLSearchParams(location.search);
const next = params.get("next") && params.get("next").startsWith("/") ? params.get("next") : "/";

// Account creation is only offered during first-time setup (?setup=1).
// Sign-ups are switched off in Supabase afterwards, so this button can't create anyone else.
if (params.get("setup") === "1") createBtn.hidden = false;

const say = (text, kind = "info") => { msg.textContent = text; msg.dataset.kind = kind; };

const { data } = await supabase.auth.getSession();
if (data.session) location.replace(next);

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  say("Signing in…");
  const { error } = await supabase.auth.signInWithPassword({
    email: form.email.value.trim(),
    password: form.password.value,
  });
  if (error) return say(error.message === "Invalid login credentials" ? "That email and password don't match." : error.message, "error");
  location.replace(next);
});

createBtn.addEventListener("click", async () => {
  if (!form.reportValidity()) return;
  say("Creating your account…");
  const { data: res, error } = await supabase.auth.signUp({
    email: form.email.value.trim(),
    password: form.password.value,
    options: { emailRedirectTo: `${location.origin}/` },
  });
  if (error) return say(error.message, "error");
  if (res.session) return location.replace("/");
  say("Account created. Check your email for a confirmation link, then sign in here.", "ok");
});
