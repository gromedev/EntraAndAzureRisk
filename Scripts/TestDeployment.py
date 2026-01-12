# Wait and check third collection (after random changes)
# sleep 390 && curl -s "https://func-entrariskv35-data-dev-enkqnnv64liny.azurewebsites.net/runtime/webhooks/durabletask/instances/840a4b3a-bddd-4332-8416-d1ba0580e719?taskHub=EntraRiskHub&connection=AzureWebJobsStorage&code=H85CnWqn2Naz4LZfUM9s6r1lhh9SI-67BTpFFIqhstFOAzFu91rYfQ==" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('Status:', d.get('runtimeStatus'))
o = d.get('output', {})
if o:
    idx = o.get('Indexing', {})
    print()
    print('=== THIRD COLLECTION (AFTER RANDOM CHANGES) ===')
    total_writes = 0
    for k, v in idx.items():
        if isinstance(v, dict):
            writes = v.get('CosmosWrites') or 0
            total_writes += writes
            mod = v.get('Modified', 'N/A')
            new = v.get('New', 'N/A')
            tot = v.get('Total', 'N/A')
            unchanged = (tot or 0) - (new or 0) - (mod or 0) if isinstance(tot, int) and isinstance(new, int) and isinstance(mod, int) else 'N/A'
            print(f'{k}: Total={tot}, New={new}, Mod={mod}, Unchanged={unchanged}, Writes={writes}')
    print()
    print(f'TOTAL WRITES: {total_writes}')
    print()
    print('Note: The Modified count now reflects REAL changes from your random changes script!')
else:
    print('Still running...')