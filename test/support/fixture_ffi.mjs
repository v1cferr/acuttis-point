// A stand-in for Acuttis, close enough to its observed shape to exercise the
// real Playwright adapter: a client-rendered page that rewrites its own path to
// /signin when unauthenticated, a submit button that starts disabled, and a
// punch modal that has to be opened before its button can be clicked.
//
// The punch list lives on the server so a test can inspect it afterwards, and
// so it survives a second browser session.

import { createServer } from "node:http";

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

  async function renderDashboard() {
    history.replaceState({}, "", "/dashboard");
    root.innerHTML = ${"`"}
      <h1>Dashboard</h1>
      <ul id="punch_history"></ul>
      <button class="modal-trigger btn">Registrar</button>
      <div id="mark_modal" class="modal" hidden>
        <p>CPF:</p>
        <button class="punch-button btn">Ponto</button>
        <button class="rest-button btn">Pausa</button>
      </div>
    ${"`"};

    root.querySelector(".modal-trigger").addEventListener("click", () => {
      root.querySelector("#mark_modal").hidden = false;
    });

    root.querySelector(".punch-button").addEventListener("click", async () => {
      await fetch("/api/punch", { method: "POST" });
      await paintHistory();
    });

    await paintHistory();
  }

  async function paintHistory() {
    const registered = await punches();
    const history = root.querySelector("#punch_history");
    if (!history) return;
    history.innerHTML = registered
      .map((time) => ${"`"}<li class="punch-row"><span class="time">${"$"}{time}</span></li>${"`"})
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

      if (path === "/api/punches") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify(punches));
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
