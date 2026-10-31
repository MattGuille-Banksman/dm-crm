# CRM + Email Marketing foundation

A HubSpot-style CRM built as a provisioned Corteza extension: contacts,
companies, a deal pipeline, an activity timeline, email campaigns, workflow
automation and reporting dashboards. It runs entirely on Corteza's own
building blocks: Compose (data model, UI, charts), Automation (node-based
workflows) and the REST API. No platform code is modified.

Source: [`server/provision/750_crm/`](../../provision/750_crm)

| File | Contents |
| --- | --- |
| `1000_namespace.yaml` | `crm` namespace |
| `1050_access_control.yaml` | `crm-user` role and its permissions |
| `1100_modules.yaml` | Data model (13 modules) |
| `1200_charts.yaml` | 15 report charts |
| `1400_pages.yaml` | Navigation, list/record pages, pipeline board, dashboards |
| `1600_workflows.yaml` | 18 automation flows |
| `1700_settings.yaml` | DM-CRM logos and login page style (themes and the column-resize snippet: `branding/tools/apply-branding-settings.sh`) |

## Install

**Fresh database.** Corteza provisions everything under `provision/*` on its
first boot, so the CRM is created automatically.

**Existing instance.** Boot-time provisioning only re-imports a few base
folders on an already-provisioned database, so import the package once:

```bash
corteza-server import provision/750_crm
```

Conflicting resources are skipped, so re-running the import is safe.

After installing:

1. Add your users to the **CRM user** role (Admin Area > Roles, or
   `corteza-server roles useradd crm-user <email>`).
2. Open the **CRM** namespace, go to **Settings** and click
   **Create default deal stages**.
3. Configure SMTP (`SMTP_HOST`, `SMTP_FROM`, ...) before sending campaigns.

> The official `corteza-ext` CRM (`provision/update.sh`, folder `700_crm`)
> also uses the `crm` namespace slug. Don't install both.

## Domain model

Every entity is a Compose module. Records get snowflake IDs,
created/updated/deleted timestamps, soft delete, revisions, RBAC and a REST
API without extra code. Record values are stored as JSON per record, and each
core entity has a `properties` field for tenant-specific JSON attributes.

| Requested entity | Implementation | Key relations |
| --- | --- | --- |
| Contact | module `Contact` | `company` → Company |
| (contact_addresses) | module `ContactAddress` | `contact` → Contact |
| Company | module `Company` | |
| Deal | module `Deal` | `contact` → Contact, `company` → Company |
| DealStage | module `DealStage` (reference data) | |
| Activity | module `Activity` (email, call, meeting, task, note) | contact, company, deal |
| Note | module `Note` | contact, company, deal |
| EmailTemplate | module `EmailTemplate` | |
| EmailCampaign | module `EmailCampaign` | `template` → EmailTemplate |
| CampaignRecipient | module `CampaignRecipient` | campaign, contact |
| AutomationFlow | Corteza **workflow** | |
| AutomationNode | workflow **step** (trigger, gateway, expression, function, delay, iterator, prompt...) | |
| AutomationEdge | workflow **path** (with optional condition expression) | |
| AutomationRun | workflow **session** (engine-level trace) + module `AutomationRun` (business-level log for reporting) | contact, deal, campaign |

Flows, nodes and edges are deliberately not duplicated as modules. Corteza's
workflow engine already stores them, and its Workflows app is the flowchart
editor. Every provisioned flow ships with layout metadata, so it opens as an
editable diagram.

### Pipeline

`Deal.stage` is a select field (New, Qualified, Proposal, Negotiation, Won,
Lost). Keeping it a select lets the **Pipeline** page group deals into kanban
columns, and dragging a card changes its stage. The `DealStage` module holds
stage metadata (order, probability, closed/won flags) for reporting and
configuration. Keep its names in sync with the select options.

