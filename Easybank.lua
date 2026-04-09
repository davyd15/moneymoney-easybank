-- ============================================================
-- MoneyMoney Web Banking Extension
-- EasyBank DE – banking.easybank.de
-- Version: 3.7.1
--
-- Changes in 3.7.1:
--  - All dialog and status texts translated to German
--  - Stale OTP state is now cleared at the start of each new login (Step 1)
-- Changes in 3.7.0:
--  - Confirmation prompt before SMS OTP is sent – prevents simultaneous OTP flood on multi-account refresh
-- Changes in 3.6.4:
--  - cardHistoryLoaded is now per-account (key: cardHistoryLoaded_<Number>) – fixes multi-card bug
-- Changes in 3.6.3:
--  - Skip zero-amount transactions (API returns settled authorizations as pending with amount 0)
-- Changes in 3.6.2:
--  - bookingDate/valueDate cascading fallback – MoneyMoney requires a number, never nil
-- Changes in 3.6.1:
--  - parseDate returns nil for sentinel dates (year < 1970) to avoid os.time() overflow
-- ============================================================

local BASE_URL = "https://banking.easybank.de"

WebBanking {
  version     = 3.71,
  country     = "de",
  url         = BASE_URL,
  services    = {"easybank DE"},
  description = "EasyBank Web Banking (easybank.de)",
}

local uniqueKey   = ""
local xsrfToken   = ""
local accountList = {}
local connection  = nil

function SupportsBank(protocol, bankCode)
  return bankCode == "easybank DE"
end

-- ============================================================
-- Helpers
-- ============================================================

local function ensureConnection()
  if not connection then
    connection = Connection()
  end
end

local function readXsrfToken()
  local cookies = connection:getCookies()
  if type(cookies) == "string" and #cookies > 0 then
    local token = cookies:match("XSRF%-TOKEN=([^;%s]+)")
    if token and #token > 0 then
      xsrfToken = token
      return true
    end
  end
  return false
end

local function getHeaders()
  return {
    ["Content-Type"]     = "application/json",
    ["x-xsrf-token"]     = xsrfToken,
    ["uniquekey"]        = uniqueKey,
    ["x-requested-with"] = "XMLHttpRequest",
    ["Accept"]           = "application/json, text/plain, */*",
    ["Referer"]          = BASE_URL .. "/Login",
    ["Origin"]           = BASE_URL,
  }
end

local function postJSON(path, bodyStr)
  local content = connection:request(
    "POST",
    BASE_URL .. path,
    bodyStr or "{}",
    "application/json",
    getHeaders()
  )
  readXsrfToken()
  return content
end

local function parseJSON(content)
  if not content or content == "" then return nil end
  local trimmed = content:match("^%s*(.+)$") or ""
  if trimmed:sub(1, 1) ~= "{" and trimmed:sub(1, 1) ~= "[" then return nil end
  local ok, data = pcall(function() return JSON(trimmed):dictionary() end)
  return ok and data or nil
end

