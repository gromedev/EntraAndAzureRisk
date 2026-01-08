
.\deploy.ps1 `
    -SubscriptionId "4e5adb24-09e8-4a01-adbb-c6cee339f639" `
    -TenantId "e5011376-d3a9-499e-8707-10e0a0ee2c45" `
    -ResourceGroupName "rg-entrarisk-v3-001" `     # Different from v1/v2
    -WorkloadName "entrariskv3" `                   # Different name → unique resource names
    -Environment "dev" `
    -Location "swedencentral"


=====================

https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/api/dashboard

https://func-entrarisk-data-dev-36jut3xd6y2so.azurewebsites.net/.auth/login/aad/callback



=====================
VERSION 2:

https://func-entrariskv2-data-dev-cotbit5z3mgv4.azurewebsites.net/api/dashboard?code=SxvoPxm3wp0d4it2NacAZ2Sf4f5Q1TFYnxKwwY50c_X1AzFuDd91yQ==

=====================
VERSION 3:

https://func-entrariskv3-data-dev-76q5bvq4grjmw.azurewebsites.net/api/dashboard?code=IBxROQTO4gim5_HX09V0YbEdABNNDyMb3Q_Enl10Edj9AzFu4zRr8A==

=====================

az functionapp deploy


--name "func-entrariskv2
--ids
-- cosmos "cosno-entrariskv3




az storage blob list --account-name "stentrariskv3dev76q5bvq4" --container-name "raw-data" --auth-mode key --query "[].{name:name, size:properties.contentLength}" -o table 2>&1