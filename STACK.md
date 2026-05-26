# Orbit stack — GitHub + Supabase + deploy scripts

Three layers. Only the **middle** lives in git; the **database** is remote; **secrets** stay out of git.

```
┌─────────────────────────────────────────────────────────────┐
│  GitHub (orbit_systems)                                     │
│  • orbit-phase1/2/3 SQL (source of truth, reviewable)       │
│  • orbit-tools/manifest.json + run-orbit.ps1                │
│  • supabase/config.toml (project ref, no DB password)         │
└───────────────────────────┬─────────────────────────────────┘
                            │ clone / CI checkout
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Operator machine or GitHub Actions                         │
│  • ORBIT_DATABASE_URL in .env (gitignored)                  │
│  • OR supabase link + ORBIT_USE_SUPABASE_CLI=1              │
└───────────────────────────┬─────────────────────────────────┘
                            │ run-orbit.ps1 / supabase db execute
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Supabase Postgres (your project)                           │
│  • Auth (auth.users)                                        │
│  • Schema + RLS + triggers from phase SQL                   │
└─────────────────────────────────────────────────────────────┘
```

End-user apps (Lovable / FlutterFlow) talk to Supabase with **anon key + user JWT** — they never run `run-orbit.ps1`.

---

## Step 1 — One-time: clone and populate repo

```powershell
cd $env:USERPROFILE\OneDrive\Documents
git clone https://github.com/howardcooper-tech/orbit_systems.git orbit-systems
cd orbit-systems
.\scripts\Sync-From-Documents.ps1
```

If you already have `orbit-systems` with this scaffold, run sync from `Documents` parent so `orbit-phase*` and `orbit-tools` copy in.

Open **this folder** in Cursor (File → Open Folder → `orbit-systems`), not all of `Documents`.

---

## Step 2 — Link Supabase CLI to your project

Install CLI: https://supabase.com/docs/guides/cli

```powershell
cd orbit-systems
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

`YOUR_PROJECT_REF` = Supabase Dashboard → Project Settings → General → Reference ID.

That writes `project_id` into `supabase/config.toml` (safe to commit).

---

## Step 3 — Operator database URL (gitignored)

Supabase → **Project Settings → Database → Connection string (URI)** (postgres role).

```powershell
copy orbit-tools\.env.example orbit-tools\.env
# Edit orbit-tools\.env — set ORBIT_DATABASE_URL=postgresql://...
```

Alternative: in `.env` set `ORBIT_USE_SUPABASE_CLI=1` and use `supabase link` only (no URL in file).

---

## Step 4 — Deploy schema to linked DB

Preview:

```powershell
.\orbit-tools\run-orbit.ps1 -Phase all -DryRun
```

Apply (example: only Phase 3 if 1–2 already ran in SQL Editor):

```powershell
.\orbit-tools\run-orbit.ps1 -Phase 3
```

Staging reset + full stack:

```powershell
.\orbit-tools\run-orbit.ps1 -Phase all -IncludeSweep -IncludeDevSeed
```

---

## Two ways to apply SQL (pick one primary)

| Method | When to use |
|--------|-------------|
| **orbit-tools** (`manifest.json` + `run-orbit.ps1`) | Matches your Phase 1→2→3 run order; what you used in SQL Editor |
| **Supabase migrations** (`supabase/migrations/*.sql`) | Optional; `supabase db push` for CLI-native workflow |

**Recommendation:** Keep **`orbit-phase*`** as source of truth. Add timestamped files under `supabase/migrations/` only when you want `db push` / branch previews — copy or generate from phase files, don’t maintain two divergent schemas.

---

## Step 5 — Push to GitHub

```powershell
cd orbit-systems
git status
git add .
git commit -m "Add Orbit Atom phased SQL, deploy tools, and Supabase stack docs"
git push -u origin main
```

If remote already has a README commit:

```powershell
git pull origin main --rebase
git push origin main
```

---

## GitHub Actions (optional later)

Repo secret: `ORBIT_DATABASE_URL` (staging CI only).

Workflow runs `run-orbit.sh` on push to `main` — only after you want automated deploy; manual `run-orbit.ps1` is fine for pilot.

---

## What not to put in git

| Item | Where it lives |
|------|----------------|
| Postgres password / full DB URL | `orbit-tools/.env` (local) or GitHub Secrets |
| `service_role` key | Supabase dashboard / app backend only |
| Anon key | Frontend env — public by design, still not in SQL repo unless documented |

---

## Verify after deploy

Run `orbit-phase3/PHASE3_VERIFY.sql` in SQL Editor (when added) or checks in Phase 3 README.

Test API as **authenticated** JWT, not service role.

---

## Operational protocols (markdown)

| Doc | When to read |
|-----|----------------|
| [docs/FIELD_TRIP_15_10_PROTOCOL.md](./docs/FIELD_TRIP_15_10_PROTOCOL.md) | Field trip missing child — 15 min sweep, 10 min Satellite verify, Point notify rules |
| [docs/COMPLIANCE_REGISTRY.md](./docs/COMPLIANCE_REGISTRY.md) | Audit evidence index |

Phase 3b SQL should implement these specs; do not change Phase 1–3 files on production without a migration plan.