## Automation flows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `crm_deal_stage_rules` | Deal before create/update | Probability from stage (10/20/40/60/100/0 %), weighted amount, closed/won flags, `closed_at` |
| `crm_contact_defaults` | Contact before create/update | Builds `full_name`, defaults lifecycle stage to Lead, stamps `unsubscribed_at` |
| `crm_deal_won` | Deal after update | On transition to Won, sets contact and company lifecycle stage to Customer; logs a run |
| `crm_lead_followup` | Contact after create | Creates a follow-up task, **waits 3 days**, creates a second task if the first is still open; logs a run |
| `crm_activity_touch` | Activity after create | Updates `last_activity_at` on the contact and company |
| `crm_campaign_build_recipients` | Button on campaign | Iterates contacts matching `audience_query`, queues a CampaignRecipient per mailable contact |
| `crm_campaign_send` | Button on campaign | Renders merge tags, sends one email per queued recipient, marks Sent/Skipped, updates the campaign |
| `crm_campaign_refresh_stats` | Button on campaign | Recounts sent/opened/clicked/bounced/unsubscribed onto the campaign |
| `crm_recipient_engagement` | CampaignRecipient before update | Stamps engagement timestamps and counters on status change; Unsubscribed also opts the contact out |
| `crm_deal_won_webhook` | Deal after update (**disabled**) | API call node: POSTs the won deal as JSON to an external URL |
| `crm_setup_default_stages` | Button on Settings | Creates the six default DealStage records if none exist |

Between them these cover the requested node types: triggers (record events
and manual buttons), conditions (exclusive gateways with expressions),
branching, delays, API calls (`httpRequestSend`), and actions (record create,
update and lookup, email send, user notifications).

To enable the webhook, open it in the Workflows app, set the URL on the
**POST to webhook** step and enable the workflow.

## Email campaigns

1. Create an **Email template**. Subject and bodies support `{{first_name}}`,
   `{{last_name}}`, `{{full_name}}` and `{{email}}`.
2. Create a **campaign**, pick the template and set the **Audience filter**.
   This is a Compose record query over Contact, e.g.
   `lifecycle_stage = 'Lead' AND lead_source = 'Event'`.
3. Click **1. Build recipient list**. Opted-out contacts and contacts without
   an email address are left out.
4. Review the recipients, then click **2. Send campaign**.

Emails go out through Corteza's SMTP settings, with `SMTP_FROM` as the
sender. The campaign's from/reply-to fields are informational for now.

### Engagement tracking (opened, clicked, bounced, unsubscribed)

Status changes on a recipient drive the rest: `crm_recipient_engagement`
stamps the timestamps and counters, and an unsubscribe also opts the contact
out of marketing email. An ESP webhook or tracking service only needs to
update the recipient's `status` through the Compose REST API:

```
PATCH /api/compose/namespace/{namespaceID}/module/{CampaignRecipient moduleID}/record/{recordID}
Authorization: Bearer <token of an auth client / service user with CRM user role>
Content-Type: application/json

{ "values": [ { "name": "status", "value": "Opened" } ] }
```

There's no built-in open pixel or click redirect. Corteza's integration
gateway doesn't pass query parameters through to workflows, so those
endpoints are the one piece that needs a small Go service or an external
tracker (most ESPs already provide webhooks). That's the recommended next
step.

## Lists (segments)

**Contacts > Lists** works like HubSpot lists:

- **Active** lists update automatically. A contact is in the list while it
  matches the filter.
- **Static** lists are a fixed set of contacts (module `SegmentMember`).
  **Save snapshot** adds everyone currently matching the filter (no
  duplicates); you can also add or remove members by hand.

A filter is a Compose record query over Contact. The list page has a cheat
sheet. Examples:

```
lifecycle_stage IN ('MQL', 'SQL') AND lead_source = 'Event'
emails_sent_count > 3 AND NOT (emails_opened_count > 0)
open_deals_count > 0 AND last_activity_at < DATE_SUB(NOW(), INTERVAL 30 DAY)
```

To make engagement and deal filters possible, workflows keep these contact
fields up to date: deals, open deals, won deals, open pipeline value, won
revenue, marketing emails sent / opened / clicked, and last open and click
time. Pick a list as a campaign's **Audience segment**. The optional
**Extra audience filter** narrows it further.

## Email intelligence

When a contact is created or saved, `crm_contact_defaults` reads the email
address:

- `jane.doe@brightwidgets.co.uk` fills First name *Jane*, Last name *Doe*
  (only when both are empty), and Email domain *brightwidgets.co.uk*.
- The contact is linked to the company whose **Email domain** matches. If
  there isn't one, a company is created (named from the domain, e.g.
  *Brightwidgets*, with its website set).
- Free webmail domains (gmail, outlook, hotmail...) don't create companies,
  and generic inboxes (info@, sales@, accounts@...) don't produce names.

