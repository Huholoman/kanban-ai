#!/usr/bin/env bash
# Builds playground/: a made-up project "Spokes" (bike-service booking app)
# with a filled backlog and fake worktree folders, for trying the CLI, the
# server and the app. Safe to re-run: the old playground is replaced.
#
#   tool/playground.sh            # uses `backlog` from PATH, else `dart run`
#   BACKLOG=/path/to/backlog tool/playground.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
play="$repo/playground"
if [[ -n "${BACKLOG:-}" ]]; then cli=("$BACKLOG")
elif command -v backlog >/dev/null; then cli=(backlog)
else cli=(dart run "$repo/packages/backlog_cli/bin/backlog.dart"); fi

rm -rf "$play"
mkdir -p "$play"/{monorepo,monorepo-2,monorepo-3,monorepo-4,monorepo-5}
for wt in monorepo monorepo-2 monorepo-3 monorepo-4 monorepo-5; do
  echo "Fake worktree of the Spokes code. Run backlog commands from here — ../backlog is found automatically." >"$play/$wt/README.md"
done

cd "$play"
bl() { "${cli[@]}" -C "$play/backlog" "$@"; }
new() { bl --json new "$@" | jq -r .id; }

"${cli[@]}" init backlog --prefix SP >/dev/null
sed -i 's/^milestones: \[\]/milestones:\n  - id: mvp\n    title: MVP for the first workshop\n    due: 2026-12-01\n  - id: launch\n    title: Public launch\n    due: 2027-02-15/' backlog/backlog.yaml

