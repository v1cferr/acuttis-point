import { Result$Ok, Result$Error } from "../gleam.mjs";
import { chromium } from "playwright-core";

// Details go into a log, so they are capped: a Playwright error can otherwise
// carry a page snapshot, and a log line is not the place for one.
const DETAIL_LIMIT = 300;

// How long to give the receipt's rows before concluding there are none. Short
// on purpose: rows either render promptly or the selector no longer matches,
// and the whole step timeout would be spent waiting to say so.
const ROW_WAIT_MS = 5000;

const ok = (value) => Result$Ok(value);

const fail = (kind, detail) =>
  Result$Error([kind, String(detail).replace(/\s+/g, " ").slice(0, DETAIL_LIMIT)]);

const isTimeout = (error) =>
  error?.name === "TimeoutError" || /Timeout .* exceeded/.test(error?.message ?? "");

const onSignInPage = (page) => new URL(page.url()).pathname.startsWith("/signin");

export async function open(headless, timeoutMs) {
  try {
    const browser = await chromium.launch({ headless });
    const context = await browser.newContext({
      locale: "pt-BR",
      timezoneId: "America/Sao_Paulo",
    });
    context.setDefaultTimeout(timeoutMs);
    const page = await context.newPage();
    return ok({ browser, context, page });
  } catch (error) {
    return fail("launch", error.message);
  }
}

export async function signIn(
  session,
  baseUrl,
  usernameSelector,
  passwordSelector,
  submitSelector,
  username,
  password,
) {
  const { page } = session;

  try {
    await page.goto(`${baseUrl}/dashboard`, { waitUntil: "domcontentloaded" });
  } catch (error) {
    return isTimeout(error)
      ? fail("timeout", "loading the dashboard")
      : fail("unreachable", error.message);
  }

  // Acuttis sends an unauthenticated visitor to /signin. Landing anywhere else
  // means a session is already in place and there is nothing to sign in to.
  if (!onSignInPage(page)) {
    return ok(undefined);
  }

  try {
    await page.waitForSelector(usernameSelector, { state: "visible" });
    await page.fill(usernameSelector, username);
    await page.fill(passwordSelector, password);
  } catch (error) {
    return isTimeout(error)
      ? fail("interface", `the sign-in form (${usernameSelector})`)
      : fail("interface", error.message);
  }

  try {
    // The submit button starts disabled and the application enables it once the
    // fields validate, so this waits rather than clicking into the void.
    await page.click(submitSelector);
  } catch (error) {
    return isTimeout(error)
      ? fail("interface", `an enabled submit button (${submitSelector})`)
      : fail("interface", error.message);
  }

  try {
    await page.waitForURL((url) => !url.pathname.startsWith("/signin"));
  } catch {
    // Still on the form: the application rejected the credentials, since a
    // network problem would have failed the navigation above instead.
    return fail("auth", "still on the sign-in page after submitting");
  }

  // Leaving the sign-in route only means the application switched views. It
  // still has to fetch the day, and reading before that lands would report an
  // empty day that is only empty yet.
  await page.waitForLoadState("networkidle").catch(() => {});

  return ok(undefined);
}

export async function punchTexts(
  session,
  triggerSelector,
  modalSelector,
  receiptSelector,
  listSelector,
) {
  const { page } = session;

  const blocked = await openReceipt(
    page,
    triggerSelector,
    modalSelector,
    receiptSelector,
    listSelector,
  );
  if (blocked) return blocked;

  try {
    // Every row of the receipt, across all the days it lists. Which of them
    // belong to today is decided in Gleam, where it is tested — and where an
    // empty result can be told apart from a selector that stopped matching.
    const texts = await page.locator(listSelector).allTextContents();
    return ok(texts.map((text) => text.replace(/\s+/g, " ").trim()));
  } catch (error) {
    return isTimeout(error)
      ? fail("timeout", `reading the punch list (${listSelector})`)
      : fail("interface", error.message);
  }
}

