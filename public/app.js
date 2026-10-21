/* GameHub — a tiny party-game platform on pure HTML/JS/CSS + Supabase.
   No build step, no backend server: Row-Level Security in Postgres is the backend. */
(() => {
  "use strict";
  const cfg = window.GAMEHUB_CONFIG || {};
  const app = document.getElementById("app");
  const nav = document.getElementById("navlinks");
  const configured = cfg.SUPABASE_URL && !cfg.SUPABASE_URL.includes("YOUR-PROJECT") && cfg.SUPABASE_ANON_KEY && !cfg.SUPABASE_ANON_KEY.includes("YOUR-ANON");
  const db = configured ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;

  let user = null;
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const slugify = s => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "game";
  const go = hash => { location.hash = hash; };
  const setHTML = html => { app.innerHTML = html; };

  function renderNav() {
    if (!configured) { nav.innerHTML = ""; return; }
    nav.innerHTML = user
      ? `<a href="#/">Marketplace</a><a href="#/dev">My games</a><a href="#" id="logout">Log out</a>`
      : `<a href="#/">Marketplace</a><a href="#/login">Developer login</a>`;
    const lo = document.getElementById("logout");
    if (lo) lo.onclick = async e => { e.preventDefault(); await db.auth.signOut(); user = null; renderNav(); go("#/"); };
  }

  /* ---------------------------------------------------------------- views */
  function notConfigured() {
    setHTML(`<div class="banner"><strong>Almost there.</strong> Edit <code>public/config.js</code> with your Supabase
      <code>SUPABASE_URL</code> and <code>SUPABASE_ANON_KEY</code> (Dashboard → Project Settings → API), and run
      <code>supabase/schema.sql</code> once in the SQL editor. Reload and the platform comes alive.</div>
      <p class="muted">Both values are safe to ship in frontend code — the anon key is public and gated by Row-Level Security.</p>`);
  }

  async function viewMarketplace() {
    setHTML(`<div class="row between"><h1>Browse games</h1>${user ? `<a class="btn sm" href="#/new">+ New game</a>` : ""}</div>
      <p class="muted">Party games you can share and play. Published by developers on GameHub.</p>
      <div id="list" class="grid" style="margin-top:16px"><p class="muted">Loading games…</p></div>`);
    const { data, error } = await db.from("games").select("slug,title,tagline,plays").eq("status", "published").order("created_at", { ascending: false });
    const list = document.getElementById("list");
    if (error) { list.innerHTML = `<p class="err">${esc(error.message)}</p>`; return; }
    if (!data.length) { list.innerHTML = `<div class="card"><p class="muted">No published games yet. ${user ? `<a href="#/new">Create the first one.</a>` : `Log in as a developer to add one.`}</p></div>`; return; }
    list.innerHTML = data.map(g => `<a class="card gamecard" href="#/game/${esc(g.slug)}">
      <h3>${esc(g.title)}</h3><p class="small muted">${esc(g.tagline || "")}</p>
      <p class="small muted" style="margin-top:8px">▶ ${g.plays} plays</p></a>`).join("");
  }

  function authView(mode) {
    const login = mode === "login";
    setHTML(`<div class="form card">
      <h1>${login ? "Developer login" : "Create a developer account"}</h1>
      <p class="muted small">${login ? "Sign in to manage your games." : "Sign up to publish games on GameHub. Free tier."}</p>
      <div id="msg"></div>
      <label>Email</label><input id="email" type="email" autocomplete="email">
      <label>Password</label><input id="pw" type="password" autocomplete="${login ? "current-password" : "new-password"}">
      <div class="row" style="margin-top:14px">
        <button id="submit">${login ? "Log in" : "Sign up"}</button>
        <a class="small" href="#/${login ? "signup" : "login"}">${login ? "Need an account? Sign up" : "Have an account? Log in"}</a>
      </div></div>`);
    const msg = document.getElementById("msg");
    document.getElementById("submit").onclick = async () => {
      const email = document.getElementById("email").value.trim();
      const password = document.getElementById("pw").value;
      if (!email || !password) { msg.innerHTML = `<p class="err">Email and password required.</p>`; return; }
      msg.innerHTML = `<p class="muted">Working…</p>`;
      const fn = login ? db.auth.signInWithPassword({ email, password }) : db.auth.signUp({ email, password });
      const { data, error } = await fn;
      if (error) { msg.innerHTML = `<p class="err">${esc(error.message)}</p>`; return; }
      if (!login && !data.session) { msg.innerHTML = `<p class="ok">Account created. Check your email to confirm, then log in.</p>`; return; }
      user = data.user; renderNav(); go("#/dev");
    };
  }

  async function viewDev() {
    if (!user) return go("#/login");
    setHTML(`<div class="row between"><h1>My games</h1><a class="btn" href="#/new">+ New game</a></div>
      <div id="mine" class="stack" style="margin-top:16px"><p class="muted">Loading…</p></div>`);
    const { data, error } = await db.from("games").select("*").eq("owner", user.id).order("created_at", { ascending: false });
    const box = document.getElementById("mine");
    if (error) { box.innerHTML = `<p class="err">${esc(error.message)}</p>`; return; }
    if (!data.length) { box.innerHTML = `<div class="card"><p class="muted">No games yet. <a href="#/new">Create your first game.</a></p></div>`; return; }
    box.innerHTML = data.map(g => `<div class="card"><div class="row between">
      <div><h3>${esc(g.title)}</h3><p class="small muted">/${esc(g.slug)} · ${g.plays} plays</p></div>
      <div class="row"><span class="pill ${g.status === "published" ? "live" : "draft"}">${g.status}</span>
        <a class="btn ghost sm" href="#/edit/${g.id}">Edit</a>
        ${g.status === "published" ? `<a class="btn ghost sm" href="#/game/${esc(g.slug)}">View</a>` : ""}</div>
      </div></div>`).join("");
  }

  function gameForm(existing) {
    const g = existing || { title: "", tagline: "", description: "", status: "draft" };
    return `<label>Title</label><input id="title" value="${esc(g.title)}" maxlength="60">
      <label>Tagline <span class="muted">(one line)</span></label><input id="tagline" value="${esc(g.tagline)}" maxlength="120">
      <label>Description</label><textarea id="description" rows="5" maxlength="2000">${esc(g.description)}</textarea>`;
  }

  function viewNew() {
    if (!user) return go("#/login");
    setHTML(`<div class="form card"><h1>New game</h1><div id="msg"></div>${gameForm()}
      <div class="row" style="margin-top:14px"><button id="save">Create</button><a class="btn ghost" href="#/dev">Cancel</a></div></div>`);
    document.getElementById("save").onclick = async () => {
      const title = document.getElementById("title").value.trim();
      if (!title) { document.getElementById("msg").innerHTML = `<p class="err">Title required.</p>`; return; }
      const slug = slugify(title) + "-" + Math.random().toString(36).slice(2, 6);
      const row = { slug, title, tagline: document.getElementById("tagline").value.trim(), description: document.getElementById("description").value.trim() };
      const { data, error } = await db.from("games").insert(row).select("id").single();
      if (error) { document.getElementById("msg").innerHTML = `<p class="err">${esc(error.message)}</p>`; return; }
      go("#/edit/" + data.id);
    };
  }

  async function viewEdit(id) {
    if (!user) return go("#/login");
    const { data: g, error } = await db.from("games").select("*").eq("id", id).single();
    if (error || !g) { setHTML(`<p class="err">${esc(error?.message || "Game not found.")}</p>`); return; }
    setHTML(`<div class="form card"><div class="row between"><h1>Edit game</h1>
        <span class="pill ${g.status === "published" ? "live" : "draft"}">${g.status}</span></div>
      <div id="msg"></div>${gameForm(g)}
      <div class="row" style="margin-top:14px">
        <button id="save">Save</button>
        <button id="pub" class="ghost btn">${g.status === "published" ? "Unpublish" : "Publish"}</button>
        <a class="btn ghost" href="#/dev">Back</a>
        <button id="del" class="btn danger sm" style="margin-left:auto">Delete</button>
      </div>
      <p class="small muted" style="margin-top:12px">Public link: <code>#/game/${esc(g.slug)}</code></p></div>`);
    const msg = document.getElementById("msg");
    const patch = async fields => {
      const { error } = await db.from("games").update({ ...fields, updated_at: new Date().toISOString() }).eq("id", id);
      if (error) { msg.innerHTML = `<p class="err">${esc(error.message)}</p>`; return false; }
      return true;
    };
    document.getElementById("save").onclick = async () => {
      if (await patch({ title: document.getElementById("title").value.trim(), tagline: document.getElementById("tagline").value.trim(), description: document.getElementById("description").value.trim() }))
        msg.innerHTML = `<p class="ok">Saved.</p>`;
    };
    document.getElementById("pub").onclick = async () => {
      if (await patch({ status: g.status === "published" ? "draft" : "published" })) viewEdit(id);
    };
    document.getElementById("del").onclick = async () => {
      if (!confirmInline()) return;
      const { error } = await db.from("games").delete().eq("id", id);
      if (error) { msg.innerHTML = `<p class="err">${esc(error.message)}</p>`; return; }
      go("#/dev");
    };
  }
  let armedDelete = false;
  function confirmInline() {
    const b = document.getElementById("del");
    if (!armedDelete) { armedDelete = true; b.textContent = "Tap again to delete"; setTimeout(() => { armedDelete = false; if (b) b.textContent = "Delete"; }, 3000); return false; }
    return true;
  }

  async function viewGame(slug) {
    setHTML(`<p class="muted">Loading…</p>`);
    const { data: g, error } = await db.from("games").select("*").eq("slug", slug).single();
    if (error || !g) { setHTML(`<div class="card"><p class="err">Game not found or not published.</p><a href="#/">Back to marketplace</a></div>`); return; }
    db.rpc("increment_play", { game_slug: slug });
    setHTML(`<a class="small muted" href="#/">← Marketplace</a>
      <div class="card" style="margin-top:12px">
        <div class="row between"><h1>${esc(g.title)}</h1><span class="pill live">${g.plays + 1} plays</span></div>
        <p class="muted">${esc(g.tagline)}</p>
        <p style="white-space:pre-wrap;margin-top:10px">${esc(g.description) || "<span class='muted'>No description.</span>"}</p>
      </div>
      <div class="card" style="margin-top:14px">
        <h3>Play</h3>
        <p class="muted small">The live multiplayer runtime (lobby, realtime chat, scoring) plugs in here next —
        this is the platform skeleton. Each game's runtime will read its settings from the game's <code>config</code>.</p>
        <button disabled>Create a room (coming next)</button>
      </div>`);
  }

  /* ---------------------------------------------------------------- router */
  function route() {
    if (!configured) return notConfigured();
    const h = location.hash || "#/";
    const [, path, arg] = h.match(/^#\/([^/]*)\/?(.*)$/) || [, "", ""];
    if (path === "") return viewMarketplace();
    if (path === "login") return authView("login");
    if (path === "signup") return authView("signup");
    if (path === "dev") return viewDev();
    if (path === "new") return viewNew();
    if (path === "edit") return viewEdit(arg);
    if (path === "game") return viewGame(arg);
    setHTML(`<p class="muted">Page not found. <a href="#/">Home</a></p>`);
  }

  /* ---------------------------------------------------------------- boot */
  async function boot() {
    if (!configured) { renderNav(); route(); return; }
    const { data } = await db.auth.getSession();
    user = data.session?.user || null;
    db.auth.onAuthStateChange((_e, session) => { user = session?.user || null; renderNav(); });
    renderNav();
    window.addEventListener("hashchange", route);
    route();
  }
  boot();
})();