local function parseDate(dateStr)
  if not dateStr or dateStr == "" then return nil end
  local y, m, d = dateStr:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if y then
    local year = tonumber(y)
    if year < 1970 then return nil end
    return os.time({ year = year, month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
  end
  return nil
end

local function currentDateISO()
  return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
end

local function dateMinusDaysISO(days)
  return os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() - days * 86400)
end

local function isCardType(accType)
  return accType == "Card" or accType == "Amazon"
end

local function jsonStr(s)
  s = tostring(s or "")
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local function findAccountList(obj, depth)
  if depth > 10 or type(obj) ~= "table" then return end
  if obj["AccountList"] then
    for _, acc in ipairs(obj["AccountList"]) do
      table.insert(accountList, acc)
    end
    return
  end
  for _, v in pairs(obj) do
    if type(v) == "table" then findAccountList(v, depth + 1) end
  end
end

local function buildAccountJson(acc)
  local bd  = acc["AvailableBalanceInLocalCurrency"] or {}
  local ld  = acc["TotalCreditLimit"] or {}
  local cld = acc["CurrentCreditLimit"] or {}

  local function val(t) return tostring(t["Value"] or 0) end
  local function cur(t)
    return jsonStr((t["Currency"] and t["Currency"]["Code"]) or "EUR")
  end

  return string.format(
    '{"Number":%s,"AccountName":%s,"IBAN":%s,"HostID":%s,' ..
    '"AccountType":%s,"AccountSubType":%s,"Ownership":%s,' ..
    '"AvailableBalanceInLocalCurrency":{"Value":%s,"Currency":{"Code":%s}},' ..
    '"TotalCreditLimit":{"Value":%s,"Currency":{"Code":%s}},' ..
    '"CurrentCreditLimit":{"Value":%s,"Currency":{"Code":%s}}}',
    jsonStr(acc["Number"] or ""),
    jsonStr(acc["AccountName"] or ""),
    jsonStr(acc["IBAN"] or ""),
    jsonStr(acc["HostID"] or ""),
    jsonStr(acc["AccountType"] or ""),
    jsonStr(acc["AccountSubType"] or ""),
    jsonStr(acc["Ownership"] or "Primary"),
    val(bd),  cur(bd),
    val(ld),  cur(ld),
    val(cld), cur(cld)
  )
end

local function saveAccToStorage(acc, prefix)
  local bd  = acc["AvailableBalanceInLocalCurrency"] or {}
  local ld  = acc["TotalCreditLimit"] or {}
  local cld = acc["CurrentCreditLimit"] or {}
  local cb  = acc["CurrentBalance"] or {}

  LocalStorage[prefix .. "Number"]         = acc["Number"] or ""
  LocalStorage[prefix .. "AccountName"]    = acc["AccountName"] or ""
  LocalStorage[prefix .. "IBAN"]           = acc["IBAN"] or ""
  LocalStorage[prefix .. "HostID"]         = acc["HostID"] or ""
  LocalStorage[prefix .. "AccountType"]    = acc["AccountType"] or ""
  LocalStorage[prefix .. "AccountSubType"] = acc["AccountSubType"] or ""
  LocalStorage[prefix .. "Ownership"]      = acc["Ownership"] or "Primary"
  LocalStorage[prefix .. "AvailVal"]       = tostring(bd["Value"] or 0)
  LocalStorage[prefix .. "AvailCur"]       = (bd["Currency"] and bd["Currency"]["Code"]) or "EUR"
  LocalStorage[prefix .. "TotalLimit"]     = tostring(ld["Value"] or 0)
  LocalStorage[prefix .. "TotalLimitCur"]  = (ld["Currency"] and ld["Currency"]["Code"]) or "EUR"
  LocalStorage[prefix .. "CurrLimit"]      = tostring(cld["Value"] or 0)
  LocalStorage[prefix .. "CurrLimitCur"]   = (cld["Currency"] and cld["Currency"]["Code"]) or "EUR"
  LocalStorage[prefix .. "CurrentBalance"] = tostring(cb["Value"] or 0)
end

local function loadAccFromStorage(prefix)
  if not LocalStorage[prefix .. "Number"] or LocalStorage[prefix .. "Number"] == "" then
    return nil
  end
  local availCur = LocalStorage[prefix .. "AvailCur"] or "EUR"
  return {
    ["Number"]         = LocalStorage[prefix .. "Number"],
    ["AccountName"]    = LocalStorage[prefix .. "AccountName"] or "",
    ["IBAN"]           = LocalStorage[prefix .. "IBAN"] or "",
    ["HostID"]         = LocalStorage[prefix .. "HostID"] or "",
    ["AccountType"]    = LocalStorage[prefix .. "AccountType"] or "",
    ["AccountSubType"] = LocalStorage[prefix .. "AccountSubType"] or "",
    ["Ownership"]      = LocalStorage[prefix .. "Ownership"] or "Primary",
    ["AvailableBalanceInLocalCurrency"] = {
      ["Value"]    = tonumber(LocalStorage[prefix .. "AvailVal"] or "0") or 0,
      ["Currency"] = { ["Code"] = availCur },
    },
    ["TotalCreditLimit"] = {
      ["Value"]    = tonumber(LocalStorage[prefix .. "TotalLimit"] or "0") or 0,
      ["Currency"] = { ["Code"] = LocalStorage[prefix .. "TotalLimitCur"] or availCur },
    },
    ["CurrentCreditLimit"] = {
      ["Value"]    = tonumber(LocalStorage[prefix .. "CurrLimit"] or "0") or 0,
      ["Currency"] = { ["Code"] = LocalStorage[prefix .. "CurrLimitCur"] or availCur },
    },
    ["CurrentBalance"] = {
      ["Value"]    = tonumber(LocalStorage[prefix .. "CurrentBalance"] or "0") or 0,
      ["Currency"] = { ["Code"] = availCur },
    },
  }
end

local function loadAccountListFromStorage()
  local count = tonumber(LocalStorage.accountCount or "0") or 0
  for i = 1, count do
    local acc = loadAccFromStorage("acc" .. i .. "_")
    if acc then table.insert(accountList, acc) end
  end
end

local function buildTransactionList(txList)
  local transactions = {}
  for _, tx in ipairs(txList or {}) do
    local amountData = tx["LocalCurrencyAmount"] or tx["Amount"] or {}
    local amount     = tonumber(amountData["Value"]) or 0

    if (tx["TransactionNature"] or "") == "Debit" then
      amount = -math.abs(amount)
    else
      amount = math.abs(amount)
    end

    -- Skip zero-amount entries: API returns settled authorizations as pending/unbilled with amount 0
    if amount == 0 then goto continue end

    local description  = tx["Description"] or ""
    local merchantName = tx["MerchantName"] or ""
    local txName, purpose

    if merchantName ~= "" then
      local firstLine  = merchantName:match("^([^\n]+)") or merchantName
      local extraLines = merchantName:match("^[^\n]+\n(.+)$") or ""
      txName = firstLine
      if description ~= "" and description ~= firstLine and description ~= merchantName then
        purpose = description
      elseif extraLines ~= "" then
        purpose = extraLines:gsub("\n", " ")
      else
        purpose = ""
      end
    else
      txName  = description ~= "" and description or "Unknown"
      purpose = ""
    end

    -- Fix: Currency.Code can be "" for some bank-internal transactions (e.g. credit postings)
    local txCurrency = "EUR"
    if type(amountData["Currency"]) == "table" then
      local code = amountData["Currency"]["Code"]
      if code and code ~= "" then txCurrency = code end
    end

    local txType = tx["TransactionType"] or ""
    local booked = txType ~= "Pending" and txType ~= "Unbilled"

    table.insert(transactions, {
      name        = txName,
      purpose     = purpose,
      amount      = amount,
      currency    = txCurrency,
      bookingDate = parseDate(tx["PostingDate"]) or parseDate(tx["TransactionDate"]) or parseDate(tx["ValueDate"]) or os.time(),
      valueDate   = parseDate(tx["ValueDate"])   or parseDate(tx["TransactionDate"]) or os.time(),
      booked      = booked,
    })
    ::continue::
  end
  return transactions
end

local function getBalance(accData, isCard)
  if isCard then
    local cb = accData["CurrentBalance"]
    return cb and tonumber(cb["Value"]) or 0
  else
    local bd = accData["AvailableBalanceInLocalCurrency"]
    return bd and tonumber(bd["Value"]) or 0
  end
end

local function buildTxBody(accJson, startDate, endDate, pageIndex, currency, tan)
  local otp = tan and ('{"Password":' .. jsonStr(tan) .. '}') or '{}'
  return string.format(
    '{"Account":%s,"StartDate":"%s","EndDate":"%s",' ..
    '"TransactionFlag":"All","TransactionTypeIndicator":0,' ..
    '"Status":"ALL","OTPAlreadyChecked":false,' ..
    '"PageSize":50,"PageIndex":%d,"Take":50,"Skip":%d,' ..
    '"TwoFactorAuthentication":%s,"Currency":"%s"}',
    accJson, startDate, endDate,
    pageIndex, pageIndex * 50,
    otp, currency or "EUR"
  )
end

local CONFIRM_OTP_PROMPT = {
  title     = "SMS TAN anfordern?",
  challenge = "Für den vollständigen Kreditkartenverlauf ist eine SMS TAN erforderlich.\n\n"
            .. "Klicken Sie auf Fertig, um die SMS jetzt zu senden\n"
            .. "(verhindert gleichzeitige SMS-Anfragen bei einem Rundruf).",
  label     = "Bestätigung",
}

local OTP_PROMPT = {
  title     = "SMS TAN für Kreditkartenumsätze",
  challenge = "Eine SMS TAN wurde an Ihr Mobiltelefon gesendet.\n\n"
            .. "Bitte geben Sie die TAN ein, um den vollständigen\n"
            .. "Kreditkartenverlauf zu laden:",
  label     = "SMS TAN",
}

-- ============================================================
-- InitializeSession2
-- ============================================================

function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  ensureConnection()

  if step == 1 then
    local username = credentials[1]
    local password = credentials[2]

    if not username or username == "" or not password or password == "" then
      return LoginFailed
    end

    -- Clear any stale OTP state from a previous session
    LocalStorage.cardAccNum        = nil
    LocalStorage.startDate         = nil
    LocalStorage.endDate           = nil
    LocalStorage.otpTries          = nil
    LocalStorage.otpConfirmPending = nil

    local html = connection:get(BASE_URL .. "/Login")
    uniqueKey = (html or ""):match("VeriBranch%.Config%.UniqueKey%s*=%s*'([^']+)'") or ""
    readXsrfToken()

    if uniqueKey == "" then return LoginFailed end

    postJSON("/services/flow/LoginTransaction")

    local loginContent = postJSON(
      "/services/flow/logintransaction/firstlevel/next",
      string.format(
        '{"UserName":%s,"Password":%s,"IsCaptchaRequired":true,' ..
        '"OTPPassword":"","SkipAuthenticationItem":false,' ..
        '"IsNotLoginTransaction":false,"SelectedApprovalRule":0,' ..
        '"SelectedApprovalSubRule":0}',
        jsonStr(username), jsonStr(password)
      )
    )

    local loginData = parseJSON(loginContent)
    if not loginData then return LoginFailed end

    local result = loginData["Result"]
    if result and result["IsSuccess"] == false then return LoginFailed end

    local item = loginData["Item"]
    if item and item["Response"] then
      local newKey = item["Response"]["UniqueKey"]
      if newKey and newKey ~= "" then uniqueKey = newKey end
    end

    postJSON("/call/flow/Login/AfterLogin", string.format(
      '{"UserName":%s,"Password":null,"IsCaptchaRequired":true,' ..
      '"CustomerType":"Retail","LandingPage":"Dashboard"}',
      jsonStr(username)
    ))

    local landingData = parseJSON(postJSON("/services/flow/RetailLanding"))
    accountList = {}
    if landingData then findAccountList(landingData, 0) end

    LocalStorage.uniqueKey    = uniqueKey
    LocalStorage.xsrfToken    = xsrfToken
    LocalStorage.accountCount = tostring(#accountList)
    for i, acc in ipairs(accountList) do
      saveAccToStorage(acc, "acc" .. i .. "_")
    end

    if LocalStorage.historyLoaded == "yes" then
      MM.printStatus("Anmeldung erfolgreich.")
      return nil
    end

    local cardAcc = nil
    for _, acc in ipairs(accountList) do
      if isCardType(acc["AccountType"] or "") then
        cardAcc = acc
        break
      end
    end

    if not cardAcc then
      MM.printStatus("Anmeldung erfolgreich.")
      return nil
    end

    local accJson        = buildAccountJson(cardAcc)
    local otpStartDate   = dateMinusDaysISO(360)
    local otpEndDate     = currentDateISO()

    postJSON("/services/flow/AccountTransactionHistory", '{"Account":' .. accJson .. '}')

    local txData = parseJSON(postJSON(
      "/call/directive/TransactionViewDirective/GetTransactions",
      buildTxBody(accJson, otpStartDate, otpEndDate, 0, "EUR")
    ))
    local txItem = txData and (txData["Item"] or txData)

    if txItem and txItem["OTPRequired"] == true then
      LocalStorage.cardAccNum        = cardAcc["Number"] or ""
      LocalStorage.startDate         = otpStartDate
      LocalStorage.endDate           = otpEndDate
      LocalStorage.xsrfToken         = xsrfToken
      LocalStorage.uniqueKey         = uniqueKey
      LocalStorage.otpConfirmPending = "yes"

      return CONFIRM_OTP_PROMPT
    end

    if txItem and txItem["OTPRequired"] ~= true then
      LocalStorage.historyLoaded = "yes"
    end

    MM.printStatus("Anmeldung erfolgreich.")
    return nil
  end

  if step == 2 then
    uniqueKey = LocalStorage.uniqueKey or uniqueKey
    xsrfToken = LocalStorage.xsrfToken or xsrfToken

    local cardAccNum = LocalStorage.cardAccNum
    if not cardAccNum or cardAccNum == "" then
      MM.printStatus("Anmeldung erfolgreich.")
      return nil
    end

    -- User confirmed → now send the OTP
    if LocalStorage.otpConfirmPending == "yes" then
      postJSON("/call/directive/VbOtpboxDirective/SendOTP")
      LocalStorage.otpConfirmPending = nil
      LocalStorage.otpTries          = "0"
      return OTP_PROMPT
    end

    MM.printStatus("Anmeldung erfolgreich.")
    return nil
  end

  if step == 3 then
    uniqueKey = LocalStorage.uniqueKey or uniqueKey
    xsrfToken = LocalStorage.xsrfToken or xsrfToken

    local cardAccNum = LocalStorage.cardAccNum
    if not cardAccNum or cardAccNum == "" then
      MM.printStatus("Anmeldung erfolgreich.")
      return nil
    end

    if #accountList == 0 then loadAccountListFromStorage() end

    local cardAcc = nil
    for _, acc in ipairs(accountList) do
      if acc["Number"] == cardAccNum then
        cardAcc = acc
        break
      end
    end

    if not cardAcc then
      MM.printStatus("Kreditkarte nicht gefunden – Anmeldung OK.")
      return nil
    end

    local tan = credentials[1] or ""
    tan = tan:match("^%s*(.-)%s*$") or ""

    if tan == "" then
      return { title = "TAN erforderlich", challenge = "Bitte geben Sie die SMS TAN ein:", label = "SMS TAN" }
    end

    local accJson = buildAccountJson(cardAcc)
    local txData  = parseJSON(postJSON(
      "/call/directive/TransactionViewDirective/GetTransactions",
      buildTxBody(accJson, LocalStorage.startDate, LocalStorage.endDate, 0, "EUR", tan)
    ))
    local txItem = txData and (txData["Item"] or txData)

    if not txItem or txItem["OTPRequired"] == true then
      local tries = (tonumber(LocalStorage.otpTries or "0") or 0) + 1
      LocalStorage.otpTries = tostring(tries)

      if tries >= 3 then
        LocalStorage.otpTries   = nil
        LocalStorage.cardAccNum = nil
        MM.printStatus("TAN dreimal falsch – Anmeldung ohne vollständigen Verlauf.")
        return nil
      end

      return {
        title     = string.format("Ungültige TAN (%d/3)", tries),
        challenge = "Die TAN ist ungültig oder abgelaufen.\n\nBitte geben Sie die SMS TAN erneut ein:",
        label     = "SMS TAN",
      }
    end

    LocalStorage.historyLoaded = "yes"
    LocalStorage.otpTries      = nil
    LocalStorage.cardAccNum    = nil

    MM.printStatus("Umsatzhistorie bestätigt.")
    return nil
  end

  return LoginFailed
end

-- ============================================================
-- ListAccounts
-- ============================================================

function ListAccounts(knownAccounts)
  ensureConnection()

  if #accountList == 0 then loadAccountListFromStorage() end

  local accounts = {}
  for _, acc in ipairs(accountList) do
    local accType = acc["AccountType"] or ""
    local accountType
    if isCardType(accType) then
      accountType = AccountTypeCreditCard
    elseif accType == "Loan" then
      accountType = AccountTypeLoan
    else
      accountType = AccountTypeOther
    end

    local bd       = acc["AvailableBalanceInLocalCurrency"] or {}
    local currency = (bd["Currency"] and bd["Currency"]["Code"]) or "EUR"

    local account = {
      name          = acc["AccountName"] or acc["Number"] or "Unknown",
      accountNumber = acc["Number"] or "",
      iban          = acc["IBAN"] or "",
      currency      = currency,
      type          = accountType,
    }

    local ld = acc["TotalCreditLimit"]
    if ld and ld["Value"] then account.creditLimit = ld["Value"] end

    table.insert(accounts, account)
  end
  return accounts
end

-- ============================================================
-- RefreshAccount
-- ============================================================

function RefreshAccount(account, since)
  ensureConnection()

  if uniqueKey == "" then uniqueKey = LocalStorage.uniqueKey or "" end
  if xsrfToken == "" then xsrfToken = LocalStorage.xsrfToken or "" end
  readXsrfToken()

  if #accountList == 0 then loadAccountListFromStorage() end

  local accData = nil
  for _, acc in ipairs(accountList) do
    if (acc["IBAN"] or "") == account.iban or
       (acc["Number"] or "") == account.accountNumber then
      accData = acc
      break
    end
  end
  if not accData then
    error("Account not found: " .. (account.accountNumber or "?"))
  end

  local accJson  = buildAccountJson(accData)
  local isCard   = isCardType(accData["AccountType"] or "")
  local currency = account.currency or "EUR"

  postJSON("/services/flow/AccountTransactionHistory", '{"Account":' .. accJson .. '}')

  -- Full 360-day history on first run for credit cards (flag is per-account)
  local cardHistoryKey = "cardHistoryLoaded_" .. (accData["Number"] or "")
  if isCard and LocalStorage[cardHistoryKey] ~= "yes" then
    MM.printStatus("Lade vollständigen Kreditkartenverlauf...")

    local allTransactions = {}
    local pageIndex       = 0
    local allPagesOk      = true
    local histStartDate   = dateMinusDaysISO(360)
    local histEndDate     = currentDateISO()

    repeat
      local txData = parseJSON(postJSON(
        "/call/directive/TransactionViewDirective/GetTransactions",
        buildTxBody(accJson, histStartDate, histEndDate, pageIndex, currency)
      ))

      if not txData then
        MM.printStatus("Fehler beim Laden von Seite " .. (pageIndex + 1))
        allPagesOk = false
        break
      end

      local txItem = txData["Item"] or txData

      if txItem["OTPRequired"] == true then
        MM.printStatus("OTP erforderlich – wird beim nächsten Login erneut angefordert.")
        LocalStorage.historyLoaded       = nil
        LocalStorage[cardHistoryKey]     = nil
        return { balance = getBalance(accData, true), transactions = {} }
      end

      local page = buildTransactionList(txItem["Transactions"] or {})
      for _, tx in ipairs(page) do
        allTransactions[#allTransactions + 1] = tx
      end

      MM.printStatus(string.format("Seite %d: %d Umsätze geladen", pageIndex + 1, #allTransactions))

      if txItem["HasMore"] ~= true then break end
      pageIndex = pageIndex + 1
    until false

    if allPagesOk then
      LocalStorage[cardHistoryKey] = "yes"
    end

    return { balance = getBalance(accData, true), transactions = allTransactions }
  end

  -- Incremental sync
  local syncEndDate   = currentDateISO()
  local syncStartDate

  if isCard then
    if since and since > 0 then
      local daysSince = math.floor((os.time() - since) / 86400)
      syncStartDate = daysSince <= 30
        and os.date("!%Y-%m-%dT%H:%M:%S.000Z", since)
        or  dateMinusDaysISO(30)
    else
      syncStartDate = dateMinusDaysISO(30)
    end
  else
    syncStartDate = (since and since > 0)
      and os.date("!%Y-%m-%dT%H:%M:%S.000Z", since)
      or  dateMinusDaysISO(360)
  end

  local allTransactions = {}
  local pageIndex       = 0

  repeat
    local txData = parseJSON(postJSON(
      "/call/directive/TransactionViewDirective/GetTransactions",
      buildTxBody(accJson, syncStartDate, syncEndDate, pageIndex, currency)
    ))

    if not txData then
      MM.printStatus("Keine Umsatzdaten: " .. (account.accountNumber or "?"))
      break
    end

    local txItem = txData["Item"] or txData

    if txItem["OTPRequired"] == true then
      MM.printStatus("OTP erforderlich – wird beim nächsten Login erneut angefordert.")
      LocalStorage.historyLoaded   = nil
      LocalStorage[cardHistoryKey] = nil
      return { balance = getBalance(accData, isCard), transactions = {} }
    end

    local page = buildTransactionList(txItem["Transactions"] or {})
    for _, tx in ipairs(page) do
      allTransactions[#allTransactions + 1] = tx
    end

    if txItem["HasMore"] ~= true then break end
    pageIndex = pageIndex + 1
  until false

  return {
    balance      = getBalance(accData, isCard),
    transactions = allTransactions,
  }
end

-- ============================================================
-- EndSession
-- ============================================================

function EndSession()
  pcall(function()
    postJSON("/call/flow/Login/Logout")
  end)

  connection  = nil
  uniqueKey   = ""
  xsrfToken   = ""
  accountList = {}

  LocalStorage.uniqueKey         = nil
  LocalStorage.xsrfToken         = nil
  LocalStorage.cardAccNum        = nil
  LocalStorage.startDate         = nil
  LocalStorage.endDate           = nil
  LocalStorage.otpTries          = nil
  LocalStorage.otpConfirmPending = nil
  LocalStorage.cardHistoryLoaded = nil  -- migrate: remove old global flag (replaced by per-account keys)

  -- Intentionally kept: historyLoaded, cardHistoryLoaded_*, accountCount, acc*_
end
