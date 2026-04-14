# Wagger LiveView UI Design Spec

---

## Overview

LiveView UI for the Wagger WAF config generator. Three screens: Dashboard, App Detail, User Management. Tokyo Night theme. Designed around Magic Ink principles — information-first, manipulation-secondary.

## Theme

**Tokyo Night** palette:

| Role | Hex | Usage |
|------|-----|-------|
| Base | `#1a1b26` | Page background |
| Surface | `#292e42` | Cards, panels |
| Surface alt | `#16161e` | Nav bar |
| Border | `#3b4261` | Borders, dividers |
| Border subtle | `#292e42` | Light separators |
| Text primary | `#c0caf5` | Headings, app names |
| Text secondary | `#a9b1d6` | Body text, values |
| Text muted | `#565f89` | Labels, timestamps, inactive |
| Text dim | `#3b4261` | Faintest text |
| Accent | `#7aa2f7` | Brand ("wagger"), path prefixes, links |
| Param | `#bb9af7` | Path parameter placeholders `{id}` |
| GET | `#9ece6a` | GET method pill, "current" status |
| POST | `#7aa2f7` | POST method pill |
| PUT/PATCH | `#e0af68` | PUT method pill, "drifted" status |
| DELETE | `#f7768e` | DELETE method pill, "removed" drift |
| HEAD/OPTIONS | `#565f89` | Less common methods |
| Alert green | `#9ece6a` | Current/healthy state |
| Alert amber | `#e0af68` | Drifted/warning state |
| Alert red | `#f7768e` | Stale/danger state (removals) |
| Neutral | `#565f89` | Never generated |

Font: monospace stack (`JetBrains Mono`, `Fira Code`, system monospace).

## Navigation

Minimal top bar on `#16161e` background:

- Left: **wagger** (accent blue, bold) — links to dashboard
- Center: **Dashboard** | **Users** — plain links, active page highlighted
- Right: username (muted)

No sidebar. Two nav items plus brand. That's it.

## Screen 1: Dashboard

**Purpose:** Answer "is my WAF config out of date?" without any interaction.

### Layout

**Status summary bar** — three clickable cards across the top:

| Card | Color | Content |
|------|-------|---------|
| Drifted | Amber border, amber number | Count of app/provider pairs with drift |
| Current | Green border, green number | Count of app/provider pairs that are current |
| Never Generated | Subtle border, muted number | Count of app/provider pairs never generated |

- Default state: just the summary bar + placeholder text "Click a status above to see affected applications"
- Cards are clickable — selecting one filters the app list below
- Selected card gets a glow/shadow and "showing" indicator; unselected cards dim to 50% opacity

**App cards** — appear below the summary bar when a status is clicked:

- Sorted by severity: most drifted providers first, then by name
- Each card shows: app name (bold), route count, tags, drift detail ("3 providers drifted")
- Provider badges inline: drifted ones in color with change summary ("nginx: -3"), current ones dimmed
- Card border color encodes worst status: red left-border for removals, amber for additions
- Click app name → app detail page
- Click provider badge → app detail page with that provider auto-expanded

### Behavior

- Dashboard loads all drift status on mount (queries all apps × all providers that have snapshots)
- Status counts update live if routes or snapshots change (PubSub on route/snapshot changes)
- No polling — LiveView push on data change

## Screen 2: App Detail

**Purpose:** Everything for one application. Routes, drift, configs, import — all on one page.

### Header

App name (large, bold), route count, tags. Provider status badges in the header row — drifted badges in alert color, current badges subdued.

### Route Display — SwaggerUI Style

Routes displayed as method+path rows, one row per method+path combination. Grouped by common path prefix.

**Group header:** Collapsible. Shows prefix path (accent blue) and endpoint count. Click to collapse/expand.

**Endpoint row:**
- Method pill: colored background (GET green, POST blue, PUT amber, DELETE red), fixed width, centered text
- Path: primary text color, path params `{id}` in purple
- Description: muted, right-aligned
- Rate limit: small pill if present (`100/min`)
- Prefix match label: small muted "prefix" tag if path_type is prefix

Clicking an endpoint row expands inline to show: query_params, headers, path_type, full description. Inline edit controls for methods, rate_limit, tags. This is the manipulation layer — reachable but not prominent.

**Grouping algorithm:** Group by longest common path prefix with at least 2 routes. Routes that don't share a prefix with any other route go in an "other" group.

### Provider Config Sections

Below the route display. One collapsible section per provider that has ever been generated for this app.

**Drifted providers auto-expand.** Current providers stay collapsed.

**Expanded provider section contains:**
- Header: provider name (colored by status) + drift summary + Regenerate/Download buttons
- Config fields: pre-filled from last generation params (last-value defaults). Editable inline.
- Drift diff: added routes in green (`+`), removed in red (`-`), modified with both values. Only shown when drifted.
- Generated config: collapsed by default behind "Show generated config (last: 2h ago, 1.2kb)". Expands to a code block with the full output.

**Collapsed provider section:** One line — provider name, status, timestamp. Click to expand.

**Providers with no snapshots:** Not shown. User generates for a provider by expanding "Generate for new provider..." which shows provider selection.

### Import Section

Collapsed by default — shows "Import routes..." as a clickable bar at the bottom.

**Expanded import contains:**
- Format tabs: Bulk Text | OpenAPI | Access Log
- Textarea for pasting content
- Live preview as you type/paste — parsed routes appear below the textarea
- Conflict indicators: routes that already exist are highlighted
- Confirm button — only interaction needed
- Skipped/error lines shown below preview

### Behavior

- Route tree and provider status load on mount
- Editing a route (methods, rate limit, tags) sends a patch and updates inline — no page reload
- Regenerate calls the generate endpoint, updates the provider section with new output and snapshot
- Import preview parses client-side for instant feedback (bulk text only), server-confirms on submit

## Screen 3: User Management

**Purpose:** Create/delete users, manage API keys.

Simple page:

- Table of users: username, display name, created date
- "Create User" — inline form at top (username, display name). On submit, shows the API key once in a dismissable alert.
- Delete user — confirmation inline, removes row

No roles, no permissions. Any authenticated user can manage others. Kept minimal until the external auth module arrives.

## Screens NOT Built

- No dedicated config view page (merged into app detail)
- No WebAuthn/FIDO2 registration UI (deferred to external auth module)
- No HTTP Message Signature key upload UI (deferred)

## Component Architecture

```
lib/wagger_web/
  live/
    dashboard_live.ex          — status bar + app cards
    app_detail_live.ex         — route display + provider configs + import
    user_live.ex               — user CRUD
  components/
    status_bar.ex              — summary count cards (drifted/current/never)
    app_card.ex                — app summary card for dashboard drill-down
    route_display.ex           — SwaggerUI-style grouped endpoint list
    endpoint_row.ex            — single method+path row with expand
    provider_section.ex        — collapsible provider config with drift/generate
    import_section.ex          — collapsible import with tabs and preview
    drift_diff.ex              — added/removed/modified route display
    theme.ex                   — Tokyo Night color constants and helpers
```

## UI Principles (from original spec)

1. Dashboard-first, not list-first
2. Manipulation is secondary — route editing, import, user management are reachable but not prominent
3. Pre-compute everything — drift status on load, not on click
4. Inline over modal — no modals, no wizards, everything in-context
5. Last-value defaults everywhere — provider config, filter state remembered
6. Progressive disclosure — summary → detail → config → raw output
