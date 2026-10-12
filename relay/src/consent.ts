import type { PairingInfo } from "./protocol";

// Everything about the client (name, domain, redirect host) comes from the client itself,
// through registration or its metadata document: always escape it.
const escape = (value: string) => value.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);

const style = `
:root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #f5f5f7; --card: #fff; --accent: #e8a33d; --warn: #b25000; }
@media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1d1d1f; --card: #2c2c2e; --warn: #ffb35c; } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 16px;
  font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--fg); }
main { width: 100%; max-width: 420px; background: var(--card); border-radius: 16px; padding: 28px; box-shadow: 0 1px 3px rgb(0 0 0 / 0.1); }
h1 { font-size: 20px; margin: 0 0 8px; }
p { margin: 8px 0; color: var(--muted); }
strong { color: var(--fg); }
.bulb { font-size: 32px; }
.code { font: 600 32px/1 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: 4px; text-align: center;
  margin: 20px 0; padding: 16px; border-radius: 12px; background: var(--bg); color: var(--fg); }
.status { display: flex; gap: 10px; align-items: center; justify-content: center; margin: 16px 0 4px; }
.spinner { width: 14px; height: 14px; border-radius: 50%; border: 2px solid var(--muted); border-top-color: transparent; animation: spin 0.8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.warn { color: var(--warn); }
button, a.button { font: inherit; padding: 8px 16px; border-radius: 8px; border: 1px solid var(--muted); background: none; color: var(--fg); cursor: pointer; text-decoration: none; }
.actions { display: flex; justify-content: center; margin-top: 16px; }
code { font: 14px ui-monospace, SFMono-Regular, Menlo, monospace; }
`;

function page(title: string, body: string, script = ""): string {
	return `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title>
<style>${style}</style>
<main>${body}</main>
${script ? `<script>${script}</script>` : ""}
</html>`;
}

export type Pairing = { id: string; code: string } | { offline: true } | { busy: true };

/**
 * Shows the code the owner will see on their Mac, then polls until they decide and posts
 * the decision back with the browser-bound consent handle.
 */
export function pairingPage(info: PairingInfo, handle: string, pairing: Pairing): string {
	const name = escape(info.client_name);
	const origin = info.client_domain
		? `Published by <strong>${escape(info.client_domain)}</strong>.`
		: "This app registered itself, so its name isn't verified.";
	const loopback = info.loopback
		? `<p class="warn">Access will be sent to an app on this computer. Continue only if you just started connecting from it.</p>`
		: "";
	const form = `<form method="post" id="decide">
  <input type="hidden" name="handle" value="${escape(handle)}">
  <input type="hidden" name="pairing" value="${"id" in pairing ? escape(pairing.id) : ""}">
  <input type="hidden" name="decision" value="deny">
</form>`;

	if ("busy" in pairing) {
		return page(
			"Porchlight is busy",
			`<div class="bulb">💡</div>
<h1>Too many requests are waiting</h1>
<p>Several connection requests are already waiting for an answer on your Mac.</p>
<p>Answer or dismiss them in Porchlight, or wait a few minutes, then try again.</p>
<div class="actions"><a class="button" href="">Try again</a></div>`,
		);
	}

	if (!("id" in pairing)) {
		return page(
			"Porchlight is offline",
			`<div class="bulb">💡</div>
<h1>Porchlight isn't running</h1>
<p><strong>${name}</strong> wants to connect, but Porchlight on your Mac isn't connected to this relay.</p>
<p>Open Porchlight, turn it on, then try again.</p>
<div class="actions"><a class="button" href="">Try again</a></div>`,
		);
	}

	const code = `${pairing.code.slice(0, 3)} ${pairing.code.slice(3)}`;
	const body = `<div class="bulb">💡</div>
<h1>Connect ${name} to Porchlight?</h1>
<p>${origin} Access will be sent to <strong>${escape(info.redirect_host)}</strong>.</p>
${loopback}
<p>Approve on your Mac. Check that it shows this code:</p>
<div class="code">${escape(code)}</div>
<div class="status" id="status"><span class="spinner"></span><span>Waiting for approval…</span></div>
<div class="actions"><button type="submit" form="decide">Cancel</button></div>
${form}`;

	const script = `
const form = document.getElementById("decide");
const status = document.getElementById("status");
const id = ${JSON.stringify(pairing.id)};
async function poll() {
  let state = "pending";
  try {
    const response = await fetch("/authorize/status?id=" + encodeURIComponent(id), { cache: "no-store" });
    state = (await response.json()).state;
  } catch {}
  if (state === "approved") {
    status.textContent = "Approved. Connecting…";
    form.decision.value = "approve";
    form.submit();
  } else if (state === "denied") {
    status.textContent = "Declined on your Mac.";
    form.submit();
  } else if (state === "expired") {
    status.textContent = "This request expired. Start connecting again from your app.";
  } else {
    status.lastElementChild.textContent = state === "offline"
      ? "Porchlight on your Mac went offline. Waiting for it…"
      : "Waiting for approval…";
    setTimeout(poll, 1000);
  }
}
poll();`;
	return page(`Connect ${info.client_name}`, body, script);
}

export function errorPage(message: string): string {
	return page(
		"Porchlight",
		`<div class="bulb">💡</div><h1>Couldn't connect</h1><p>${escape(message)}</p><p>Start connecting again from your app.</p>`,
	);
}

export function landingPage(origin: string): string {
	return page(
		"Porchlight relay",
		`<div class="bulb">💡</div>
<h1>Porchlight relay</h1>
<p>This relay connects cloud agents to the MCP servers on your Mac.</p>
<p>Add <code>${escape(origin)}/mcp</code> as a custom connector, then approve the connection on your Mac.</p>`,
	);
}
