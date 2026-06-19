# Capacity Monitoring & Leak Detection Runbook
## Payment Processing Environment (vm-app / vm-db)

---

## Quick Reference: Command Locations

| Tool | Location | Purpose |
|------|----------|---------|
| `disk-breakdown.sh` | `/usr/local/bin/disk-breakdown.sh` | On-demand disk usage analysis |
| `disk-trend-capture.sh` | `/usr/local/bin/disk-trend-capture.sh` | Weekly trend data capture (automated) |
| `jvm-heap-capture.sh` | `/usr/local/bin/jvm-heap-capture.sh` | JVM heap/GC statistics (7-day history) |
| `check-idle-connections.sh` | `/usr/local/bin/check-idle-connections.sh` | PostgreSQL idle connection detection |
| Logrotate (app) | `/etc/logrotate.d/payment-service` | Rotate payment service logs daily |
| Logrotate (db) | `/etc/logrotate.d/postgresql` | Rotate PostgreSQL logs daily |
| Trend data | `/var/log/capacity-trends.csv` | 90-day historical trend (vm-app) |

---

## 1. DISK USAGE MONITORING

### Symptom: Disk is growing unexpectedly

**Step 1: Get disk breakdown**
```bash
ssh labadmin@vm-app
/usr/local/bin/disk-breakdown.sh
```

**Expected output interpretation:**
```
=== ROOT FILESYSTEM BREAKDOWN ===
12G	/var
4.5G	/opt
1.2G	/tmp
```
- If `/var/log` is > 5GB: log rotation may not be working → check logrotate
- If `/opt/payment-service/logs` is > 3GB: application logging verbosity may be too high
- If `/tmp` is > 2GB: temp files accumulating → investigate application temp cleanup

**Step 2: Check logrotate status**
```bash
logrotate -d /etc/logrotate.d/payment-service
# Output: 'handling 1 file' means ready to rotate
# Output: 'not rotating' means recent rotation or size threshold not met
```

**Step 3: Force rotate immediately if needed**
```bash
logrotate -fv /etc/logrotate.d/payment-service
```

### Thresholds & Actions

| Disk % | Status | Action |
|--------|--------|--------|
| < 50% | Healthy | Monitor only |
| 50-70% | Warning | Review recent log growth trend |
| 70-85% | Alert | Verify logrotate is running; consider manual cleanup |
| > 85% | Critical | Immediate action: stop app, clean logs, restart |

---

## 2. DATABASE CONNECTION LEAK DETECTION

### Symptom: DB connections trending upward (2.1 → 7.3 → ???)

**Step 1: Check current idle connections**
```bash
ssh labadmin@vm-db
/usr/local/bin/check-idle-connections.sh
```

**Step 2: Manual query for connection details**
```bash
sudo -u postgres psql labdb -c "
  SELECT
    pid,
    usename,
    application_name,
    backend_start,
    state,
    EXTRACT(EPOCH FROM (now() - backend_start))::int AS backend_age_sec,
    EXTRACT(EPOCH FROM (now() - query_start))::int AS idle_since_sec,
    query
  FROM pg_stat_activity
  WHERE state = 'idle'
    AND pid <> pg_backend_pid()
  ORDER BY backend_start ASC
  LIMIT 20;
"
```

**Interpretation:**
- `backend_age_sec` = 3 days (259200 sec) and `idle_since_sec` = 3 days → **leaked connection**
- `backend_age_sec` = 5 min and `idle_since_sec` = 30 sec → **normal pool idling**

**Step 3: Check if idle_session_timeout is working**
```bash
sudo -u postgres psql -c "SHOW idle_session_timeout;"
# Should output: 10min
```

### Thresholds & Actions

| Idle Connections | Duration | Action |
|------------------|----------|--------|
| 1-3 | < 10 min | Normal; monitor |
| 3-7 | 10-60 min | Check if session timeout is configured |
| > 7 | > 1 hour | Leak likely; check app logs; may need restart |
| Monotonic growth | Any | Likely connection pool bug in app |

