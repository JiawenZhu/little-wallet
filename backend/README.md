# Little Wallet server

The small Node server behind Little Wallet's pay-me-back links, PayPal sync and Penny's PayPal actions
(invoices, refunds, payouts). It has no dependencies beyond Node 22.

- Pay page: `/s/<token>`, the link friends open to pay their share.
- App API: `/api/...`, called by the iOS app with the `x-app-key` header.
- PayPal webhooks: `/webhooks/paypal`.

## Run it locally

```bash
cd backend
cp .env.example .env   # fill in your PayPal sandbox keys
npm run dev            # http://localhost:8787/s/demo-sam
npm test
```

## Hosting

Deployed on Render as the `little-wallet` web service (`render.yaml` at the repository root, `rootDir: backend`),
Starter plan with a 1 GB disk at `/var/data` so saved splits survive deploys. It runs against the PayPal sandbox.
Secrets are set in Render's dashboard, never in this repository.
