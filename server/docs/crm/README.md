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
| `1100_modules.yaml` | Data model (11 modules) |
| `1200_charts.yaml` | 15 report charts |
| `1400_pages.yaml` | Navigation, list/record pages, pipeline board, dashboards |
| `1600_workflows.yaml` | 11 automation flows |

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

## Known limitations and caveats

- **Not yet run.** This package was written against the Corteza source in this
  repo (envoy decoders, page and workflow formats) but hasn't been imported
  into a running instance. Import it on a test database first and check the
  server log for decoder or validation errors.
- Probability is driven by stage. Manual edits are overwritten on save.
- `crm_lead_followup` uses a 3-day delay step. Delayed workflow sessions are
  held by the server, so check how your deployment handles restarts during
  the delay.
- A send failure on one recipient (e.g. SMTP rejects the address) stops the
  `crm_campaign_send` run. Recipients already marked Sent stay Sent, and
  clicking Send again continues with the remaining Queued ones.
- `crm-user` can execute all workflows. Narrow
  `corteza::automation:workflow/*` to specific workflows if needed.
