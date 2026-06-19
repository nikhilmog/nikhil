#!/bin/bash
################################################################################
# FinBridge DB Connectivity Incident Runbook
# Execution date: 2026-06-17
# Root cause: TCP 5432 path blocked at NSG (evidence: E1, E2, E3)
################################################################################

set -e

DB_HOST="10.0.2.10"
DB_PORT="5432"
DB_USER="labuser"
DB_PASS="Lab@2024!"
DB_NAME="labdb"

echo "=========================================="
echo "STEP 1: Confirm 5432 failure"
echo "=========================================="
echo "Test: nc -zv -w5 $DB_HOST $DB_PORT"
if nc -zv -w5 $DB_HOST $DB_PORT 2>&1; then
  echo "[PASS] Port 5432 is reachable"
  STEP1_RESULT="PASS"
else
  echo "[FAIL] Port 5432 is UNREACHABLE"
  STEP1_RESULT="FAIL"
fi

echo ""
echo "=========================================="
echo "STEP 2: Check NSG deny rules"
echo "=========================================="
if command -v az &> /dev/null; then
  echo "Azure CLI found. Listing NSG rules..."
  # List all NSG rules — identify any deny rules for port 5432
  az network nsg rule list --resource-group "$(az group list -o tsv | head -1 | cut -f1)" \
    --nsg-name "$(az network nsg list -o tsv | head -1 | cut -f1)" \
    -o table 2>/dev/null || echo "[INFO] Unable to list NSG rules — check Azure permissions"
else
  echo "[WARN] az CLI not installed. Cannot check NSG rules directly."
  echo "[INFO] Manual action: In Azure Portal, check NSG attached to vm-app NIC"
  echo "[INFO] Look for any DENY rules for port 5432 or port range including 5432"
fi

echo ""
echo "=========================================="
echo "STEP 3: Check Activity Log for NSG changes"
echo "=========================================="
if command -v az &> /dev/null; then
  echo "Checking Activity Log for NSG rule changes (last 30 min)..."
  az monitor activity-log list \
    --start-time "$(date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%S')" \
    --resource-group "$(az group list -o tsv | head -1 | cut -f1)" \
    --query "[?operationName.value == 'Microsoft.Network/networkSecurityGroups/securityRules/write']" \
    -o table 2>/dev/null || echo "[INFO] Unable to fetch Activity Log — check permissions"
else
  echo "[WARN] az CLI not installed. Cannot check Activity Log directly."
  echo "[INFO] Manual action: In Azure Portal Activity Log, search for NSG rule changes ~05:12-05:13 UTC"
fi

echo ""
echo "=========================================="
echo "STEP 4a: [CONDITIONAL] Delete NSG deny rule"
echo "=========================================="
if [ "$STEP1_RESULT" = "FAIL" ]; then
  echo "[ACTION REQUIRED]"
  echo "If Step 2 identified a DENY rule for 5432, execute:"
  echo "  az network nsg rule delete --resource-group <RG> --nsg-name <NSG> --name <RULE_NAME>"
  echo ""
  echo "Then proceed to Step 5 (Validate recovery)"
  read -p "Press Enter after rule is deleted (or Ctrl+C to abort): "
else
  echo "[SKIP] Port 5432 already reachable; deny rule removal not needed"
fi

echo ""
echo "=========================================="
echo "STEP 4b: [CONDITIONAL] Check NIC assignment"
echo "=========================================="
if [ "$STEP1_RESULT" = "FAIL" ]; then
  echo "[ACTION REQUIRED] If Step 2 found no NSG deny rule:"
  echo "Check vm-app network interface assignment to NSG"
  echo "Manual: In Azure Portal > vm-app > Networking > Network Security Group"
  echo "Verify correct NSG is assigned and has no blocking rules"
  read -p "Press Enter after NIC assignment verified (or Ctrl+C to abort): "
else
  echo "[SKIP] Port 5432 already reachable; NIC check not needed"
fi

echo ""
echo "=========================================="
echo "STEP 5: Validate recovery — nc + psql"
echo "=========================================="
echo "Test 1: nc -zv -w5 $DB_HOST $DB_PORT"
if nc -zv -w5 $DB_HOST $DB_PORT 2>&1; then
  echo "[PASS] Port 5432 is reachable"
  
  echo ""
  echo "Test 2: psql connection test"
  if PGPASSWORD="$DB_PASS" psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1" 2>&1; then
    echo "[PASS] PostgreSQL connection successful"
    RECOVERY_STATUS="SUCCESS"
  else
    echo "[FAIL] PostgreSQL connection failed — DB may be unresponsive"
    RECOVERY_STATUS="PARTIAL"
  fi
else
  echo "[FAIL] Port 5432 still unreachable after remediation"
  RECOVERY_STATUS="FAILED"
fi

echo ""
echo "=========================================="
echo "STEP 6: Confirm PostgreSQL pool recovered"
echo "=========================================="
if [ "$RECOVERY_STATUS" = "SUCCESS" ]; then
  echo "Query active connections..."
  PGPASSWORD="$DB_PASS" psql -h $DB_HOST -U $DB_USER -d $DB_NAME \
    -c "SELECT count(*) as active_connections FROM pg_stat_activity;" 2>&1 || echo "[WARN] Cannot query active connections"
  echo "[TARGET] Active connections should be <10/20 max"
else
  echo "[SKIP] Skipped — PostgreSQL not yet responding"
fi

echo ""
echo "=========================================="
echo "INCIDENT RESOLUTION SUMMARY"
echo "=========================================="
echo "Step 1 (Confirm failure):        $STEP1_RESULT"
echo "Step 5 (Validate recovery):      $RECOVERY_STATUS"
echo ""
if [ "$RECOVERY_STATUS" = "SUCCESS" ]; then
  echo "✓ INCIDENT RESOLVED"
  echo "Service is restored. Monitor for 15 min to confirm stability."
else
  echo "✗ INCIDENT NOT RESOLVED"
  echo "Escalate to network/security team for further investigation."
  echo "Provide: runbook output, Activity Log excerpt, NSG rule names"
fi
