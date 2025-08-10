# Pickup System

This folder is ready to deploy via **GitHub Pages** for the web portals.
- Employee: `employee.html`
- Driver: `driver.html`
- Shared: `styles.css`, `config.js`

Admin is a Python GUI (not hosted on Pages).

## Configure
We already injected your Supabase details:
- URL: https://ikmahnxtovwhjppuzdpx.supabase.co
- Anon key: (public) embedded in `config.js`

## Publish to GitHub Pages (from iPad)
1. Create a new repo on GitHub named `pickup-system` (or any name).

2. Upload these files to the root of the repo:
   - `index.html`, `employee.html`, `driver.html`, `styles.css`, `config.js`

3. In the repo settings → **Pages** → Source: **Deploy from a branch** → branch: **main** → `/ (root)`.

4. Wait 1–2 minutes. The site becomes available at `https://<your-username>.github.io/<repo-name>/`.

## Database
Run `supabase_schema.sql` in your Supabase SQL Editor to create/replace the needed functions (helpers, RPCs). Make sure the base tables and RLS policies from earlier setup exist.

