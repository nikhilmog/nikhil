# INCIDENT REFERENCE CARD
## Azure Payment Processing Environment (vm-app / vm-db)

**Last Updated:** 2024-03-25 | **Data Window:** 90 days (2024-01-01 to 2024-03-25)

---

## CRITICAL ALERTS & THRESHOLDS

### 🔴 DISK USAGE (vm-app)
- **Current:** 34.4% of 30GB (10.3GB used)
- **Growth Rate:** +0.25%/day
- **Days to 85% (no mitigation):** ~193 days → **ETA: 2024-10-05**
- **Days to 85% (with logrotate 80% reduction):** ~1012 days → **ETA: 2026-11-30**
- **Action if > 80%:** Run `/usr/local/bin/disk-breakdown.sh` + `logrotate -fv /etc/logrotate.d/payment-service`
- **Action if > 85%:** Stop app, clean `/var/log`, restart

---

### 🔴 DB CONNECTIONS (vm-db)
- **Current:** 7.3 of 20 max
- **Growth Rate:** +0.433 connections/week (monotonic, zero variance)
- **Days to 16/20 threshold:** ~140 days → **ETA: 2024-08-12 to 2024-08-23**
- **Alert threshold:** ≥ 15 sustained for 10 minutes
- **Concern pattern:** Perfectly monotonic growth suggests connection leak, not workload cycling
- **Action:** Run `/usr/local/bin/check-idle-connections.sh`, identify backend_start >> query_start rows
- **Mitigation:** PostgreSQL `idle_session_timeout = 10min` (already deployed)

---

### 🟡 MEMORY USAGE (vm-app)
- **Current:** 26.3% of 8GB RAM
- **Growth Rate:** +0.10%/day
- **JVM Config:** -Xmx4g (4GB heap on 8GB VM)
- **Risk Level:** Watch & Monitor (no immediate threshold)
- **Leak hypothesis:** Combined with flat CPU, suggests state accumulation (cache/session retention), not compute growth
- **Action:** If > 85% OR JVM Old Gen > 85%, run `/usr/local/bin/jvm-heap-capture.sh` and analyze

---

### 🟢 CPU USAGE (vm-app)
- **Current:** 3.6%
- **Growth Rate:** Flat (~3.1% → 3.6% over 90 days = negligible)
- **Risk Level:** None
- **Interpretation:** Combined with rising memory, indicates workload shift is NOT CPU-bound

---

## QUICK COMMANDS

| Scenario | Command | Expected Output |
|----------|---------|-----------------|
| **Disk breakdown** | `/usr/local/bin/disk-breakdown.sh` | Identifies /var/log, /opt, /tmp consumption |
| **DB idle connections** | `/usr/local/bin/check-idle-connections.sh` | Lists connections idle > 5 minutes |
| **JVM heap trend (7 days)** | `/usr/local/bin/jvm-heap-capture.sh` | Starts background jstat capture |
| **TCP CLOSE_WAIT count** | `ss -tan state close-wait '( dport = :5432 )' \| tail -n +2 \| wc -l` | Should be < 5 |
| **Test logrotate** | `logrotate -d /etc/logrotate.d/payment-service` | "handling 1 file" = ready to rotate |

---

## PRIORITY RANKING

| Rank | Metric | Urgency | Reason | ETA to Critical |
|------|--------|---------|--------|----------------|
| **1** | DB Connections | **NOW** | Strongest rate, earliest threshold, monotonic pattern (likely leak) | ~5 months (Aug 2024) |
| **2** | Disk Usage | **PLAN** | High growth rate, severe failure mode if saturated | ~6 months (Oct 2024) |
| **3** | Memory Usage | **WATCH** | Steady growth, no immediate threshold, likely state accumulation | No ETA (monitoring only) |
| **4** | CPU Usage | **IGNORE** | Flat; no capacity concern | N/A |

---

## WHAT TO DO THIS WEEK

- [ ] **Deploy logrotate:** Terraform deployment includes logrotate config for daily rotation + 7-day retention
- [ ] **Enable DB idle timeout:** PostgreSQL configured with `idle_session_timeout = 10min` to auto-recycle leaked connections
- [ ] **Start trend capture:** First weekly trend runs this Sunday @ 09:00 UTC via cron
- [ ] **Schedule review:** Review DB connection trend after 2 weeks to confirm leak is being recycled

---

## DIAGNOSIS DECISION TREE

```
SYMPTOM: Memory rising, CPU flat

├─→ Is JVM running? (pgrep -f "java.*payment-service")
│   ├─→ YES: Run jvm-heap-capture.sh → analyze Old Gen trend
│   │   ├─→ Old Gen > 85% & monotonic? = HEAP LEAK (restart app)
│   │   ├─→ Old Gen stable? = Normal JVM behavior (no action)
│   │   └─→ Can't decide? = Take heap dump (jmap)
│   │
│   └─→ NO: Check OS-level memory
│       └─→ Run 'free -h' → If page cache > 4GB, likely normal Linux behavior
│
```

```
SYMPTOM: DB connections trending up

├─→ Query pg_stat_activity
│   ├─→ backend_start ≈ query_start && both very old? = LEAKED CONNECTION
│   │   └─→ Action: Restart payment service, monitor trend next week
│   │
│   ├─→ Multiple connections from same app? = CONNECTION POOL LEAK
│   │   └─→ Action: Check app logs, review connection pool config
│   │
│   ├─→ Steady increase but connections finishing? = NORMAL GROWTH
│   │   └─→ Action: Monitor, may need connection pool tuning
│   │
│   └─→ Monotonic with zero variance? = LIKELY APP-LEVEL LEAK (highest risk)
│       └─→ Action: Escalate to app team, apply idle_session_timeout mitigation
│
```

```
SYMPTOM: Disk at 80%

├─→ Run disk-breakdown.sh
│   ├─→ /var/log > 70% of growth? = LOG PROBLEM (run logrotate -fv)
│   ├─→ /opt/payment-service/logs > 3GB? = APP LOGS TOO VERBOSE (reduce log level)
│   ├─→ /tmp > 2GB? = TEMP FILE LEAK (check app, restart if needed)
│   └─→ Multiple culprits? = Manual cleanup + address each source
│
```

---

## ESCALATION TREE

**Page on-call if any:**
- DB connections >= 15 and trending up
- Disk usage >= 85%
- JVM heap Old Gen >= 85%
- TCP CLOSE_WAIT > 15 sustained > 10 min

**Page SRE on-call if:**
- Disk >= 85% and cannot be freed
- DB unreachable (connections not responding)
- Payment service crashes due to memory/disk

---

## NOTES FOR FUTURE REFERENCE

- **Logrotate deployment:** Auto-compresses logs after 1 day (delaycompress), reduces disk growth by ~80%
- **idle_session_timeout:** PostgreSQL 14 feature; auto-closes connections idle > 10 min (no app change needed)
- **JVM capture:** Runs on-demand via `/usr/local/bin/jvm-heap-capture.sh`, 7-day history per run
- **Trend data:** CSV at `/var/log/capacity-trends.csv`, auto-populated weekly
- **No redeploy needed:** All mitigations are operational (config/script only), except app bug fix for connection leak

---

**Runbook:** See `CAPACITY_MONITORING_RUNBOOK.md` for detailed procedures
**Contact:** See section 8 of runbook for escalation paths