# --- epics -------------------------------------------------------------------
booking=$(new "Online service booking" -t epic -p p0 -m mvp --body '## Goal
Customers pick a time slot and a service type themselves; the workshop sees its load.

Design: [docs/booking.md](../docs/booking.md)')
payments=$(new "Payments and deposits" -t epic -p p1 -m launch)
ops=$(new "Operations and infrastructure" -t epic -p p1 -m mvp -l infra)
web=$(new "Public website" -t epic -p p2 -m launch -l web)

# --- booking -----------------------------------------------------------------
model=$(new "Data model for slots and workshop capacity" -s done -p p0 -m mvp --parent "$booking" -l backend --body '- [x] entities Slot, Workshop, Booking
- [x] migrations
- [x] development seed')
api=$(new "REST API for free slots" -t story -s todo -p p0 -m mvp --parent "$booking" -d "$model" -l backend --body '## Context
The client needs free slots 14 days ahead, per service type.

## Acceptance criteria
- [x] GET /slots?from&to&service
- [ ] respects public holidays and leave of mechanics
- [ ] p95 under 200 ms for 1000 slots')
form=$(new "Booking form (3 steps)" -t story -s todo -p p0 -m mvp --parent "$booking" -d "$api" -l web,ui --body '1. service type
2. time slot
3. contact + note (optional photo of the bike)')
confirm=$(new "Confirmation e-mail and SMS" -s backlog -p p1 -m mvp --parent "$booking" -d "$form" -l notifications)
calendar=$(new "Workshop calendar for mechanics" -t story -s todo -p p1 -m mvp --parent "$booking" -d "$model" -l web,ui)
dnd=$(new "Move bookings in the calendar by dragging" -t story -s backlog -p p2 -m launch --parent "$booking" -d "$calendar" -l ui)
bug1=$(new "Bookings across midnight are saved a day off" -t bug -s todo -p p0 -m mvp --parent "$booking" -l backend --body '## Repro
1. create a booking 23:30–00:30
2. the calendar shows it on the next day

Suspect: time zone conversion in `SlotService.normalize`.')

step1=$(new "Step 1: choose the service type" -s todo -p p0 -m mvp --parent "$form" -l web,ui)
step2=$(new "Step 2: choose from free slots" -s todo -p p0 -m mvp --parent "$form" -d "$api" -l web,ui)
phone=$(new "Validate phone and e-mail" -s in-progress -p p1 -m mvp --parent "$form" -l web)
cal_week=$(new "Weekly calendar view" -s review -p p1 -m mvp --parent "$calendar" -l web,ui)
cal_print=$(new "Print the daily workshop plan" -s backlog -p p3 --parent "$calendar" -l web)

# --- payments ----------------------------------------------------------------
gateway=$(new "Decision: payment gateway" -t decision -s review -p p1 -m launch --parent "$payments" --body '## Options
| gateway | fee | API |
|---|---|---|
| GoPay | 1.9 % | ok |
| Stripe | 1.4 % + €0.25 | excellent |
| Comgate | 1.5 % | ok |

**Proposal:** Stripe — best SDK, Apple/Google Pay included.')
deposit=$(new "€10 deposit when booking" -s backlog -p p1 -m launch --parent "$payments" -d "$gateway","$form" -l backend,web)
invoice=$(new "Invoices for finished jobs" -s backlog -p p2 -m launch --parent "$payments" -d "$gateway" -l backend)
refund=$(new "Refund the deposit on cancellation within 24 h" -s backlog -p p3 --parent "$payments" -d "$deposit")

# --- ops ---------------------------------------------------------------------
backups=$(new "Production DB backups" -s todo -p p0 -m mvp --parent "$ops" -l infra,db --body '- [x] pick a tool (restic)
- [ ] daily backup + 30 days retention
- [ ] tested restore')
ci=$(new "CI: tests and build on every PR" -s done -p p1 -m mvp --parent "$ops" -l infra)
deploy=$(new "Automatic deploy to staging" -s in-progress -p p1 -m mvp --parent "$ops" -d "$ci" -l infra)
monitoring=$(new "Monitoring and alerts (uptime, errors)" -s todo -p p2 -m launch --parent "$ops" -d "$deploy" -l infra)
gdpr=$(new "GDPR: export and deletion of customer data" -s backlog -p p2 -m launch --parent "$ops" -l legal,backend)

# --- web ---------------------------------------------------------------------
landing=$(new "Landing page and price list" -s in-progress -p p2 -m launch --parent "$web" -l web)
seo=$(new "SEO and sitemap" -s backlog -p p3 -m launch --parent "$web" -d "$landing" -l web)
reviews=$(new "Customer reviews of the service" -t story -s backlog -p p3 --parent "$web" -d "$confirm" -l web)

# --- loose ideas -------------------------------------------------------------
new "Loyalty programme (every 5th service discounted)" -t idea -p p3 -l marketing >/dev/null
new "Spring reminder for the seasonal service" -t idea -p p3 -l notifications --body 'Send in March to everyone who came last year.' >/dev/null
old=$(new "Prototype in Google Sheets" -s cancelled -p p3 --body 'Replaced by the real app.')

# --- agents at work ----------------------------------------------------------
bl claim "$deploy" --as monorepo-2 >/dev/null
bl claim "$landing" --as monorepo-3 >/dev/null
bl claim "$bug1" --as monorepo-4 >/dev/null
bl claim "$phone" --as monorepo-5 --force >/dev/null
bl set "$bug1" branch=fix/midnight-booking >/dev/null
# monorepo-4 "crashed": its claim ran out 3 hours ago
lock="backlog/.locks/$bug1.lock"
stale=$(date -u -d '-7 hours' +%Y-%m-%dT%H:%M:%S.000Z)
jq --arg t "$stale" '.claimed_at=$t | .heartbeat_at=$t' "$lock" >"$lock.new" && mv "$lock.new" "$lock"

# --- docs and custom views ---------------------------------------------------
cat >backlog/docs/booking.md <<'EOF'
# Booking — design

30-minute slots; capacity depends on the number of mechanics on shift.
The service type sets the length (small service 1 h, full service 3 h).
EOF
cat >backlog/views/mvp.yaml <<'EOF'
name: MVP
section: Releases
layout: kanban
filter:
  milestone: mvp
group_by: status
columns: [backlog, todo, in-progress, review, done]
sort: [priority, created]
EOF
cat >backlog/views/by-priority.yaml <<'EOF'
name: By priority
section: Planning
layout: kanban
filter:
  category: {not: [done]}
group_by: priority
sort: [-ready, created]
EOF

(cd backlog && git init -q && git add -A && git -c user.name=playground -c user.email=playground@localhost commit -qm "Spokes backlog")

echo "Playground ready: $play"
bl lint || true
bl ready
