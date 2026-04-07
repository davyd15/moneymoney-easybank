# MoneyMoney Extension – EasyBank

A [MoneyMoney](https://moneymoney-app.com) extension for **EasyBank** that imports account balances and transactions from the [EasyBank Online Banking](https://banking.easybank.de) portal.

---

## Features

- Supports **credit card, loan, and other** accounts in EUR
- Fetches up to **360 days** of transaction history on first run, then syncs incrementally
- Confirmation prompt before sending the SMS TAN — prevents all accounts from triggering an SMS simultaneously when refreshing in bulk
- Per-account history flags so each credit card can be initialized independently
- Filters zero-amount ghost entries (settled authorizations the API returns as pending with amount 0)

## How It Works

The extension implements MoneyMoney's `WebBanking` Lua API and communicates with the VeriBranch banking platform at `banking.easybank.de`.

### Authentication

Login completes in a single step for most sessions. On the very first run with a credit card that requires an OTP, the flow extends to three steps.

| Step | Action |
|------|--------|
| 1 | `GET /Login` → extract `VeriBranch.Config.UniqueKey` from embedded JS |
| 1 | `POST /services/flow/LoginTransaction` → init session, receive XSRF cookie |
| 1 | `POST /services/flow/logintransaction/firstlevel/next` with username + password |
| 1 | `POST /call/flow/Login/AfterLogin` → finalize login |
| 1 | `POST /services/flow/RetailLanding` → load account list |
| 1 | `POST /call/directive/TransactionViewDirective/GetTransactions` → probe whether OTP is required |
| 2 | *(OTP path only)* User confirms → `POST /call/directive/VbOtpboxDirective/SendOTP` → SMS sent |
| 3 | *(OTP path only)* User enters TAN → resubmitted with transaction request to unlock full history |

Every request carries three custom headers: `x-xsrf-token` (refreshed from the `XSRF-TOKEN` cookie after each POST), `uniquekey` (extracted from the login page JS), and `x-requested-with: XMLHttpRequest`.

The password is kept in RAM only during Step 1 and is never written to LocalStorage.

### Data Retrieval

- **Accounts:** `POST /services/flow/RetailLanding` (during login) — account list is cached in LocalStorage
- **Transactions:** `POST /call/directive/TransactionViewDirective/GetTransactions`, paginated at 50 per page (`HasMore` flag drives pagination)

On first run for a credit card, the extension fetches the full 360-day history. Subsequent syncs are incremental from the last-sync date (capped at 30 days for cards, up to 360 days for other account types). A per-account flag (`cardHistoryLoaded_<Number>` in LocalStorage) tracks whether the initial full load has completed, so each card is managed independently.

## Requirements

- [MoneyMoney](https://moneymoney-app.com) for macOS (any recent version)
- An **EasyBank Online Banking** account
- Your **EasyBank username** and **password**

> **Note:** This extension connects to **banking.easybank.de** and uses the corresponding login credentials.

## Installation

### Option A — Direct download

1. Download [`Easybank.lua`](Easybank.lua)
2. Move it into MoneyMoney's Extensions folder:
   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```
3. Reload extensions: right-click any account in MoneyMoney → **Reload Extensions** (or restart the app)

### Option B — Clone the repository

```bash
git clone https://github.com/davyd15/moneymoney-easybank.git
cp moneymoney-easybank/Easybank.lua \
  ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/
```

## Setup in MoneyMoney

1. Open MoneyMoney → **File → Add Account…**
2. Search for **"EasyBank"**
3. Select **EasyBank Web Banking (easybank.de)**
4. Enter your **EasyBank username** and **password**, then click **Fertig**
5. MoneyMoney will connect and import your accounts

If this is the first time adding a credit card account and the portal requires an SMS TAN, two additional prompts follow:

- **Step 2 — Confirm:** A dialog explains that an SMS TAN will be sent. Enter anything in the input field and click **Fertig** to trigger the SMS.
- **Step 3 — Enter TAN:** Enter the SMS TAN you received and click **Fertig**.

After this one-time setup, subsequent logins require only username and password.

## Supported Account Types

| Type | Description |
|------|-------------|
| Credit card (`Card`, `Amazon`) | Credit cards and Amazon co-branded cards — balance from `CurrentBalance` |
| Loan (`Loan`) | Loan accounts |
| Other | Checking, savings, and all remaining account types — balance from `AvailableBalanceInLocalCurrency` |

## Limitations

- **EUR only** — foreign currency sub-accounts are not explicitly supported
- **360-day initial history** per account (portal limitation); subsequent syncs are incremental
- The SMS TAN is only required once per credit card — subsequent logins and refreshes do not trigger an OTP

## Troubleshooting

**"Login failed" / credentials rejected**
- Verify your credentials by logging in directly at [banking.easybank.de](https://banking.easybank.de)
- Make sure you are not accidentally using easybank.at (Austria) credentials

**Extension not appearing in MoneyMoney**
- Confirm the `.lua` file is in the correct Extensions folder (see Installation above)
- Reload extensions or restart MoneyMoney

**Transactions missing / history too short**
- The portal limits history to 360 days on the initial load. Older transactions cannot be retrieved.

**SMS TAN prompt appears unexpectedly**
- This can happen if MoneyMoney's LocalStorage was cleared (e.g. by removing and re-adding the account). The one-time setup will run again automatically.

## Changelog

| Version | Changes |
|---------|---------|
| 3.7.0 | Confirmation prompt before SMS OTP is sent — prevents simultaneous OTP flood on multi-account refresh |
| 3.6.4 | `cardHistoryLoaded` is now per-account (`cardHistoryLoaded_<Number>`) — fixes multi-card bug |
| 3.6.3 | Skip zero-amount transactions (API returns settled authorizations as pending with amount 0) |
| 3.6.2 | `bookingDate`/`valueDate` cascading fallback — MoneyMoney requires a number, never nil |
| 3.6.1 | `parseDate` returns nil for sentinel dates (year < 1970) to avoid `os.time()` overflow |

## Contributing

Bug reports and pull requests are welcome. If EasyBank changes its login flow or API, please open an issue with the MoneyMoney log output — that makes it much easier to diagnose.

To test changes locally, copy the `.lua` file into the Extensions folder and reload extensions in MoneyMoney.

## Disclaimer

This extension is an independent community project and is **not affiliated with, endorsed by, or supported by EasyBank** or the MoneyMoney developers. Use at your own risk. Credentials are handled solely by MoneyMoney's built-in secure storage and are never transmitted to any third party.

## License

MIT — see [LICENSE](LICENSE)