---

## 3. JVM HEAP LEAK DETECTION (vm-app)

### Symptom: Memory % rising while CPU stays flat

**Step 1: Check if payment service is running**
```bash
ssh labadmin@vm-app
pgrep -f "java.*payment-service"
# If PID returned: service is running
# If empty: service not running (can't capture heap data)
```

**Step 2: Start 7-day JVM heap capture**
```bash
/usr/local/bin/jvm-heap-capture.sh
# Runs in background; captures jstat output to /var/log/payment/jvm_heap_gcutil_YYYY-MM-DD.log
```

**Step 3: After capture, analyze heap growth**
```bash
# View first 10 samples
head -15 /var/log/payment/jvm_heap_gcutil_2024-03-25.log

# Expected columns: S0 S1 E O M CCS YGC YGCT FGC FGCT GCT
# S0/S1 = Survivor spaces (young gen)
# E = Eden (young gen)
# O = Old generation (heap)
# M = Metaspace
```

**Leak confirmation pattern (bad):**
```
YGC  YGCT FGC FGCT   GCT    O      <- Old gen column
  50  1.23  15  12.4  13.6  89.5   <- Old gen at 89.5% after Full GC
  52  1.24  16  13.1  14.3  92.1   <- Higher after each FGC = leak
  54  1.25  17  13.8  15.0  95.6   <- Still rising = LEAK CONFIRMED
```

**Normal pattern (good):**
```
YGC  YGCT FGC FGCT   GCT    O      <- Old gen column
  50  1.23   5   2.1   3.4  35.2   <- Old gen at 35%, drops after FGC
  52  1.24   6   2.3   3.7  36.1   <- Stable ±2%
  54  1.25   7   2.5   4.0  35.8   <- No trend = healthy
```

**Step 4: If leak confirmed, take heap dump**
```bash
PID=$(pgrep -f "java.*payment-service")
jmap -dump:live,format=b,file=/tmp/heap_dump.hprof $PID
# Analyze with Eclipse MAT or jhat
```

### Thresholds & Actions

| Old Gen Utilization | Trend | Action |
|---------------------|-------|--------|
| 20-40% | Flat | Healthy; no action |
| 40-70% | Steady rise | Monitor; check object retention |
| 70-85% | Monotonic increase | Likely leak; schedule app restart |
| > 85% | Constant rise | Leak confirmed; restart app immediately |

---

## 4. TCP CONNECTION STATE MONITORING (vm-app → vm-db)

### Symptom: Connections not closing cleanly (CLOSE_WAIT state)

**Step 1: Count CLOSE_WAIT sockets to PostgreSQL**
```bash
ssh labadmin@vm-app
ss -tanp state close-wait '( dport = :5432 )' | tail -n +2 | wc -l
# Output: number of sockets in CLOSE_WAIT state
```

**Step 2: View details**
```bash
ss -tanpo state close-wait '( dport = :5432 )'
# Shows: IP:port, timer, size, state
```

**Step 3: Calculate ratio of CLOSE_WAIT to established**
```bash
CLOSE_WAIT=$(ss -tan state close-wait '( dport = :5432 )' | tail -n +2 | wc -l)
ESTABLISHED=$(ss -tan state established '( dport = :5432 )' | tail -n +2 | wc -l)
RATIO=$(echo "scale=3; $CLOSE_WAIT / ($CLOSE_WAIT + $ESTABLISHED)" | bc)
echo "CLOSE_WAIT=$CLOSE_WAIT, ESTABLISHED=$ESTABLISHED, Ratio=$RATIO"
```

### Thresholds & Actions

| CLOSE_WAIT Count | Ratio | Duration | Action |
|------------------|-------|----------|--------|
| < 5 | < 1% | Any | Normal; monitor |
| 5-15 | 1-3% | < 10 min | Warning; check app logs |
| 15+ | > 3% | > 10 min | Alert; leak likely in app |
| Growing monotonically | Any | Any | Leak confirmed; restart app |