Company email domains are filled from the website automatically
(`crm_company_defaults`). For contacts that existed before, use **Settings >
Enrich existing contacts from email**.

Contacts imported from CSV skip record workflows, so `crm_contacts_tidy_imports`
runs every 5 minutes (as the admin, `run_as`) and re-saves contacts that have
an email but no email domain yet. Imported contacts are therefore named,
linked to their company and given an owner within a few minutes.

## HTML email templates

The template's **HTML code** field is a plain code box: paste your full email
HTML there. The **Preview** panel next to it renders the HTML in an isolated
frame; it refreshes when you save.

## AI campaign content

**Generate content with AI** on a campaign (`crm_campaign_generate_content`)
sends the brief (about, key messages, keywords, call to action, writing
style, channels) to the Claude API and saves the draft, as HTML, in
**Generated content**. It drafts one section per selected channel.

- An administrator adds the Anthropic API key once, under Settings > AI
  settings (key from console.anthropic.com). Model (Opus 5.5 or Sonnet 5.5)
  and effort are chosen there too.
- AI settings are admin-only: CRM users get per-module permissions that leave
  the module out, and signed-in users are denied it with SQL in
  `update-existing-crm.sh`, because the importer can't resolve the built-in
  `authenticated` role. The workflow runs as the admin (`run_as`, also set by
  the script) so CRM users can still use the button.
- Cost is roughly 5p per draft on Opus 5.5 and about half that on Sonnet 5.5.
  Set a monthly spend limit in the Anthropic console.

## Resizable columns

Every record list supports drag-to-resize columns: drag the right edge of a
column header, and double-click the edge to reset it. Widths are remembered
per page in each browser. This is `branding/column-resize.js`, loaded on
every web app through a Corteza **Code snippet** (Admin Area > Code
snippets).

## Page builder

The **Page builder** (sidebar **Admin** menu > Page builder) on CRM pages is Corteza's layout editor: it
moves and resizes the boxes (blocks), adds new ones (lists, charts, metrics,
buttons) and configures them. Only users who may edit pages see it.
Administrators do; members of the **CRM user** role don't. Keep it for
administrators to adjust the CRM without code.

## Reporting

| Page | Charts |
| --- | --- |
| Home | Open pipeline, weighted forecast, won this year, new leads (30 days); my tasks and deals |
| Reports > Pipeline revenue | Pipeline by stage, deal funnel, forecast by close month, won revenue by month, won vs lost |
| Reports > Lead conversion | Contacts by lifecycle stage (funnel), by lead source, new contacts per month, customers by source |
| Reports > Email engagement | Recipients by status, emails sent per month, engagement by campaign |
| Reports > Automation performance | Runs by workflow, results, runs per day (from the AutomationRun log) |

Engine-level detail for every run (step trace, errors, duration) is also
available in the Workflows app under each workflow's **Sessions**.

## API

Every module is available over the Compose REST API (list, filter, create,
update, delete records) under `/api/compose/namespace/{id}/module/{id}/record`.
Workflows can be executed over `/api/automation/workflows/{id}/exec`. Use an
auth client with a service user in the **CRM user** role for integrations.

## Updating an existing instance

Boot-time provisioning only installs the CRM on an empty database, and
`corteza-server import --replace-existing` isn't safe on an instance that
already has it. Corteza's importer has three problems:

- it matches existing module fields by name across *all* modules, so it can
  move fields such as `owner` or `name` from one module to another;
- it re-creates workflow triggers on every import (duplicate triggers run
  workflows several times);
- it doesn't see disabled workflows, so importing one again fails as a
  duplicate;
- it overwrites existing *settings* even with `--skip-existing`, and turns
  list values (themes, code snippets) into empty lists. `1700_settings.yaml`
  therefore only holds plain values; the colour themes and the column-resize
  snippet are set by `branding/tools/apply-branding-settings.sh`. Run it once
  on a fresh install too; it only fills settings that are empty, so pass
  `--force` to reset them to the DM-CRM defaults.

Use the update script instead. Take a backup first:

```bash
docker compose exec -T db pg_dump -U corteza -d corteza -Fc > backups/corteza-before-update.dump
```

```bash
bash branding/tools/update-existing-crm.sh corteza-server-1 corteza http://localhost:18080 you@example.com
```