// Called straight after `punchTexts`, so the receipt is on screen and its rows
// can be counted before anything is clicked.
export async function registerPunch(
  session,
  triggerSelector,
  modalSelector,
  receiptSelector,
  backSelector,
  buttonSelector,
  listSelector,
) {
  const { page } = session;

  // The newest row as it stands, so the click can be waited out by watching for
  // it to change. Counting rows would not work: Acuttis caps the receipt at
  // twenty, so a new punch pushes the oldest out and the count never grows.
  const topBefore = (
    await page
      .locator(listSelector)
      .first()
      .textContent()
      .catch(() => "")
  )?.trim();

  const blocked = await openPunchInterface(page, triggerSelector, modalSelector);
  if (blocked) return blocked;

  // The punch controls and the receipt are two views of the same modal, so
  // having just read the day leaves the wrong one showing.
  if (backSelector) {
    const back = page.locator(backSelector).first();
    if (await back.isVisible().catch(() => false)) {
      try {
        await back.click();
      } catch (error) {
        return fail(
          "interface",
          `could not leave the receipt: ${error.message}`,
        );
      }
    }
  }

  const button = page.locator(buttonSelector).first();

  try {
    await button.waitFor({ state: "visible" });
  } catch (error) {
    return isTimeout(error)
      ? fail("interface", `the punch button (${buttonSelector})`)
      : fail("interface", error.message);
  }

  if (await button.isDisabled()) {
    return fail("unavailable", "the punch button is disabled");
  }

  try {
    await button.click();
  } catch (error) {
    return isTimeout(error)
      ? fail("unavailable", "the punch button never became clickable")
      : fail("unavailable", error.message);
  }

  // Back to the receipt so the caller can read the day again.
  const reopened = await openReceipt(
    page,
    triggerSelector,
    modalSelector,
    receiptSelector,
    listSelector,
  );
  if (reopened) return reopened;

  // Give the new punch a chance to reach the top of the list. Best effort on
  // purpose: whether the punch actually landed is decided by reading the day
  // back, not here, and a slow refresh must not be reported as a failed punch.
  await page
    .waitForFunction(
      ({ selector, previous }) => {
        const newest = document.querySelector(selector);
        return newest && newest.textContent.trim() !== previous;
      },
      { selector: listSelector, previous: topBefore ?? "" },
      { timeout: ROW_WAIT_MS },
    )
    .catch(() => {});

  return ok(undefined);
}

export async function close(session) {
  try {
    await session.browser.close();
  } catch {
    // A run has already happened or not by now; there is nothing left to save.
  }
  return undefined;
}

/// Returns a failure, or null once the punch list is on screen.
///
/// Acuttis keeps the punch controls and the receipt in the same modal, so the
/// list takes two steps to reach: open the modal, then switch to the receipt.
/// Either step can be configured away for a deployment that needs neither.
async function openReceipt(
  page,
  triggerSelector,
  modalSelector,
  receiptSelector,
  listSelector,
) {
  const blocked = await openPunchInterface(page, triggerSelector, modalSelector);
  if (blocked) return blocked;

  if (!receiptSelector) return null;

  // Already showing: reading twice in one run must not toggle the view back.
  if (await page.locator(listSelector).first().isVisible().catch(() => false)) {
    return null;
  }

  const receipt = page.locator(receiptSelector).first();

  try {
    await receipt.waitFor({ state: "visible" });
    await receipt.click();
  } catch (error) {
    if (onSignInPage(page)) return fail("expired", "");
    return isTimeout(error)
      ? fail("interface", `the punch receipt (${receiptSelector})`)
      : fail("interface", error.message);
  }

  // The receipt fetches its rows, and a quiet network is not a reliable signal
  // for that: the request is issued by the click handler, so the network can
  // still look idle at the moment it is asked. Wait for a row instead, and let
  // the absence of one be reported as such rather than waited on forever.
  await page
    .locator(listSelector)
    .first()
    .waitFor({ state: "attached", timeout: ROW_WAIT_MS })
    .catch(() => {});

  return null;
}

