# Cosmos DB Cost Analysis

**Account:** `cosno-entrariskv35-dev-enkqnnv64liny`
**Resource Group:** `rg-entrarisk-v35-001`
**Region:** Sweden Central
**Analysis Date:** January 15, 2026

---

## Root Cause: Provisioned Instead of Serverless

The Cosmos DB account was deployed as **provisioned** instead of **serverless** due to a Bicep misconfiguration.

### Verification
```
Capacity Mode:    null (not serverless)
Capabilities:     [] (missing EnableServerless)
Free Tier:        false
Billing Meter:    "Azure Cosmos DB - RUs - SE Central" (provisioned billing)
```

### The Bicep Issue
**Current** ([main.bicep:150](../Infrastructure/main.bicep#L150)):
```bicep
capabilities: []   // EMPTY - defaults to provisioned
```

**Required for serverless:**
```bicep
capabilities: [
  {
    name: 'EnableServerless'
  }
]
```

### Result
| Container | Provisioned Throughput |
|-----------|------------------------|
| principals | 400 RU/s |
| policies | 400 RU/s |
| audit | 400 RU/s |
| events | 400 RU/s |
| edges | 400 RU/s |
| resources | 400 RU/s |
| **Total** | **2,400 RU/s (24/7)** |

---

## Cost Impact

### Current Costs (Provisioned)
| Metric | Value |
|--------|-------|
| Provisioned capacity | 2,400 RU/s |
| Daily cost | ~28 DKK (~$4 USD) |
| Monthly cost | **~840 DKK (~$120 USD)** |

### If Serverless (as intended)
| Metric | Value |
|--------|-------|
| Average daily RU consumption | ~1.1M RU |
| Serverless rate | $0.25 per 1M RU |
| Monthly cost | **~56 DKK (~$8 USD)** |

### Overpayment
| Period | Overpayment |
|--------|-------------|
| Per month | ~$112 USD |
| Since deployment (Jan 8) | ~$28 USD |

---

## RU Consumption Analysis

### By Container (Jan 8-15, 2026)
| Container | Total RUs | % of Total |
|-----------|----------|------------|
| audit | 2,935,103 | 33% |
| edges | 2,739,231 | 31% |
| principals | 2,119,062 | 24% |
| policies | 639,458 | 7% |
| resources | 467,959 | 5% |
| events | 1,447 | <1% |
| **Total** | **8,904,137** | 100% |

### By Operation Type
| Operation | Total RUs | % of Total |
|-----------|----------|------------|
| Upsert (Orchestrator writes) | 8,759,726 | 98.4% |
| Query (Dashboard reads) | 140,394 | 1.6% |
| Other | 4,017 | <1% |

### Dashboard Cost per Access
The Dashboard function executes 7 queries per page load:
- ~210 RU per dashboard access
- Only 1.6% of total RU consumption
- **Dashboard is NOT a significant cost driver**

---

## Utilization Analysis

| Metric | Value |
|--------|-------|
| Provisioned capacity | 2,400 RU/s |
| Average actual usage | ~12.7 RU/s |
| **Utilization** | **0.5%** |

You are paying for 207M RU/day capacity but using only ~1.1M RU/day.

---

## Fix Required

### Option 1: Redeploy with Serverless (Recommended)

Serverless cannot be enabled on an existing account. You must:

1. Update Bicep to add serverless capability
2. Deploy new account
3. Migrate data
4. Update connection strings

**Bicep change required:**
```bicep
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: cosmosDbAccountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [
      {
        name: 'EnableServerless'  // ADD THIS
      }
    ]
    // ... rest of config
  }
}
```

**Note:** Serverless does not support:
- Continuous backup (must use Periodic)
- Multi-region writes
- Provisioned throughput guarantees

### Option 2: Reduce Provisioned Throughput (Workaround)

If you must keep provisioned mode:
- Use shared database throughput (400 RU/s shared across all containers)
- Reduces cost from ~$120/month to ~$20/month

---

## Daily Cost Breakdown (Jan 8-15)

| Date | RUs Consumed | Billed Cost (DKK) | Notes |
|------|-------------|-------------------|-------|
| Jan 8 | 451,420 | 3.86 | Partial day |
| Jan 9 | 3,825,832 | 29.25 | Heavy testing |
| Jan 10 | 502,335 | 29.25 | |
| Jan 11 | 506,081 | 29.25 | |
| Jan 12 | 2,576,408 | 31.89 | Heavy testing |
| Jan 13 | 372,651 | 29.25 | |
| Jan 14 | 73,586 | 29.25 | Light usage |
| Jan 15 | 595,824 | 15.84 | Partial day |

**Note:** Cost is based on provisioned capacity (2,400 RU/s), not actual consumption. This is why cost is nearly constant regardless of usage.

---

## Summary

| Finding | Details |
|---------|---------|
| **Root Cause** | Bicep missing `EnableServerless` capability |
| **Current Mode** | Provisioned (6 × 400 RU/s = 2,400 RU/s) |
| **Intended Mode** | Serverless |
| **Current Cost** | ~$120/month |
| **Expected Cost** | ~$8/month (serverless) |
| **Overpayment** | ~$112/month (93%) |
| **Fix** | Redeploy with serverless capability |

---

*Generated: January 15, 2026*