It applies module changes through the REST API
(`apply-crm-module-changes.ps1`, which only adds fields and options), then
imports a package (`prepare-crm-update.sh`) that skips modules, fields and
unchanged workflows and replaces only the pages and workflows listed in the
script. It's safe to run more than once. When you change other pages or
workflows, add them to the lists at the top of `update-existing-crm.sh`, and
add new module fields to `apply-crm-module-changes.ps1`.

Records imported without an owner (owner 0) can't be saved by anyone, admins
included, until they have one. After a CSV import, set an owner, e.g.:

```sql
update compose_record set owned_by = <user id> where owned_by = 0 and rel_namespace = <crm namespace id>;
```

## Known limitations and caveats

- The segment, email intelligence, template preview and rollup workflows were
  tested end to end against a copy of a live database. Campaign sending and
  the follow-up delay haven't been exercised with a real SMTP server yet.
- Workflow expressions can't index a function call directly
  (`split(x, "@")[0]` doesn't parse): assign the result to a variable first.
  Don't name variables after built-in functions (`count`, `sum`, `filter`...).
- Contact rollups update when deals or campaign recipients change. Contacts
  with no deals or emails yet have empty values, so filter with
  `deals_count IS NULL` rather than `deals_count = 0`.
- Company names created from email domains have no spaces
  (`midstreamlighting.com` gives *Midstreamlighting*). Rename them as needed.
- Probability is driven by stage. Manual edits are overwritten on save.
- `crm_lead_followup` uses a 3-day delay step. Delayed workflow sessions are
  held by the server, so check how your deployment handles restarts during
  the delay.
- A send failure on one recipient (e.g. SMTP rejects the address) stops the
  `crm_campaign_send` run. Recipients already marked Sent stay Sent, and
  clicking Send again continues with the remaining Queued ones.
- `crm-user` can execute all workflows. Narrow
  `corteza::automation:workflow/*` to specific workflows if needed.

## Web app changes (compose)

The compose web app is built from `client/web/compose` in the image
(`deploy/oracle/Dockerfile`); the other web apps come from the release. The
DM-CRM changes are marked `DM-CRM` in the source:

- `components/Common/Grid.vue`: on viewed pages, blocks grow to fit their
  content instead of scrolling, and the blocks below move down. The page
  builder still shows and saves the stored sizes.
- `components/Namespaces/NamespaceSidebar.vue` and
  `views/Public/Pages/View.vue`, `views/Public/Pages/Records/View.vue`: the
  page builder, page settings and module editor links moved from the top
  bar into the sidebar's **Admin** menu.
- `views/Admin/Charts/Edit.vue`, `components/Chart/Report/ReportEdit.vue` and
  `GenericChart.vue`: the chart editor shows the essentials (name, module,
  preset filter, group by, metric, chart type) with a live preview; handle,
  colours, animation, custom filter, axis, legend, formatting and toolbox
  options are behind **Advanced settings** (remembered per browser). Elements
  marked `dmcrm-advanced` are the ones it hides.
- The admin sidebar no longer lists every chart; the Charts page does.

The look (Userflow-style: Figtree type, white cards with large rounded
corners, pill buttons, indigo-tinted navigation and badges, the inline-edit
pencil shown on hover, slimmed narrow lists) is `branding/dm-crm-ui.scss`,
applied as the general custom CSS by `apply-branding-settings.sh`, which
also adds the "DM-CRM font (Figtree)" code snippet that loads the font from
Google Fonts. The update script applies it to the container it updates
(`BRANDING_CONTAINER`), so rehearsals get it too.

## Pipeline board

The Pipeline page is a board of Record organizer blocks, one per deal stage.
`components/PageBlocks/RecordOrganizerBase.vue` carries DM-CRM additions,
driven by block options:

- `cardFields`: extra fields shown on each card as small "label value" rows
  (amount, company, contact, close date, owner), like HubSpot's deal cards.
- `totalField`, `weightedField`, `totalPrefix`: the column header shows the
  number of deals, their total and the weighted total.
- Dragging a card to another column saves the deal normally (when the block
  has no position field), so `crm_deal_stage_rules` and the other deal
  workflows run; Corteza's own "organize" action skips them.
- The compact **+** in each column creates a deal already in that stage.

Deals don't need a name: `crm_deal_auto_name` names an unnamed deal after
its company or primary contact (e.g. "Brightwidgets deal"), or "New deal" and
the date.

Top-level pages have line icons (`branding/icons/*.svg`) set through the page
`config.navitem.icon`.