/// Returns a failure, or null once the punch interface is on screen.
async function openPunchInterface(page, triggerSelector, modalSelector) {
  // No trigger configured means the punches are already on the page. Nothing is
  // clicked, which is what leaves a dry run provably unable to punch.
  if (!triggerSelector) return null;

  const modal = modalSelector ? page.locator(modalSelector).first() : null;

  if (modal && (await modal.isVisible().catch(() => false))) {
    return null;
  }

  const trigger = page.locator(triggerSelector).first();

  try {
    await trigger.waitFor({ state: "visible" });
  } catch (error) {
    // Being back on the sign-in form mid-run means the session went away.
    if (onSignInPage(page)) return fail("expired", "");
    return isTimeout(error)
      ? fail("interface", `the punch trigger (${triggerSelector})`)
      : fail("interface", error.message);
  }

  try {
    await trigger.click();
    if (modal) await modal.waitFor({ state: "visible" });
  } catch (error) {
    return isTimeout(error)
      ? fail("interface", `the punch interface (${modalSelector})`)
      : fail("interface", error.message);
  }

  return null;
}

// Everything below only reads. A hidden element is still in the DOM, which is
// why this can find the punch rows without opening anything.
export async function describePage(session, triggerSelector, modalSelector) {
  const { page } = session;

  await page.waitForLoadState("networkidle").catch(() => {});

  try {
    const lines = await page.evaluate(
      ([trigger, modal]) => {
        const out = [];

        const count = (selector) => {
          try {
            return document.querySelectorAll(selector).length;
          } catch {
            return -1;
          }
        };

        const visibleCount = (selector) => {
          try {
            return Array.from(document.querySelectorAll(selector)).filter(
              (element) =>
                !!(element.offsetParent || element.getClientRects().length),
            ).length;
          } catch {
            return -1;
          }
        };

        out.push(`url: ${location.pathname}`);
        if (trigger) {
          out.push(
            `PUNCH_TRIGGER_SELECTOR "${trigger}" matches ${count(trigger)}, ${visibleCount(trigger)} visible`,
          );
        }
        if (modal) {
          out.push(
            `PUNCH_MODAL_SELECTOR "${modal}" matches ${count(modal)}, ${visibleCount(modal)} visible`,
          );
        }

        const TIME = /\b([01][0-9]|2[0-3]):[0-5][0-9]\b/;
        const holdsTime = (element) => TIME.test(element.textContent || "");

        // The innermost elements holding a time, plus their parents: for a row
        // like <div class="row"><span>08:03</span></div> the row is usually
        // what PUNCH_LIST_SELECTOR wants, and the span is what finds it.
        const leaves = Array.from(document.querySelectorAll("body *")).filter(
          (element) =>
            holdsTime(element) &&
            !Array.from(element.children).some(holdsTime),
        );

        const selectorFor = (element) =>
          element.tagName.toLowerCase() +
          Array.from(element.classList)
            .map((name) => `.${CSS.escape(name)}`)
            .join("");

        const candidates = new Map();
        for (const leaf of leaves) {
          const texts = [leaf, leaf.parentElement].filter(Boolean);
          for (const element of texts) {
            const candidate = selectorFor(element);
            if (!candidates.has(candidate)) candidates.set(candidate, new Set());
            candidates
              .get(candidate)
              .add(
                (leaf.textContent || "").replace(/\s+/g, " ").trim().slice(0, 40),
              );
          }
        }

        if (candidates.size === 0) {
          out.push(
            "no element on this page holds an HH:MM time — either no punch is registered today, or this is the wrong page",
          );
          return out;
        }

        out.push("candidates for PUNCH_LIST_SELECTOR:");
        for (const [candidate, texts] of candidates) {
          const matches = count(candidate);
          // A selector matching half the page is not a punch list.
          if (matches > 20) continue;
          out.push(
            `  ${candidate}  matches ${matches}, ${visibleCount(candidate)} visible  e.g. ${Array.from(
              texts,
            )
              .slice(0, 4)
              .join(" | ")}`,
          );
        }
        return out;
      },
      [triggerSelector, modalSelector],
    );

    return ok(lines);
  } catch (error) {
    return isTimeout(error)
      ? fail("timeout", "reading the page")
      : fail("interface", error.message);
  }
}
