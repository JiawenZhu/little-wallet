# 🎬 Little Wallet — Commercial Ready Video Script & Storyboard
**Target**: PayPal AI Hackathon: *Build What's Next with PayPal and AI*  
**Duration**: ~100 seconds  
**Voice Profile**: Google Gemini 3.8 Flash TTS (`Zephyr` — Crisp, Energetic, Modern Tech Copilot)  
**Audio Outputs**:
- Pure Narration Master: [`commercial-video/audio/little_wallet_commercial_narration.mp3`](file:///Users/jiawenzhu/Developer/Little%20Wallet/commercial-video/audio/little_wallet_commercial_narration.mp3)
- Broadcast Mix with BGM: [`commercial-video/audio/little_wallet_commercial_master_with_bgm.mp3`](file:///Users/jiawenzhu/Developer/Little%20Wallet/commercial-video/audio/little_wallet_commercial_master_with_bgm.mp3)

---

## 🎯 Commercial Concept: *"Putting AI Behind the Wheel of PayPal"*

Most bill-splitting apps treat payments as an afterthought — giving you manual calculators, messy group spreadsheets, and awkward reminder texts.  
**Little Wallet** reimagines everyday personal finance by combining on-device speech & vision AI with PayPal's robust payment infrastructure (Orders v2, Webhooks, Invoicing, Refunds, and Payouts).

---

## 🎞️ Beat-by-Beat Storyboard & Narration

| Beat | Title & Timestamp | Visual Scene Description | On-Screen Text / UI Action | Spoken Narration (Zephyr) |
| :--- | :--- | :--- | :--- | :--- |
| **01** | **The Everyday Problem**<br>`0:00 - 0:18` | Close-up montage of chaotic receipt piles, calculator apps doing awkward division, and awkward text messages ("Hey, did you send that $28?"). Dynamic transition into a calm, warm cream palette. | *Chasing receipts? Awkward texts?*<br>• Messy spreadsheets<br>• Napkin math | *"Splitting dinner, chasing down group grocery bills, or tracking shared expenses shouldn't feel like a second job. We juggle screenshots, do napkin math, and send awkward payment reminders. But what happens when you put AI behind the wheel of PayPal?"* |
| **02** | **Introducing Little Wallet**<br>`0:18 - 0:28` | Hero reveal of the **Little Wallet** app running on iPhone 17 Pro. Tactile 3D cards, soft cream background (`#F7F2E8`), playful icons for Groceries, Dining, Transport, and Bills. | **Little Wallet**<br>*Tactile Personal Finance with AI* | *"Meet Little Wallet. It's a fresh, tactile personal finance companion designed for how people actually spend and share money in real life."* |
| **03** | **Voice AI: 'Say it'**<br>`0:28 - 0:43` | User taps the prominent green microphone button at the bottom of the screen. Real-time animated waveform reacts to natural speech. App instantly populates an itemized card with Trader Joe's items, tax breakdown, and split badges. | **Say it** 🎙️<br>→ "Trader Joe's, $84, split 3 ways with Sam and Alex"<br>• Itemized breakdown<br>• Exact cent split | *"Just tap 'Say it'. Say: 'Trader Joe's, eighty-four dollars, split three ways with Sam and Alex.' On-device intelligence instantly understands the shop, itemizes the purchase, calculates exact tax and tip, and splits the total down to the cent."* |
| **04** | **Vision AI: 'Scan Receipt'**<br>`0:43 - 0:54` | Camera scans a paper grocery receipt on a wooden table. Bounding boxes appear over line items, automatically reading cents and assigning items to friends with haptic feedback. | **Scan Receipt** 📷<br>• Vision OCR itemization<br>• Instant category tagging | *"Got a paper receipt? Snap a photo. Our Vision AI extracts every single line item and lets you assign items to friends with a tap, keeping your monthly budget organized effortlessly."* |
| **05** | **Instant PayPal & Venmo Settle-Up**<br>`0:54 - 1:10` | The Settle Up pane opens. Friend receives an SMS link `https://little-wallet.../s/xyz`. They open it in mobile Safari: crisp PayPal Checkout button and Venmo button appear with zero login friction. | **Instant Settle-Up**<br>• PayPal Orders v2<br>• Venmo 1-Tap<br>• Zero app download required | *"Settling up is completely frictionless. Little Wallet generates instant settle-up links. Your friends don't even need the app installed. They tap their link, pay securely with PayPal or Venmo, and the money goes straight to your account."* |
| **06** | **Live Webhooks & Real-Time Sync**<br>`1:10 - 1:22` | Split screen: Friend approves payment on their phone via PayPal. On the organizer's iPhone, the friend's badge instantly transitions from green `Waiting` to checkmark `Paid` without refreshing. | **Real-Time Webhooks** ⚡<br>• `PAYMENT.CAPTURE.COMPLETED`<br>• Instant state update | *"And thanks to PayPal's real-time webhooks, the exact second a friend completes payment, their status flips from 'Waiting' to 'Paid' live on your screen. No manual checks. No guessing."* |
| **07** | **Penny: Autonomous Financial Copilot**<br>`1:22 - 1:44` | Penny's AI assistant pane slides up. Shows three clean actionable cards: 1) "Send PayPal invoice to David", 2) "Refund $12.50 via PayPal to Maya", 3) "Batch payout $45 to 3 roommates". User taps one button to execute. | **Meet Penny** 💡<br>• PayPal Invoicing API<br>• PayPal Instant Refunds<br>• PayPal Batch Payouts | *"Then there's Penny, your autonomous financial copilot. If a friend forgets to pay, Penny drafts an official PayPal Invoice. Overcharged someone? Penny prepares an instant PayPal Refund. Reimbursing multiple roommates? Penny executes a batch PayPal Payout in one tap. Every action is laid out clearly, and nothing moves without your confirmation."* |
| **08** | **Closing & Hackathon Call to Action**<br>`1:44 - 1:57` | Elegant 3D rendering of the Little Wallet icon alongside PayPal and Google AI marks. Dynamic text: "Build What's Next with PayPal and AI". | **Little Wallet**<br>Spend Smarter. Split Effortlessly.<br>*PayPal AI Hackathon 2026* | *"From spoken words to completed transactions. No awkward texts. No spreadsheets. Just intelligent, effortless payments. Little Wallet: Build what's next with PayPal and AI."* |

---

## 🛠️ PayPal Platform & AI Architecture Matrix

| Hackathon Dimension | Little Wallet Implementation | Code Reference |
| :--- | :--- | :--- |
| **PayPal Orders v2** | Server-orchestrated order creation with precise item breakdown and payee attribution | [`server/index.js`](file:///Users/jiawenzhu/Developer/little-fridge-split/server/index.js#L110-L142) |
| **Live Webhooks** | Real-time `PAYMENT.CAPTURE.COMPLETED` verification and instant UI push | [`server/index.js`](file:///Users/jiawenzhu/Developer/little-fridge-split/server/index.js#L184-L207) |
| **PayPal Invoicing API** | Autonomous invoice generation for overdue debts via Penny | [`Sources/PennyActions.swift`](file:///Users/jiawenzhu/Developer/Little%20Wallet/Sources/PennyActions.swift) |
| **PayPal Refunds API** | Instant one-tap balance adjustments and transaction reversal | [`Sources/PayPalActions.swift`](file:///Users/jiawenzhu/Developer/Little%20Wallet/Sources/PayPalActions.swift) |
| **PayPal Payouts API** | Multi-party roommate and group reimbursement | [`Sources/PennyActions.swift`](file:///Users/jiawenzhu/Developer/Little%20Wallet/Sources/PennyActions.swift) |
| **Speech Intelligence** | Natural language spoken expense parsing into itemized math | [`Sources/VoiceAgent.swift`](file:///Users/jiawenzhu/Developer/Little%20Wallet/Sources/VoiceAgent.swift) |
| **Vision Intelligence** | Physical receipt document parsing and line-item categorization | [`Sources/ReceiptReader.swift`](file:///Users/jiawenzhu/Developer/Little%20Wallet/Sources/ReceiptReader.swift) |
