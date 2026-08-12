import { Result$Ok, Result$Error } from "../gleam.mjs";
import { chromium } from "playwright-core";

// Details go into a log, so they are capped: a Playwright error can otherwise
// carry a page snapshot, and a log line is not the place for one.
const DETAIL_LIMIT = 300;

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

  return ok(undefined);
}

export async function punchTexts(
  session,
  triggerSelector,
  modalSelector,
  listSelector,
) {
  const { page } = session;

  const blocked = await openPunchInterface(page, triggerSelector, modalSelector);
  if (blocked) return blocked;

  try {
    // No matches means the day has not started yet, which is a legitimate
    // reading rather than an error. A selector that has silently stopped
    // matching looks the same from here, but not for long: the decision rules
    // then see an empty day and refuse to register a punch whose window has
    // already closed.
    const texts = await page.locator(listSelector).allTextContents();
    return ok(texts.map((text) => text.replace(/\s+/g, " ").trim()));
  } catch (error) {
    return isTimeout(error)
      ? fail("timeout", `reading the punch list (${listSelector})`)
      : fail("interface", error.message);
  }
}

export async function registerPunch(
  session,
  triggerSelector,
  modalSelector,
  buttonSelector,
) {
  const { page } = session;

  const blocked = await openPunchInterface(page, triggerSelector, modalSelector);
  if (blocked) return blocked;

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

  // Let the application send the punch and refresh its list before the caller
  // reads it back. A quiet network is the best signal available; not reaching
  // one is not itself a failure, since the confirmation read decides.
  await page.waitForLoadState("networkidle").catch(() => {});

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

/// Returns a failure, or null once the punch interface is on screen.
async function openPunchInterface(page, triggerSelector, modalSelector) {
  const modal = page.locator(modalSelector).first();

  if (await modal.isVisible().catch(() => false)) {
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
    await modal.waitFor({ state: "visible" });
  } catch (error) {
    return isTimeout(error)
      ? fail("interface", `the punch interface (${modalSelector})`)
      : fail("interface", error.message);
  }

  return null;
}
