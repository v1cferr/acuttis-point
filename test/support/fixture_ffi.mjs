// A stand-in for Acuttis, close enough to its observed shape to exercise the
// real Playwright adapter: a client-rendered page that rewrites its own path to
// /signin when unauthenticated, a submit button that starts disabled, and a
// punch modal that has to be opened before its button can be clicked.
//
// The punch list lives on the server so a test can inspect it afterwards, and
// so it survives a second browser session.

import { createServer } from "node:http";

// Acuttis caps its receipt at twenty rows.
const RECEIPT_ROWS = 20;

let state = null;

const PAGE = String.raw`<!doctype html>
<html lang="pt-BR">
<head><meta charset="utf-8"><title>Fixture - Acuttis</title></head>
<body>
<div id="root"></div>
<script>
  const CREDENTIALS = { username: "victor@example.test", password: "s3cret" };
  const root = document.getElementById("root");

  const punches = () => fetch("/api/punches").then((r) => r.json());

  function renderSignIn(message) {
    history.replaceState({}, "", "/signin");
    root.innerHTML = ${"`"}
      <form class="login-form">
        <input id="username" name="username" type="text" required>
        <label for="username">E-mail ou CPF*</label>
        <input id="password" name="password" type="password" required>
        <label for="password">Senha*</label>
        <button type="submit" disabled class="btn sigInButton">Entrar</button>
      </form>
      <p id="signin_error">${"$"}{message ?? ""}</p>
    ${"`"};

    const form = root.querySelector("form");
    const username = root.querySelector("#username");
    const password = root.querySelector("#password");
    const submit = root.querySelector("button[type=submit]");

    // The real form enables its button only once both fields validate, which is
    // what the adapter has to wait for.
    const revalidate = () => {
      submit.disabled = !(username.value.length && password.value.length);
    };
    username.addEventListener("input", revalidate);
    password.addEventListener("input", revalidate);

    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (
        username.value === CREDENTIALS.username &&
        password.value === CREDENTIALS.password
      ) {
        sessionStorage.setItem("signedIn", "yes");
        renderDashboard();
      } else {
        root.querySelector("#signin_error").textContent = "Credenciais inválidas";
      }
    });
  }

  // The observed shape: the punch controls and the receipt are two views of the
  // same modal, and an anchor rather than a button opens it.
  async function renderDashboard() {
    history.replaceState({}, "", "/dashboard");
    root.innerHTML = ${"`"}
      <h1>Dashboard</h1>
      <a class="waves-effect tooltipped size-item-navbar"><i>touch_app</i></a>
      <div id="mark_modal" class="modal" hidden>
        <div id="punch_view">
          <span class="styles_clock__nR8e0">00:00:00</span>
          <p>CPF: 000.000.000-00</p>
          <button class="btn">Ponto</button>
          <button class="btn">Pausa</button>
          <button class="button-link">Comprovante de ponto</button>
        </div>
        <div id="receipt_view" hidden>
          <div id="punch_history"></div>
          <button class="button-link">Voltar</button>
        </div>
      </div>
    ${"`"};

    const modal = root.querySelector("#mark_modal");
    const punchView = root.querySelector("#punch_view");
    const receiptView = root.querySelector("#receipt_view");
    const button = (label) =>
      Array.from(root.querySelectorAll("button")).find(
        (b) => b.textContent.trim() === label,
      );

    root.querySelector("a.size-item-navbar").addEventListener("click", () => {
      modal.hidden = false;
    });

    button("Comprovante de ponto").addEventListener("click", async () => {
      punchView.hidden = true;
      receiptView.hidden = false;
      await paintHistory();
    });

    button("Voltar").addEventListener("click", () => {
      receiptView.hidden = true;
      punchView.hidden = false;
    });

    button("Ponto").addEventListener("click", async () => {
      await fetch("/api/punch", { method: "POST" });
    });
  }

  // Newest first, and spanning several days, the way the real receipt does.
  async function paintHistory() {
    const registered = await punches();
    const history = root.querySelector("#punch_history");
    if (!history) return;
    history.innerHTML = registered
      .map(
        (row) =>
          ${"`"}<div class="styles_containerMarkingAddress__lLpPc">${"$"}{row}</div>${"`"},
      )
      .join("");
  }

  if (sessionStorage.getItem("signedIn")) {
    renderDashboard();
  } else {
    renderSignIn();
  }
</script>
</body>
</html>`;

export function start(existingPunches, landsAt) {
  return new Promise((resolve) => {
    const punches = Array.from(existingPunches);

    const server = createServer((request, response) => {
      const path = new URL(request.url, "http://localhost").pathname;

      // Newest first and capped, the way the real receipt is: a new punch
      // pushes the oldest row out, so the row count never grows.
      if (path === "/api/punches") {
        const newest = punches.slice(-RECEIPT_ROWS).reverse();
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify(newest));
        return;
      }

      if (path === "/api/punch" && request.method === "POST") {
        punches.push(landsAt);
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify(punches));
        return;
      }

      // Any other path serves the application, the way a single page app does.
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end(PAGE);
    });

    server.listen(0, "127.0.0.1", () => {
      state = { server, punches };
      resolve(server.address().port);
    });
  });
}

// What the fixture holds now, so a test can prove a dry run changed nothing.
export function punches() {
  return state ? Array.from(state.punches) : [];
}

// The punch list outlives the server, so a test can stop the fixture and still
// ask what happened to it.
export function stop() {
  return new Promise((resolve) => {
    if (!state?.server) return resolve(undefined);
    const server = state.server;
    state.server = null;
    server.close(() => resolve(undefined));
  });
}
