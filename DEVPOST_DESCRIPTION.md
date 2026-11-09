# Little Wallet ✨

> **Tactile personal finance & bill-splitting iOS app putting AI behind the wheel of PayPal.**
> 
> You speak an expense (*"Spent $14 at Blue Bottle for coffee on Apple Card"*), and on-device natural language models parse every detail instantly with zero cloud roundtrips. You snap a photo of a restaurant or grocery receipt, and VisionKit decomposes it into line items. When it's time to split, friends get a personalized link (`/s/:token`) with **only their items** and a one-tap **Venmo** or **PayPal** button powered by **PayPal Orders v2**.
> 
> Best of all, **Penny**—your autonomous on-device financial copilot—remembers your shared history, answers spending questions conversationally, and drafts actions across the PayPal ecosystem: sending PayPal Invoices, issuing 1-tap Refunds, and distributing Payouts to friends with human-in-the-loop review.

Built for the **PayPal AI Hackathon 2026**.

---

## 💡 Inspiration

Splitting expenses with friends, roommates, or partners is one of those everyday rituals that is surprisingly painful. Someone covers dinner, someone grabs groceries, someone fronts the concert tickets. Then comes the dreaded aftermath:
- **Napkin math is tedious**: Roommates share communal items like milk and olive oil, buy personal snacks, and calculate tax and tip on sticky notes or group chats.
- **Flat splits are unfair**: The person who only drank coffee ends up subsidizing someone else's wagyu steak.
- **Chasing money is awkward**: Friends forget, messages get buried, and asking "did you send that yet?" feels uncomfortable.

We asked: **What happens when you put cutting-edge on-device AI behind the wheel of PayPal?** 
Can an app log your spending hands-free with 100% privacy, itemize receipts with computer vision, calculate mathematically fair splits down to the exact integer cent, and provide an autonomous AI financial copilot that actually interacts with the PayPal network to invoice, refund, and settle up?

That vision became **Little Wallet**.

---

## ✨ What Little Wallet Does

### 1. 🎙️ On-Device Voice AI ("Say it")
- **Hands-Free Speech Capture**: Tap the mic and speak naturally: *"Dinner at Sushi Ran was $86 on Apple Card"* or *"Trader Joe's 38 dollars grocery"*.
- **Zero-Cloud Privacy**: Built with Apple FoundationModels and Speech frameworks. Your voice recordings, transcripts, and financial logs never leave your phone.
- **Automated Slot Extraction**: Accurately infers merchant names, dollar amounts, budget categories, payment methods, and notes.

### 2. 🧾 VisionKit OCR Receipt Decomposition
- **Point-and-Shoot Scanning**: Snap any grocery or restaurant receipt with the camera.
- **Line-Item Itemization**: Automatically extracts line items, quantities, prices, subtotals, tax, and tip.
- **Audit Vault**: Original receipt images are securely stored locally and permanently linked to the transaction for instant auditability.

### 3. ✂️ Interactive Fair-Share Bill Splitting
- **Item-by-Item Assignment**: Tap who had what. Shared items are split evenly, while individual items belong strictly to whoever ordered them.
- **Fair-Share Integer Cent Math**: Taxes, service fees, and tips are distributed proportionally to each person's spend using largest-remainder integer cent rounding—guaranteeing that split shares add up to 100% of the receipt with zero stray pennies.
- **iMessage & Apple Cash**: Generate instant Message requests with rendered visual receipt cards.

### 4. 💳 Instant Settle-Up via PayPal Orders v2 & Venmo
- **Dedicated Friend Links**: Each friend receives an unguessable settle-up link (`/s/:token`).
- **PayPal & Venmo Checkout**: The friend-facing web page renders native PayPal and Venmo checkout buttons powered by the **PayPal JS SDK** (`enable-funding=venmo`) and **PayPal Orders v2** (`intent: CAPTURE`).
- **Server-Enforced Integrity**: The frontend cannot alter the amount; order creation (`POST /api/shares/:token/order`) derives amounts exclusively from backend records.
- **Venmo App Fallback**: Deep links (`venmo://paycharge`) with prefilled handle, amount, and note ensure everyone can pay.

