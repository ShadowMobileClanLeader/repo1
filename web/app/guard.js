// Loaded first on every private page: hides the page until a session exists.
import { requireSession, signOut } from "./supabase.js";

const session = await requireSession();
document.documentElement.dataset.signedIn = "true";
for (const el of document.querySelectorAll("[data-user-email]")) el.textContent = session.user.email;
for (const el of document.querySelectorAll("[data-sign-out]")) el.addEventListener("click", signOut);
window.dispatchEvent(new CustomEvent("session-ready", { detail: session }));
export default session;