**Early warning policy:**
```
IF close_wait_count >= 5 FOR 10 minutes
   OR close_wait_ratio >= 0.03 FOR 10 minutes
   THEN: Page on-call engineer to review app logs
```

---

## 5. GROWTH RATE FORECASTING

### Current projections (as of 2024-03-25):

| Metric | Current | Rate | 85% Threshold | ETA |
|--------|---------|------|----------------|-----|
| DB Connections | 7.3/20 | +0.43/week | 16/20 | 2024-08-12 |
| Disk % | 34.4% | +0.26%/day | 85% | 2024-10-05 |
| Memory % | 26.3% | +0.10%/day | (no threshold) | N/A |
| CPU % | 3.6% | flat | (no concern) | N/A |

**With logrotate 80% reduction:**
| Metric | New Rate | 85% Threshold | New ETA |
|--------|----------|----------------|---------|
| Disk % | +0.05%/day | 85% | 2026-11-30 |

---

## 6. WEEKLY TREND CAPTURE

**Automated:** Runs every Sunday at 09:00 UTC via cron on vm-app

**Manual execution:**
```bash
/usr/local/bin/disk-trend-capture.sh
```

**View historical trends:**
```bash
cat /var/log/capacity-trends.csv | column -t -s,
# Format: epoch_day,timestamp,cpu_pct,mem_pct,disk_pct,db_connections
```

**Export for analysis:**
```bash
scp labadmin@vm-app:/var/log/capacity-trends.csv ./capacity-trends-2024.csv
```

---

## 7. INCIDENT RESPONSE CHECKLIST

### If disk reaches 80%:
- [ ] Run `/usr/local/bin/disk-breakdown.sh`
- [ ] Check if `/var/log` is > 70% of total
- [ ] Force logrotate: `logrotate -fv /etc/logrotate.d/payment-service`
- [ ] Verify free space increased
- [ ] If still > 80%, archive and delete old logs manually

### If DB connections > 15:
- [ ] Run `/usr/local/bin/check-idle-connections.sh`
- [ ] Identify connections idle > 1 hour
- [ ] Review application logs for connection pool errors
- [ ] Verify `idle_session_timeout = 10min` is set on database
- [ ] Restart payment service if leak confirmed

### If JVM heap Old Gen > 85%:
- [ ] Take heap dump: `jmap -dump:live,format=b,file=/tmp/heap.hprof <PID>`
- [ ] Check application logs for memory-intensive operations
- [ ] Review recent code changes to application
- [ ] Restart payment service
- [ ] Schedule application bug review

### If CLOSE_WAIT > 15:
- [ ] Run `ss -tanpo state close-wait '( dport = :5432 )'`
- [ ] Check payment service application logs
- [ ] Verify database is accepting new connections
- [ ] Restart payment service
- [ ] Escalate to app development team

---

## 8. CONTACT & ESCALATION

| Issue | Owner | Escalation |
|-------|-------|-----------|
| Disk growth | DevOps | If > 80%, page SRE |
| DB connections | DB Admin | If > 16, page DBA |
| JVM heap leak | App Team | If heap > 85%, restart service |
| TCP CLOSE_WAIT | Network Eng | If ratio > 3%, check network connectivity |

---

## Appendix: Manual Commands (No Scripts)

```bash
# Disk breakdown
du -sh /* 2>/dev/null | sort -hr

# DB idle connections (PostgreSQL)
sudo -u postgres psql -c "SELECT pid, usename, state, EXTRACT(EPOCH FROM (now() - backend_start))::int AS age_sec FROM pg_stat_activity WHERE state = 'idle' ORDER BY backend_start ASC;"

# JVM heap capture (7 days at 60s intervals)
PID=$(pgrep -f 'java.*payment-service')
jstat -gcutil -t "$PID" 60000 10080 >> /var/log/jvm_heap_$(date +%F).log

# TCP CLOSE_WAIT count
ss -tan state close-wait '( dport = :5432 )' | tail -n +2 | wc -l

# Logrotate test
logrotate -d /etc/logrotate.d/payment-service
```