### 5. 🤖 Penny: Autonomous Financial Copilot
- **Conversational Intelligence**: Ask Penny anything about your money: *"How much did I spend on dining out this month?"*, *"Who owes me from Trader Joe's?"*, or *"Remind Sam and Jing about the dinner bill"*.
- **Autonomous Action Planning with Human-in-the-Loop Review**: Penny prepares structured execution cards (`PennyPlan`):
  - **Friendly Reminders**: Drafts consolidated reminders grouping unpaid splits.
  - **PayPal Invoices**: Triggers `POST /api/paypal/invoices` using the **PayPal Invoicing API v2** to send professional invoices via email or payment link.
  - **PayPal Refunds**: Triggers `POST /api/paypal/refunds` via the **PayPal Refunds API v2** for 1-tap reimbursement.
  - **PayPal Payouts**: Triggers `POST /api/paypal/payouts` via the **PayPal Payouts API v1** to disburse funds to friends.
- **Zero Hallucinations**: Penny's answers are strictly computed from verified on-device ledger data.

### 6. ⚡ Real-Time Synchronization (Webhooks & SSE)
- **Live Status Feed**: The iOS app connects to Server-Sent Events (`LiveUpdates.swift` -> `GET /api/events`) while active.
- **Cryptographic Webhooks**: The companion server receives PayPal webhooks (`POST /webhooks/paypal`), verifies cryptographic signatures via `/v1/notifications/verify-webhook-signature`, and broadcasts `PAYMENT.CAPTURE.COMPLETED` and `INVOICING.INVOICE.PAID` events to the phone in real time.

---

## 🛠️ How We Built It

Little Wallet is engineered as a high-performance, privacy-first mobile architecture paired with a zero-dependency companion server:

- **iOS Client**:
  - **Swift 6 & SwiftUI**: Modern declarative UI with physics-based tactile cards, custom gesture stacks, and dynamic Month carousels.
  - **Apple Intelligence & Speech Framework**: On-device natural language parser that extracts intent, entities, and slots without external API calls.
  - **Apple VisionKit**: Fast OCR document scanning and structured bounding-box parsing for itemized receipts.
  - **XCTest Suite**: 63 comprehensive unit tests executing in **0.28 seconds**, verifying split math, OCR parsing, voice parsing, and agent safety.

- **Companion Server (`little-fridge-split`)**:
  - **Node.js 22**: Pure ES module server built with zero third-party runtime dependencies for maximum security, speed, and auditability.
  - **PayPal Orders v2**: Creates and captures sandbox/live orders with strict server-side validation.
  - **PayPal Invoicing API v2**: Generates and emails PayPal invoices.
  - **PayPal Refunds API v2**: Processes instant transaction refunds.
  - **PayPal Payouts API v1**: Dispatches batch payouts to friends.
  - **PayPal Transaction Search API**: Synchronizes recent account activity.
  - **Real-Time SSE Engine**: Broadcasts instant push notifications to active iOS clients upon webhook receipt.

---

## 🧗 Challenges We Ran Into

1. **Integer-Cent Math Guarantee**: When splitting shared grocery items and allocating proportional sales tax across 4 or 5 roommates, standard floating-point division leads to rounding errors and lost cents. We implemented largest-remainder distribution in integer cents to ensure that $\sum \text{shares} \equiv \text{receipt total}$ always.
2. **PayPal Sandbox Multi-Party Checkout**: Navigating sandbox authentication and payment approvals for multi-party bill settlements required careful handling of `custom_id` verification, currency formatting, and instrument decline recovery.
3. **Local Webhook Cryptographic Verification**: Verifying PayPal's HMAC and asymmetric certificates locally during development required precise header forwarding and SSL certificate chain handling.

---

## 🏆 Accomplishments We're Proud Of

- **63 Passing Tests in 0.28s**: Every mathematical calculation, voice intent parser, receipt OCR edge case, and Penny action plan is verified by automated unit tests.
- **100% On-Device Privacy**: Your financial transactions, receipts, and voice audio remain strictly on your device.
- **End-to-End Real-Time Payment Flow**: Watching a friend pay via Venmo on the settle-up page and seeing the iOS app update to "Paid" via real-time webhooks in under a second feels like magic.
- **Commercial-Grade Explainer Story**: A fully produced explainer video and soundtrack inspired by the storytelling style of *3D Craft*.

---

## 📚 What We Learned

Integrating PayPal Orders v2 with Webhooks and Invoicing showed us the power of PayPal's modern developer platform. By combining server-enforced order integrity with on-device AI, we can build consumer finance tools that are both delightfully tactile and enterprise-grade reliable.

---

## 🚀 What's Next for Little Wallet

- **PayPal Marketplace Onboarding**: Support multi-organizer split payouts where funds route directly to any organizer's linked PayPal account.
- **iOS Live Activities & Dynamic Island**: Track pending group split settlements in real-time right on the lock screen.
- **Multi-Currency Travel Splits**: Automatic FX conversion using real-time rates when traveling internationally with friends.
